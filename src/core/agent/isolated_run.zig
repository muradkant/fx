const std = @import("std");
const agent_runtime = @import("agent_runtime.zig");
const agent_run_service = @import("run_service.zig");
const worker_runtime = @import("worker_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const command_admission = @import("../permissions/command_admission.zig");
const auto_classifier = @import("../permissions/auto_classifier.zig");
const session_runtime = @import("../session/session.zig");
const file_mutation = @import("../tooling/file_mutation.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const tool_presentation = @import("../tooling/tool_presentation.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const gateway_error_format = @import("../shared/gateway_error_format.zig");
const diff_mod = @import("../output/diff.zig");
const hooks = @import("../hooks/hooks.zig");
const types = @import("../shared/types.zig");
const run_failure = @import("run_failure.zig");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    alloc: Allocator,
    worker: *worker_runtime.WorkerRuntime,
    session: *session_runtime.SessionRuntime,
    tool_context: tool_runtime.Context,
    lifecycle_view: hooks.RuntimeView = hooks.RuntimeView.empty(),
    lifecycle_session_id: ?[]const u8 = null,
    system_prompt: []const u8,
    model_prompt_overlay: ?[]const u8 = null,
    skills_prompt_section: []const u8 = "",
    explicit_skills_prompt_section: []const u8 = "",
    advertised_tool_names: []const []const u8 = &.{},
    advertised_functions: []const @import("../tooling/model_tool_schema.zig").FunctionSchema = &.{},
    custom_tool_guidance: []const u8 = "",
    response_schema_json: ?[]const u8 = null,
    /// Live host worker receiving the run's presentation stream. When set,
    /// assistant text, tool lifecycle, diffs, notices, and command output
    /// are forwarded into its event queue exactly as native turns emit
    /// them; control and transient turn-scoped events stay dropped. Null
    /// preserves the previous capture-only behavior.
    live_worker: ?*worker_runtime.WorkerRuntime = null,
};

pub const Result = struct {
    output: []u8,
    input_tokens: u64,
    output_tokens: u64,
    outcome: types.TurnPresentationOutcome,
    failure: ?run_failure.Snapshot = null,

    pub fn deinit(self: Result, alloc: Allocator) void {
        alloc.free(self.output);
        if (self.failure) |failure| alloc.free(failure.message);
    }
};

const Context = struct {
    config: Config,
    prompt: *const worker_runtime.QueuedPrompt,
    cancel: *std.atomic.Value(bool),
    output: std.ArrayList(u8) = .empty,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    outcome: ?types.TurnPresentationOutcome = null,
    failure: ?run_failure.Snapshot = null,

    fn deinit(self: *Context) void {
        self.output.deinit(self.config.alloc);
        if (self.failure) |failure| self.config.alloc.free(failure.message);
    }

    fn toolContext(self: *Context) tool_runtime.Context {
        var result = self.config.tool_context;
        result.worker = self.config.worker;
        result.session = self.config.session;
        result.session_allocator = self.config.alloc;
        result.cancel_flag = self.cancel;
        result.permission_mode = self.prompt.permission_mode;
        result.permission_grants = self.prompt.grants;
        result.session_grants = self.prompt.grants;
        result.permission_prompter = tool_admission.workerPrompter(self.config.worker);
        result.provider = self.prompt.provider;
        result.model = self.prompt.model;
        result.api_key = self.prompt.api_key;
        result.gateway_team = self.prompt.gateway_team;
        result.credential_source = self.prompt.credential_source;
        result.account_id = self.prompt.account_id;
        result.subagent_host = null;
        result.subagent_caller_id = null;
        result.session_child_capability = null;
        result.interactive = true;
        result.output_chunk_ctx = self;
        result.on_output_chunk = streamOutputChunk;
        result.lifecycle_view = self.config.lifecycle_view;
        result.lifecycle_scope = .{
            .kind = .interactive,
            .workspace_root = result.workspace_root,
            .session_id = self.config.lifecycle_session_id,
        };
        // Root-app responders are bound to its single worker. An isolated run
        // must never publish a question through that unrelated queue.
        result.mcp_input_responder = null;
        return result;
    }
};

pub fn run(
    config: Config,
    prompt: *const worker_runtime.QueuedPrompt,
    cancel: *std.atomic.Value(bool),
) agent_run_service.Error!Result {
    var arena_state = std.heap.ArenaAllocator.init(config.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parsed_schema: ?std.json.Parsed(std.json.Value) = if (config.response_schema_json) |schema|
        std.json.parseFromSlice(std.json.Value, arena, schema, .{}) catch
            return error.AgentExecutionFailed
    else
        null;
    defer if (parsed_schema) |*parsed| parsed.deinit();
    if (parsed_schema) |parsed| {
        if (parsed.value != .object) return error.AgentExecutionFailed;
    }

    var context = Context{
        .config = config,
        .prompt = prompt,
        .cancel = cancel,
    };
    defer context.deinit();
    const deps = runtimeDeps(&context);
    agent_run_service.run(.{
        .agent = &config.session.agent,
        .deps = &deps,
        .lifecycle = .{
            .view = config.lifecycle_view,
            .scope = .{
                .kind = .interactive,
                .workspace_root = config.tool_context.workspace_root,
                .session_id = config.lifecycle_session_id,
            },
            .outcome_allocator = config.alloc,
        },
        .config = .{
            .system_prompt = config.system_prompt,
            .model_prompt_overlay = config.model_prompt_overlay,
            .gateway_retry_count = config.tool_context.gateway_retry_count,
            .gateway_chat_url = config.tool_context.gateway_chat_url,
            .advertised_tool_names = config.advertised_tool_names,
            .advertised_functions = config.advertised_functions,
            .response_format = if (parsed_schema) |parsed| .{
                .name = "fixer_orchestration_outcome",
                .description = "A strict orchestration outcome selected by the active Fixer role.",
                .schema = parsed.value,
            } else null,
            .provider_capabilities = config.tool_context.provider_capabilities,
            .custom_tool_guidance = config.custom_tool_guidance,
            .agent_step_limit = config.tool_context.agent_step_limit,
            .max_tool_result_bytes = config.tool_context.max_tool_result_bytes,
            .cancel_flag = cancel,
            .fast_mode = config.tool_context.fast_mode,
            .effort = config.tool_context.effort,
            .first_call_tool_choice = config.tool_context.first_call_tool_choice,
            .workspace_root = config.tool_context.workspace_root,
            .access_scope = config.tool_context.access_scope,
            .origin = .root,
            .root_user_intent_context = prompt.root_user_intent_context,
            .current_prompt_is_root_authority = true,
            .context_limits = config.tool_context.context_limits,
        },
        .prompt = prompt.*,
    }) catch |err| return err;
    const output = context.output.toOwnedSlice(config.alloc) catch
        return error.OutOfMemory;
    errdefer config.alloc.free(output);
    const failure = context.failure;
    context.failure = null;
    return .{
        .output = output,
        .input_tokens = context.input_tokens,
        .output_tokens = context.output_tokens,
        .outcome = context.outcome orelse .completed,
        .failure = failure,
    };
}

fn runtimeDeps(context: *Context) agent_runtime.AgentRuntimeDeps {
    const tool_ctx = context.toolContext();
    return .{
        .ctx = context,
        .agent_stream_provider = tool_ctx.agent_stream_provider,
        .tool_registry = tool_ctx.tool_registry,
        .context_registry = tool_ctx.context_registry,
        .context_enabled = tool_ctx.context_enabled,
        // Isolated runs never present assistant markdown to a user: every run
        // ends in a machine envelope (or specialist result) parsed by the
        // Fixer extension, with human text published via publish_answer.
        // Stay source-only like ACP so wire JSON never renders live;
        // operational and restart notices still stream.
        .render_assistant_text = false,
        .finalize_turn = finalizeTurn,
        .append_runtime_context = appendRuntimeContext,
        .append_static_context = appendStaticContext,
        .validate_tool_call = validateToolCall,
        .check_tool_availability = checkToolAvailability,
        .request_tool_permission = requestToolPermission,
        .request_prepared_file_mutation_permission = requestPreparedFileMutationPermission,
        .resolve_tool_action_display_target = resolveToolActionDisplayTarget,
        .describe_tool_action = describeToolAction,
        .describe_tool_action_completed = describeToolAction,
        .describe_tool_action_denied = describeToolActionDenied,
        .permission_target_for_call = permissionTargetForCall,
        .execute_tool_call = executeToolCall,
        .publish_committed_file_handoff = publishCommittedFileHandoff,
        .propagate_history_turn = propagateHistoryTurn,
        .propagate_grant = discardGrant,
        .push_event = pushStreamEvent,
        .push_text = captureText,
        .push_tool_lifecycle = pushStreamToolLifecycle,
        .push_diff_block = pushStreamDiff,
        .push_system_notice = pushStreamNotice,
        .push_route_recovery_status = discardRouteRecoveryStatus,
        .push_command_output_complete = pushStreamCommandOutputComplete,
        .push_http_error = captureHttpError,
        .refresh_gateway_credential = refreshGatewayCredential,
        .format_tool_execution_error = formatToolExecutionError,
        .report_usage = reportUsage,
        .usage = &context.config.session.usage,
        .usage_allocator = context.config.alloc,
    };
}

fn finalizeTurn(raw: *anyopaque, _: u64, outcome: types.TurnPresentationOutcome, _: ?types.ProviderCompletionDisposition) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    context.outcome = outcome;
}

fn appendRuntimeContext(raw: *anyopaque, arena: Allocator, messages: *std.ArrayList(types.ChatMessage)) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    const tool_ctx = context.toolContext();
    try tool_ctx.context_registry.appendDefaultTransient(.{
        .workspace_root = tool_ctx.workspace_root,
        .access_scope = tool_ctx.access_scope,
        .interactive = true,
        .permission_mode = context.prompt.permission_mode,
    }, arena, messages);
}

