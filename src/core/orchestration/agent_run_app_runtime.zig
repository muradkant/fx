const std = @import("std");
const app_agent_runtime = @import("../app/app_agent_runtime.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const builtin_gateway = @import("../../builtins/gateway.zig");
const credentials = @import("../auth/credentials.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const secret = @import("../auth/secret.zig");
const skill_invocation = @import("../skills/skill_invocation.zig");
const model_provider = @import("../config/model_provider.zig");
const types = @import("../shared/types.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_projection = @import("../tooling/tool_projection.zig");
const web_backends = @import("../tooling/web_backends.zig");
const run_manager = @import("run_manager.zig");

const Allocator = std.mem.Allocator;
const ReasoningEffort = types.ReasoningEffort;

fn orchestrationModelId(
    alloc: Allocator,
    provider: model_provider.ProviderId,
    route_raw: []const u8,
    name_raw: []const u8,
) ![]u8 {
    const route = std.mem.trim(u8, route_raw, " \t\r\n");
    const name = std.mem.trim(u8, name_raw, " \t\r\n");
    if (!validOrchestrationModelComponent(route) or
        !validOrchestrationModelComponent(name))
    {
        return error.InvalidOrchestrationModelIdentity;
    }
    return switch (provider) {
        .opencode => if (std.ascii.eqlIgnoreCase(route, "zen"))
            alloc.dupe(u8, name)
        else if (std.ascii.eqlIgnoreCase(route, "go"))
            std.fmt.allocPrint(alloc, "go/{s}", .{name})
        else
            error.InvalidOpenCodeRoute,
        .cline => std.fmt.allocPrint(alloc, "{s}/{s}", .{ route, name }),
        .gateway => std.fmt.allocPrint(alloc, "{s}/{s}", .{ route, name }),
        .codex, .grok => error.OrchestrationProviderNotUnified,
    };
}

test "ALT preserves complete Cline model identities" {
    const free = try orchestrationModelId(std.testing.allocator, .cline, "z-ai", "glm-5.3-flash");
    defer std.testing.allocator.free(free);
    try std.testing.expectEqualStrings("z-ai/glm-5.3-flash", free);

    const cline_pass = try orchestrationModelId(std.testing.allocator, .cline, "cline-pass", "kimi-k3");
    defer std.testing.allocator.free(cline_pass);
    try std.testing.expectEqualStrings("cline-pass/kimi-k3", cline_pass);
}

fn validOrchestrationModelComponent(value: []const u8) bool {
    if (value.len == 0 or value.len > 256) return false;
    for (value) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn orchestrationPromptOverlay(
    alloc: Allocator,
    base: ?[]const u8,
    role_prompt: []const u8,
    supplemental_context: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    var wrote = false;
    for ([_][]const u8{ base orelse "", role_prompt, supplemental_context }) |section| {
        const trimmed = std.mem.trim(u8, section, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (wrote) try writer.writeAll("\n\n");
        try writer.writeAll(trimmed);
        wrote = true;
    }
    return out.toOwnedSlice();
}

pub fn start(
    comptime Host: type,
    comptime App: type,
    app: *App,
    request: Host.AgentRunRequest,
) !void {
    const AgentAppRuntime = app_agent_runtime.Runtime(App);
    if (!app.orchestration.active) return error.OrchestrationModeInactive;
    if (app.orchestration.active_source_turn_id != request.authority.source_turn_id) {
        return error.OrchestrationAuthorityMismatch;
    }
    if (!std.mem.eql(
        u64,
        app.orchestration.instruction_source_turn_ids.items,
        request.authority.instruction_source_turn_ids,
    )) {
        return error.OrchestrationInstructionAuthorityMismatch;
    }
    switch (request.scope) {
        .specialist => if (request.context_key != null) {
            return error.StatefulOrchestrationSpecialist;
        },
        .leader, .peer => if (request.context_key == null or request.context_key.?.len == 0) {
            return error.MissingOrchestrationContextKey;
        },
    }
    if (request.context_key != null and request.visible_input == .projected) {
        return error.ContextBearingProjectedInput;
    }
    const provider = provider_catalog.parse(request.model.provider_id) orelse
        return error.UnknownOrchestrationProvider;
    if (provider_catalog.find(provider).catalog_scope != .unified) {
        return error.OrchestrationProviderNotUnified;
    }

    var prompt = switch (request.visible_input) {
        .canonical_turn => try app.orchestration.canonical_turns.cloneCanonical(
            app.alloc,
            request.authority.source_turn_id,
            request.authority.instruction_source_turn_ids,
        ),
        .projected => |projected| try app.orchestration.canonical_turns.cloneProjected(
            app.alloc,
            request.authority.source_turn_id,
            request.authority.instruction_source_turn_ids,
            projected.content,
            projected.attachment_references,
        ),
    };
    var owns_prompt = true;
    errdefer if (owns_prompt) worker_runtime.freeQueuedPrompt(app.alloc, prompt);
    const supplemental_context = switch (request.visible_input) {
        .canonical_turn => |canonical| canonical.supplemental_context,
        .projected => "",
    };
    const continued_context = if (request.context_key) |key|
        try app.orchestration.runs.attachContextSurface(
            app.alloc,
            key,
            request.authority.source_turn_id,
            request.authority.instruction_source_turn_ids,
            supplemental_context,
            &prompt,
        )
    else
        false;

    // Canonical projections deliberately discard the root worker's turn
    // identity. Rebind this isolated worker to fx's opaque custody ID so
    // its permission, question, cancellation, and activity snapshots have
    // a stable nonzero lifecycle key without reviving root-worker state.
    prompt.turn_id = request.authority.source_turn_id;

    try routeOrchestrationCredential(App, app, &prompt, provider);
    const exact_model = try orchestrationModelId(
        app.alloc,
        provider,
        request.model.route,
        request.model.name,
    );
    app.alloc.free(prompt.model);
    prompt.model = exact_model;
    prompt.provider = provider;
    prompt.agent_settings.effort = .auto;
    if (request.model.reasoning_effort) |raw_effort| {
        prompt.agent_settings.effort = ReasoningEffort.parse(raw_effort) orelse
            return error.InvalidOrchestrationReasoningEffort;
    }

    var projection = try app.snapshotModelToolProjectionForProvider(
        app.alloc,
        prompt.permission_mode,
        provider,
    );
    var owns_projection = true;
    errdefer if (owns_projection) projection.deinit(app.alloc);
    debug_trace.eventf(
        "orchestration",
        "agent_run_host_admitted",
        .{},
        "run={s} provider={s} model={s} tool_count={d} write_file={s} native_subagent={s} structured_outcome={s}",
        .{
            request.run_id,
            request.model.provider_id,
            prompt.model,
            projection.advertised_names.len,
            if (tool_projection.containsName(projection.advertised_names, "write_file")) "advertised" else "absent",
            if (tool_projection.containsName(projection.advertised_names, "subagent")) "advertised" else "absent",
            if (request.response_schema_json != null) "enabled" else "disabled",
        },
    );
    var permission_rules = try types.dupePermissionRuleSet(
        app.alloc,
        app.permission_engine.rules,
    );
    var owns_permission_rules = true;
    errdefer if (owns_permission_rules) permission_rules.deinit(app.alloc);

    var tool_context = AgentAppRuntime.toolContext(
        app,
        &tool_dispatch.default_ignored_list_entries,
        tool_dispatch.default_max_list_entries,
        tool_dispatch.default_max_read_file_bytes,
        tool_dispatch.default_max_read_file_lines,
        tool_dispatch.default_max_read_file_line_len,
        tool_dispatch.default_max_command_output_bytes,
        builtin_gateway.retry_count,
        builtin_gateway.defaultChatUrl(),
    );
    const bundle = app.providerSet().select(provider);
    tool_context.agent_stream_provider = bundle.agent_stream_or_unavailable();
    tool_context.provider = provider;
    tool_context.provider_capabilities = bundle.capabilities;
    tool_context.model = prompt.model;
    tool_context.api_key = prompt.api_key;
    tool_context.gateway_team = prompt.gateway_team;
    tool_context.credential_source = prompt.credential_source;
    tool_context.account_id = prompt.account_id;
    tool_context.permission_mode = prompt.permission_mode;
    tool_context.permission_grants = prompt.grants;
    tool_context.permission_rules = permission_rules;
    tool_context.subagent_host = null;
    tool_context.subagent_caller_id = null;
    const configured_backends = web_backends.configure(.{
        .fx_search = bundle.capabilities.fx_search,
        .api_key = prompt.api_key,
        .credential_source = prompt.credential_source,
        .gateway_team = prompt.gateway_team,
        .worker_model = prompt.model,
        .gateway_retry_count = builtin_gateway.retry_count,
        .gateway_chat_url = builtin_gateway.defaultChatUrl(),
        .usage = &app.session.usage,
        .usage_allocator = app.alloc,
        .parallel_api_key = if (app.parallel_connection) |*connection| connection.api_key else null,
    }, .{
        .web_search = &app.web_search_runtime,
        .parallel_web_search = &app.parallel_web_search_runtime,
        .parallel_web_fetch = &app.parallel_web_fetch_runtime,
    });
    tool_context.web_search_backend = configured_backends.web_search;
    tool_context.web_fetch_backend = configured_backends.web_fetch;
    tool_context.web_search_runtime_ready = configured_backends.web_search_runtime_ready;
    if (request.visible_input == .projected) {
        tool_context.context_enabled = false;
    }

    const policy_snapshot = app.promptPolicy();
    var strings_transferred = false;
    const system_prompt = try app.alloc.dupe(u8, policy_snapshot.system_prompt);
    errdefer if (!strings_transferred) app.alloc.free(system_prompt);
    const model_prompt_overlay = try orchestrationPromptOverlay(
        app.alloc,
        policy_snapshot.modelPromptOverlay(prompt.model),
        request.system_prompt,
        if (continued_context) "" else supplemental_context,
    );
    errdefer if (!strings_transferred) app.alloc.free(model_prompt_overlay);

    const skills_prompt_section: []u8 = &.{};
    var explicit_skills_prompt_section: []u8 = &.{};
    if (request.visible_input == .canonical_turn) {
        // Routed skill mentions are no longer injected as prompt text;
        // the advertised skill catalog and the skill tool load them.
        const explicit_bindings = try app.alloc.alloc(
            skill_invocation.ExplicitBinding,
            prompt.skill_bindings.len,
        );
        defer app.alloc.free(explicit_bindings);
        for (prompt.skill_bindings, 0..) |binding, index| {
            explicit_bindings[index] = .{
                .name = binding.name,
                .path = binding.path,
            };
        }
        var explicit = try skill_invocation.buildExplicitPromptSection(
            app.alloc,
            .{
                .skills = app.skills.items,
                .diagnostics = app.skills.diagnostics,
            },
            prompt.prompt,
            explicit_bindings,
            app.context_limits,
            null,
        );
        defer explicit.deinit(app.alloc);
        explicit_skills_prompt_section = try app.alloc.dupe(
            u8,
            explicit.text,
        );
        errdefer if (!strings_transferred) app.alloc.free(explicit_skills_prompt_section);
    }

    const run_id = try app.alloc.dupe(u8, request.run_id);
    errdefer if (!strings_transferred) app.alloc.free(run_id);
    const context_key = if (request.context_key) |key|
        try app.alloc.dupe(u8, key)
    else
        null;
    errdefer if (!strings_transferred) {
        if (context_key) |key| app.alloc.free(key);
    };
    const instruction_source_turn_ids = try app.alloc.dupe(
        u64,
        request.authority.instruction_source_turn_ids,
    );
    errdefer if (!strings_transferred) app.alloc.free(instruction_source_turn_ids);
    const response_schema_json = if (request.response_schema_json) |schema|
        try app.alloc.dupe(u8, schema)
    else
        null;
    errdefer if (!strings_transferred) {
        if (response_schema_json) |schema| app.alloc.free(schema);
    };
    const lifecycle_session_id = try app.alloc.dupe(u8, request.run_id);
    errdefer if (!strings_transferred) app.alloc.free(lifecycle_session_id);

    var owned_prepared = run_manager.Prepared{
        .run_id = run_id,
        .context_key = context_key,
        .source_turn_id = request.authority.source_turn_id,
        .instruction_source_turn_ids = instruction_source_turn_ids,
        .prompt = prompt,
        .tool_context = tool_context,
        .tool_projection = projection,
        .permission_rules = permission_rules,
        .system_prompt = system_prompt,
        .model_prompt_overlay = model_prompt_overlay,
        .skills_prompt_section = skills_prompt_section,
        .explicit_skills_prompt_section = explicit_skills_prompt_section,
        .response_schema_json = response_schema_json,
        .lifecycle_session_id = lifecycle_session_id,
    };
    var owns_prepared = true;
    errdefer if (owns_prepared) owned_prepared.deinit(app.alloc);
    owns_prompt = false;
    owns_projection = false;
    owns_permission_rules = false;
    strings_transferred = true;
    try app.orchestration.runs.start(owned_prepared);
    owns_prepared = false;
}

fn routeOrchestrationCredential(
    comptime App: type,
    app: *App,
    prompt: *worker_runtime.QueuedPrompt,
    provider: model_provider.ProviderId,
) !void {
    if (model_provider.authorizesCredential(provider, prompt.credential_source)) return;
    const resolution = try credentials.resolveForProvider(
        app.alloc,
        app.auth.oauthTransport(),
        app.auth.secretStore(),
        .refresh_if_needed,
        provider,
        prompt.credential_source,
    );
    var credential = resolution.credential orelse return error.OrchestrationCredentialMissing;
    defer credential.deinit(app.alloc);
    const token = try app.alloc.dupe(u8, credential.token);
    errdefer secret.zeroAndFree(app.alloc, token);
    const gateway_team = if (credential.gatewayTeam()) |team|
        try app.alloc.dupe(u8, team)
    else
        null;
    errdefer if (gateway_team) |team| app.alloc.free(team);
    const account_id = if (credential.accountId()) |id|
        try app.alloc.dupe(u8, id)
    else
        null;

    secret.zeroAndFree(app.alloc, prompt.api_key);
    if (prompt.gateway_team) |team| app.alloc.free(team);
    if (prompt.account_id) |id| app.alloc.free(id);
    prompt.api_key = token;
    prompt.gateway_team = gateway_team;
    prompt.account_id = account_id;
    prompt.credential_source = credential.source;
}