fn appendStaticContext(raw: *anyopaque, arena: Allocator, project_context: ?[]const u8, messages: *std.ArrayList(types.ChatMessage)) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    const snapshot_context = if (context.prompt.context_snapshot.modelVisibleBytes().len > 0)
        context.prompt.context_snapshot.modelVisibleBytes()
    else
        "";
    try context.config.tool_context.context_registry.appendDefaultStatic(.{
        .project_context = project_context orelse snapshot_context,
    }, arena, messages);
}

fn validateToolCall(raw: *anyopaque, arena: Allocator, call: types.ToolCall) !agent_runtime.ToolCallValidationResult {
    const context: *Context = @ptrCast(@alignCast(raw));
    return tool_runtime.validateToolCall(context.toolContext(), arena, call);
}

fn checkToolAvailability(raw: *anyopaque, arena: Allocator, call: types.ToolCall) !?[]const u8 {
    const context: *Context = @ptrCast(@alignCast(raw));
    return tool_runtime.checkToolAvailability(context.toolContext(), arena, call);
}

fn admissionContext(context: *Context, dynamic_names: []const []const u8, review: ?auto_classifier.ReviewTurnContext) tool_runtime.Context {
    var tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(context.toolContext(), dynamic_names);
    tool_ctx.permission_review_turn = review;
    return tool_ctx;
}

fn requestToolPermission(raw: *anyopaque, arena: Allocator, call: types.ToolCall, review: auto_classifier.ReviewTurnContext, mode: types.PermissionMode, grants: []const types.PermissionGrant, live: ?agent_runtime.LiveToolAuthority, revalidation: ?agent_runtime.LivePermissionRevalidation, dynamic_names: []const []const u8, mcp_review_schema_json: ?[]const u8) !command_admission.PermissionOutcome {
    const context: *Context = @ptrCast(@alignCast(raw));
    var tool_ctx = admissionContext(context, dynamic_names, review);
    tool_ctx.mcp_review_schema_json = mcp_review_schema_json;
    if (revalidation) |request| return switch (request) {
        .action => |action| tool_admission.revalidateLiveActionPermissionOutcome(tool_ctx.admissionInputWithLiveAuthority(live), arena, call, mode, grants, action.authority, action.human_approval),
    };
    return tool_admission.requestPermissionOutcome(tool_ctx.admissionInputWithLiveAuthority(live), arena, call, mode, grants);
}

fn requestPreparedFileMutationPermission(raw: *anyopaque, arena: Allocator, call: types.ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review: auto_classifier.ReviewTurnContext, mode: types.PermissionMode, grants: []const types.PermissionGrant, live: ?agent_runtime.LiveToolAuthority, dynamic_names: []const []const u8) !command_admission.PermissionOutcome {
    const context: *Context = @ptrCast(@alignCast(raw));
    const tool_ctx = admissionContext(context, dynamic_names, review);
    return tool_admission.requestPreparedFileMutationPermissionOutcome(tool_ctx.admissionInputWithLiveAuthority(live), arena, call, prepared, mode, grants);
}

fn resolveToolActionDisplayTarget(raw: *anyopaque, arena: Allocator, call: types.ToolCall) !?[]const u8 {
    const context: *Context = @ptrCast(@alignCast(raw));
    const tool_ctx = context.toolContext();
    return tool_presentation.resolveTerminalDisplayTarget(arena, tool_ctx.tool_registry, tool_ctx.workspace_root, tool_ctx.terminal_client, tool_ctx.managed_executions, call);
}

fn describeToolAction(raw: *anyopaque, arena: Allocator, call: types.ToolCall, display_target: ?[]const u8, _: []const []const u8) ![]const u8 {
    const context: *Context = @ptrCast(@alignCast(raw));
    const tool_ctx = context.toolContext();
    return tool_presentation.formatPlainAction(arena, .{
        .tool_registry = tool_ctx.tool_registry,
        .call = call,
        .workspace_root = tool_ctx.workspace_root,
        .display_target = display_target,
    });
}

fn describeToolActionDenied(raw: *anyopaque, arena: Allocator, call: types.ToolCall, display_target: ?[]const u8, label: []const u8, dynamic_names: []const []const u8) ![]const u8 {
    const action = try describeToolAction(raw, arena, call, display_target, dynamic_names);
    return std.fmt.allocPrint(arena, "{s}: {s}", .{ label, action });
}

fn permissionTargetForCall(raw: *anyopaque, arena: Allocator, call: types.ToolCall, dynamic_names: []const []const u8) ![]const u8 {
    const context: *Context = @ptrCast(@alignCast(raw));
    const tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(context.toolContext(), dynamic_names);
    return tool_admission.permissionTargetForLiveAuthority(tool_ctx.admissionInput(), arena, call);
}

fn executeToolCall(raw: *anyopaque, request: agent_runtime.ToolExecutionRequest) !agent_runtime.ToolExecutionResult {
    const context: *Context = @ptrCast(@alignCast(raw));
    var tool_ctx = context.toolContext();
    tool_ctx.root_user_intent_context = request.root_user_intent_context;
    tool_ctx.root_user_messages = request.root_user_messages;
    tool_ctx.root_user_evidence_complete = request.root_user_evidence_complete;
    tool_ctx.session_grants = request.session_grants;
    tool_ctx.advertised_dynamic_tool_names = request.advertised_dynamic_tool_names;
    tool_ctx.max_tool_result_bytes = request.max_tool_result_bytes;
    return tool_runtime.executeToolCallAuthorized(tool_ctx, request);
}

fn propagateHistoryTurn(raw: *anyopaque, turn: types.HistoryTurn) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    try context.config.session.appendHistoryEntry(context.config.alloc, turn);
}

fn captureText(raw: *anyopaque, emission: agent_runtime.TextEmission) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    switch (emission) {
        .assistant_source => |text| try context.output.appendSlice(context.config.alloc, text),
        .assistant_started, .assistant_rendered, .assistant_restarted, .operational => {},
    }
    if (context.config.live_worker) |live| try forwardStreamText(live, emission);
}

fn pushStreamEvent(raw: *anyopaque, event: worker_runtime.WorkerEvent) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    if (context.config.live_worker) |live| return forwardStreamEvent(live, event);
    worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
}

fn pushStreamToolLifecycle(raw: *anyopaque, event: types.ToolLifecycleEvent) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    if (context.config.live_worker) |live| try forwardStreamToolLifecycle(live, event);
}

fn pushStreamDiff(raw: *anyopaque, payload: agent_runtime.DiffEntryPayload) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    if (context.config.live_worker) |live| return forwardStreamDiff(live, payload);
    diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
}

fn pushStreamNotice(raw: *anyopaque, text: []const u8) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    if (context.config.live_worker) |live| try forwardStreamNotice(live, text);
}

fn pushStreamCommandOutputComplete(raw: *anyopaque, lifecycle_id: ?types.ToolLifecycleId) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    if (context.config.live_worker) |live| try forwardStreamCommandOutputComplete(live, lifecycle_id);
}

fn streamOutputChunk(raw: *anyopaque, lifecycle_id: ?types.ToolLifecycleId, stream: @import("../tooling/command_output_content.zig").Stream, chunk: []const u8) anyerror!void {
    const context: *Context = @ptrCast(@alignCast(raw));
    if (context.config.live_worker) |live| try forwardStreamCommandOutput(live, lifecycle_id, stream, chunk);
}

/// Presentation-safe worker events forwarded from an isolated run into the
/// host worker queue. Control, credential, grant, and transient turn-scoped
/// events stay with the run: forwarding them would corrupt host turn state.
/// New variants stay dropped by default until explicitly allowed here.
fn streamsWorkerEvent(event: worker_runtime.WorkerEvent) bool {
    return switch (event) {
        .assistant_presentation,
        .semantic_notice,
        .error_text,
        .command_output,
        .command_output_complete,
        .tool_lifecycle,
        .diff_block,
        => true,
        else => false,
    };
}

fn forwardStreamEvent(live: *worker_runtime.WorkerRuntime, event: worker_runtime.WorkerEvent) !void {
    defer worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
    if (!streamsWorkerEvent(event)) return;
    try live.pushEvent(std.heap.c_allocator, event);
}

fn forwardStreamText(live: *worker_runtime.WorkerRuntime, emission: agent_runtime.TextEmission) !void {
    // Mirrors agentPushText: only rendered output reaches the transcript.
    const text = switch (emission) {
        .assistant_rendered, .assistant_restarted, .operational => |bytes| bytes,
        .assistant_started, .assistant_source => return,
    };
    try live.pushEvent(std.heap.c_allocator, .{ .assistant_presentation = .{ .text = @constCast(text) } });
}

fn forwardStreamToolLifecycle(live: *worker_runtime.WorkerRuntime, event: types.ToolLifecycleEvent) !void {
    try live.pushEvent(std.heap.c_allocator, .{ .tool_lifecycle = event });
}

fn forwardStreamDiff(live: *worker_runtime.WorkerRuntime, payload: agent_runtime.DiffEntryPayload) !void {
    live.pushOwnedEvent(std.heap.c_allocator, .{ .diff_block = payload }) catch |err| {
        diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
        return err;
    };
}

fn forwardStreamNotice(live: *worker_runtime.WorkerRuntime, text: []const u8) !void {
    // Mirrors agentPushSystemNotice.
    try live.pushEvent(std.heap.c_allocator, .{ .semantic_notice = .{
        .topic = @constCast("system"),
        .tone = .neutral,
        .body = @constCast(text),
    } });
}

fn forwardStreamCommandOutput(live: *worker_runtime.WorkerRuntime, lifecycle_id: ?types.ToolLifecycleId, stream: @import("../tooling/command_output_content.zig").Stream, chunk: []const u8) !void {
    if (chunk.len == 0) return;
    try live.pushEvent(std.heap.c_allocator, .{ .command_output = .{
        .lifecycle_id = lifecycle_id,
        .stream = stream,
        .text = @constCast(chunk),
    } });
}

fn forwardStreamCommandOutputComplete(live: *worker_runtime.WorkerRuntime, lifecycle_id: ?types.ToolLifecycleId) !void {
    try live.pushEvent(std.heap.c_allocator, .{ .command_output_complete = lifecycle_id });
}

fn discardRouteRecoveryStatus(_: *anyopaque, _: types.RouteRecoveryStatus) !void {}
fn captureHttpError(raw: *anyopaque, status: std.http.Status, detail: []const u8, credential_source: ?types.CredentialSource) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    const failure = try formatHttpFailure(context.config.alloc, status, detail, credential_source);
    errdefer context.config.alloc.free(failure.message);
    if (context.failure) |previous| context.config.alloc.free(previous.message);
    context.failure = failure;
}

fn formatHttpFailure(
    alloc: Allocator,
    status: std.http.Status,
    detail: []const u8,
    credential_source: ?types.CredentialSource,
) !run_failure.Snapshot {
    const auth_failure = auth_runtime.FailureSnapshot.fromHttp(status, credential_source);
    const message = if (detail.len > 0)
        try gateway_error_format.formatHttpErrorMessage(alloc, status, detail)
    else if (auth_failure) |failure|
        try failure.renderText(alloc)
    else
        try gateway_error_format.formatHttpErrorMessage(alloc, status, detail);
    return .{
        .kind = run_failure.kindForHttpStatus(status),
        .http_status = @intFromEnum(status),
        .message = message,
    };
}
fn discardGrant(_: *anyopaque, _: []const u8, _: []const u8) !void {}
fn discardBackgroundUrl(_: *anyopaque, _: u64, _: []const u8) void {}

fn publishCommittedFileHandoff(_: *anyopaque, _: file_mutation.CommittedFileHandoff) agent_runtime.SecondaryPublicationReport {
    return .{ .diff = .skipped, .tracker = .skipped };
}

fn refreshGatewayCredential(raw: *anyopaque, alloc: Allocator, source: types.CredentialSource, mode: auth_runtime.CredentialRefreshMode, expected_account_id: ?[]const u8) !?[]u8 {
    const context: *Context = @ptrCast(@alignCast(raw));
    const tool_ctx = context.toolContext();
    var refreshed = (try auth_runtime.refreshCredentialForAccount(
        tool_ctx.oauth_transport,
        alloc,
        source,
        mode,
        expected_account_id,
    )) orelse return null;
    defer refreshed.deinit(alloc);
    return try alloc.dupe(u8, refreshed.token);
}

test "isolated HTTP failure retains sanitized provider billing detail" {
    const failure = try formatHttpFailure(
        std.testing.allocator,
        .unauthorized,
        \\{"error":{"type":"CreditsError","message":"Insufficient balance. Manage billing at https://example.invalid/billing"}}
    ,
        .opencode_api_key,
    );
    defer std.testing.allocator.free(failure.message);

    try std.testing.expectEqual(run_failure.Kind.authentication, failure.kind);
    try std.testing.expectEqual(@as(?u16, 401), failure.http_status);
    try std.testing.expect(std.mem.find(u8, failure.message, "CreditsError") != null);
    try std.testing.expect(std.mem.find(u8, failure.message, "Insufficient balance") != null);
}

fn formatToolExecutionError(_: *anyopaque, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
    return tool_result_errors.formatToolExecutionErrorJson(arena, tool_name, err);
}

fn reportUsage(raw: *anyopaque, usage: types.Usage) void {
    const context: *Context = @ptrCast(@alignCast(raw));
    if (usage.input_tokens) |value| context.input_tokens = value;
    if (usage.output_tokens) |value| context.output_tokens = value;
}

test "isolated service is independent of native subagent modules" {
    _ = Config;
    _ = Result;
    _ = run;
}

test "isolated live forwarding streams presentation and drops control events" {
    var live: worker_runtime.WorkerRuntime = .{};
    defer live.deinit(std.heap.c_allocator);

    const owned_text = try std.heap.c_allocator.dupe(u8, "streamed");
    try forwardStreamEvent(&live, .{ .assistant_presentation = .{ .text = owned_text } });
    try forwardStreamText(&live, .{ .assistant_rendered = "rendered" });
    try forwardStreamText(&live, .{ .assistant_source = "source stays captured" });
    try forwardStreamNotice(&live, "note");
    try forwardStreamCommandOutputComplete(&live, null);
    try forwardStreamEvent(&live, .question_requested);
    try forwardStreamEvent(&live, .open_model_picker);
    try forwardStreamEvent(&live, .{ .begin_presented_prompt = 7 });
    try forwardStreamEvent(&live, .{ .turn_token_update = .{ .input_tokens = 1, .output_tokens = 2 } });

    const events = live.worker_events.items;
    try std.testing.expectEqual(@as(usize, 4), events.len);
    try std.testing.expectEqualStrings("streamed", events[0].assistant_presentation.text);
    try std.testing.expect(events[0].assistant_presentation.text.ptr != owned_text.ptr);
    try std.testing.expectEqualStrings("rendered", events[1].assistant_presentation.text);
    try std.testing.expectEqualStrings("note", events[2].semantic_notice.body);
    try std.testing.expect(events[3] == .command_output_complete);
    try std.testing.expect(events[3].command_output_complete == null);
}
