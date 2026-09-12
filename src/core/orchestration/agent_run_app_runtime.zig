const std = @import("std");
const orchestration_app_runtime = @import("app_runtime.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const builtin_gateway = @import("../../builtins/gateway.zig");
const credentials = @import("../auth/credentials.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const provider_set = @import("../gateway/provider_set.zig");
const secret = @import("../auth/secret.zig");
const host = @import("../hosts/host.zig");
const skill_invocation = @import("../skills/skill_invocation.zig");
const config_runtime = @import("../config/config_runtime.zig");
const model_provider = @import("../config/model_provider.zig");
const prompt_policy = @import("../config/prompt_policy.zig");
const session_usage = @import("../session/session_usage.zig");
const types = @import("../shared/types.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const tool_projection = @import("../tooling/tool_projection.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const web_backends = @import("../tooling/web_backends.zig");
const run_manager = @import("run_manager.zig");

const Allocator = std.mem.Allocator;
const ReasoningEffort = types.ReasoningEffort;

fn orchestrationModelId(
    comptime Host: type,
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
    const identity = Host.ModelIdentity{ .route = route, .name = name };
    return switch (provider) {
        .opencode, .cline, .gateway => identity.format(@tagName(provider), alloc) catch |err| {
            // Only the OpenCode branch validates routes; the other joins
            // fail only on allocation failure.
            if (err == error.OutOfMemory) return err;
            return error.InvalidOpenCodeRoute;
        },
        .codex, .grok => error.OrchestrationProviderNotUnified,
    };
}

test "Fixer preserves complete Cline model identities" {
    const Host = @import("fx_orchestration_host");
    const free = try orchestrationModelId(Host, std.testing.allocator, .cline, "z-ai", "glm-5.3-flash");
    defer std.testing.allocator.free(free);
    try std.testing.expectEqualStrings("z-ai/glm-5.3-flash", free);

    const cline_pass = try orchestrationModelId(Host, std.testing.allocator, .cline, "cline-pass", "kimi-k3");
    defer std.testing.allocator.free(cline_pass);
    try std.testing.expectEqualStrings("cline-pass/kimi-k3", cline_pass);
}

test "admission requires response-format identity alongside a schema" {
    const Host = @import("fx_orchestration_host");
    var state = orchestration_app_runtime.State(Host){
        .active = true,
        .active_source_turn_id = 7,
    };
    defer state.instruction_source_turn_ids.deinit(std.testing.allocator);
    var request: Host.AgentRunRequest = .{
        .run_id = "run-1",
        .authority = .{ .source_turn_id = 7 },
        .model = .{ .provider_id = "opencode", .route = "zen", .name = "kimi-k3" },
        .scope = .{ .leader = .{ .agent_id = "leader" } },
        .context_key = "leader",
        .system_prompt = "sys",
        .visible_input = .{ .canonical_turn = .{} },
        .response_schema_json = "{}",
    };
    try std.testing.expectError(
        error.OrchestrationResponseFormatIdentityMissing,
        validateAdmission(Host, &state, request),
    );
    request.response_format_name = "fixer_orchestration_outcome";
    request.response_format_description = "outcome";
    try validateAdmission(Host, &state, request);
}

test "orchestration joins stored route and name through the shared encoding" {
    const Host = @import("fx_orchestration_host");
    const alloc = std.testing.allocator;
    const zen = try orchestrationModelId(Host, alloc, .opencode, "zen", "kimi-k3");
    defer alloc.free(zen);
    try std.testing.expectEqualStrings("kimi-k3", zen);

    const go = try orchestrationModelId(Host, alloc, .opencode, "go", "kimi-k3");
    defer alloc.free(go);
    try std.testing.expectEqualStrings("go/kimi-k3", go);

    const gateway = try orchestrationModelId(Host, alloc, .gateway, "z-ai", "glm-5.3-flash");
    defer alloc.free(gateway);
    try std.testing.expectEqualStrings("z-ai/glm-5.3-flash", gateway);

    try std.testing.expectError(
        error.InvalidOpenCodeRoute,
        orchestrationModelId(Host, alloc, .opencode, "direct", "kimi-k3"),
    );
    try std.testing.expectError(
        error.OrchestrationProviderNotUnified,
        orchestrationModelId(Host, alloc, .codex, "openai", "gpt-5"),
    );
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

/// Explicitly typed host services for one orchestration agent-run admission.
/// The composition root assembles this contract; this module never reaches
/// into the application object. Borrowed fields reference app-owned state
/// that outlives `start`; the only owned field is the permission-rule
/// snapshot, which `start` moves into the prepared run.
pub fn Services(comptime Host: type) type {
    return struct {
        /// Host allocation used for the prepared run and its strings.
        alloc: Allocator,
        /// Live orchestration admission state: authority, canonical turns,
        /// and the run manager.
        state: *orchestration_app_runtime.State(Host),
        /// Credential resolution services for the routed provider.
        oauth_transport: oauth_transport.Provider,
        secret_store: host.SecretStore,
        /// Owned copy of the permission rules, captured by the composition
        /// root under the permission-authority lock so the projection and
        /// the prepared run observe one consistent rule set. `start` moves
        /// it into the prepared run; `deinit` frees it only when the run
        /// never took it.
        permission_rules: types.PermissionRuleSet = .{},
        /// Effective tool set used to build the run's tool projection.
        /// Static data for the native host profile.
        tool_set: tool_set_contract.ToolSet,
        /// Whether native subagents may be advertised to the run.
        subagent_available: bool,
        /// Base tool context assembled by the composition root after
        /// admission. Borrowed: it embeds app-owned callbacks and runtime
        /// pointers, and the run overrides its provider-derived fields
        /// before use.
        tool_context_base: tool_runtime.Context,
        /// Constant provider bundle set used to select the run's provider.
        providers: provider_set.Set,
        /// Session usage metering shared with the host app.
        usage: *session_usage.Usage,
        /// Whether a Parallel local-search connection exists; selects the
        /// projection's web-search mode.
        parallel_connected: bool,
        /// Parallel connection key borrowed from app connection state.
        parallel_api_key: ?[]const u8 = null,
        /// Web tool runtimes owned by the app, borrowed read-only as
        /// provider/clock/policy templates. Each run receives private
        /// runtimes via `configureOwned`; the host runtimes are never
        /// configured per run.
        web: web_backends.Runtimes,
        /// Prompt policy value: system prompt and per-model overlay.
        policy: prompt_policy.Policy,
        /// Skill catalog view for explicit skill prompt sections.
        skills: skill_invocation.Catalog,
        /// Context limits for skill section budgets.
        context_limits: config_runtime.context_limits.Values,
        /// Live host worker receiving the run's presentation stream.
        /// Borrowed from the app; null keeps the run capture-only.
        live_worker: ?*worker_runtime.WorkerRuntime = null,

        /// Frees the owned permission-rule snapshot unless `start` moved it
        /// into the prepared run. Every other field is borrowed.
        pub fn deinit(self: *@This()) void {
            self.permission_rules.deinit(self.alloc);
            self.* = undefined;
        }
    };
}

/// Pure admission checks for one agent-run request: mode-active, authority
/// match, scope and context-key consistency, and a unified provider. The
/// composition root calls this before assembling active services so a
/// rejected request never mutates shared runtime configuration.
pub fn validateAdmission(
    comptime Host: type,
    state: *const orchestration_app_runtime.State(Host),
    request: Host.AgentRunRequest,
) !void {
    _ = try admit(Host, state, request);
}

fn admit(
    comptime Host: type,
    state: *const orchestration_app_runtime.State(Host),
    request: Host.AgentRunRequest,
) !model_provider.ProviderId {
    if (!state.active) return error.OrchestrationModeInactive;
    if (state.active_source_turn_id != request.authority.source_turn_id) {
        return error.OrchestrationAuthorityMismatch;
    }
    if (!std.mem.eql(
        u64,
        state.instruction_source_turn_ids.items,
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
    if (request.response_schema_json != null and
        (request.response_format_name == null or request.response_format_description == null))
    {
        return error.OrchestrationResponseFormatIdentityMissing;
    }
    const provider = provider_catalog.parse(request.model.provider_id) orelse
        return error.UnknownOrchestrationProvider;
    if (provider_catalog.find(provider).catalog_scope != .unified) {
        return error.OrchestrationProviderNotUnified;
    }
    return provider;
}

fn webSearchMode(
    providers: provider_set.Set,
    parallel_connected: bool,
    provider: model_provider.ProviderId,
) tool_projection.WebSearchMode {
    if (providers.select(provider).capabilities.fx_search) return .provider;
    if (parallel_connected) return .local;
    return .unavailable;
}

pub fn start(
    comptime Host: type,
    services: *Services(Host),
    request: Host.AgentRunRequest,
) !void {
    const provider = try admit(Host, services.state, request);

    var prompt = switch (request.visible_input) {
        .canonical_turn => try services.state.canonical_turns.cloneCanonical(
            services.alloc,
            request.authority.source_turn_id,
            request.authority.instruction_source_turn_ids,
        ),
        .projected => |projected| try services.state.canonical_turns.cloneProjected(
            services.alloc,
            request.authority.source_turn_id,
            request.authority.instruction_source_turn_ids,
            projected.content,
            projected.attachment_references,
        ),
    };
    var owns_prompt = true;
    errdefer if (owns_prompt) worker_runtime.freeQueuedPrompt(services.alloc, prompt);
    const supplemental_context = switch (request.visible_input) {
        .canonical_turn => |canonical| canonical.supplemental_context,
        .projected => "",
    };
    const continued_context = if (request.context_key) |key|
        try services.state.runs.attachContextSurface(
            services.alloc,
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

    try routeOrchestrationCredential(Host, services, &prompt, provider);
    const exact_model = try orchestrationModelId(
        Host,
        services.alloc,
        provider,
        request.model.route,
        request.model.name,
    );
    services.alloc.free(prompt.model);
    prompt.model = exact_model;
    prompt.provider = provider;
    prompt.agent_settings.effort = .auto;
    if (request.model.reasoning_effort) |raw_effort| {
        prompt.agent_settings.effort = ReasoningEffort.parse(raw_effort) orelse
            return error.InvalidOrchestrationReasoningEffort;
    }

    var projection = try tool_projection.buildModelToolProjectionForSet(
        services.alloc,
        services.tool_set,
        .{
            .permission_mode = prompt.permission_mode,
            .permission_rules = services.permission_rules,
            .subagent_available = services.subagent_available,
            .web_search_mode = webSearchMode(
                services.providers,
                services.parallel_connected,
                provider,
            ),
        },
    );
    var owns_projection = true;
    errdefer if (owns_projection) projection.deinit(services.alloc);
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
    // The composition root captured this owned snapshot under the
    // permission-authority lock; it becomes the prepared run's rule set.
    var permission_rules = services.permission_rules;
    services.permission_rules = .{};
    var owns_permission_rules = true;
    errdefer if (owns_permission_rules) permission_rules.deinit(services.alloc);

    var tool_context = services.tool_context_base;
    const bundle = services.providers.select(provider);
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
    // Each run owns its web runtimes and input storage: configuring the
    // shared host runtimes here would let a concurrent run steal this run's
    // credentials and leave dangling borrows once a run is reaped.
    const web = try web_backends.configureOwned(services.alloc, .{
        .fx_search = bundle.capabilities.fx_search,
        .api_key = prompt.api_key,
        .credential_source = prompt.credential_source,
        .gateway_team = prompt.gateway_team,
        .worker_model = prompt.model,
        .gateway_retry_count = builtin_gateway.retry_count,
        .gateway_chat_url = builtin_gateway.defaultChatUrl(),
        .usage = services.usage,
        .usage_allocator = services.alloc,
        .parallel_api_key = services.parallel_api_key,
    }, services.web);
    var owns_web = true;
    errdefer if (owns_web) {
        web.deinit(services.alloc);
        services.alloc.destroy(web);
    };
    tool_context.web_search_backend = web.backends.web_search;
    tool_context.web_fetch_backend = web.backends.web_fetch;
    tool_context.web_search_runtime_ready = web.backends.web_search_runtime_ready;
    if (request.visible_input == .projected) {
        tool_context.context_enabled = false;
    }

    const policy_snapshot = services.policy;
    var strings_transferred = false;
    const system_prompt = try services.alloc.dupe(u8, policy_snapshot.system_prompt);
    errdefer if (!strings_transferred) services.alloc.free(system_prompt);
    const model_prompt_overlay = try orchestrationPromptOverlay(
        services.alloc,
        policy_snapshot.modelPromptOverlay(prompt.model),
        request.system_prompt,
        if (continued_context) "" else supplemental_context,
    );
    errdefer if (!strings_transferred) services.alloc.free(model_prompt_overlay);

    const skills_prompt_section: []u8 = &.{};
    var explicit_skills_prompt_section: []u8 = &.{};
    if (request.visible_input == .canonical_turn) {
        // Routed skill mentions are no longer injected as prompt text;
        // the advertised skill catalog and the skill tool load them.
        const explicit_bindings = try services.alloc.alloc(
            skill_invocation.ExplicitBinding,
            prompt.skill_bindings.len,
        );
        defer services.alloc.free(explicit_bindings);
        for (prompt.skill_bindings, 0..) |binding, index| {
            explicit_bindings[index] = .{
                .name = binding.name,
                .path = binding.path,
            };
        }
        var explicit = try skill_invocation.buildExplicitPromptSection(
            services.alloc,
            services.skills,
            prompt.prompt,
            explicit_bindings,
            services.context_limits,
            null,
        );
        defer explicit.deinit(services.alloc);
        explicit_skills_prompt_section = try services.alloc.dupe(
            u8,
            explicit.text,
        );
        errdefer if (!strings_transferred) services.alloc.free(explicit_skills_prompt_section);
    }

    const run_id = try services.alloc.dupe(u8, request.run_id);
    errdefer if (!strings_transferred) services.alloc.free(run_id);
    const context_key = if (request.context_key) |key|
        try services.alloc.dupe(u8, key)
    else
        null;
    errdefer if (!strings_transferred) {
        if (context_key) |key| services.alloc.free(key);
    };
    const instruction_source_turn_ids = try services.alloc.dupe(
        u64,
        request.authority.instruction_source_turn_ids,
    );
    errdefer if (!strings_transferred) services.alloc.free(instruction_source_turn_ids);
    const response_schema_json = if (request.response_schema_json) |schema|
        try services.alloc.dupe(u8, schema)
    else
        null;
    errdefer if (!strings_transferred) {
        if (response_schema_json) |schema| services.alloc.free(schema);
    };
    const response_format_name = if (request.response_format_name) |name|
        try services.alloc.dupe(u8, name)
    else
        null;
    errdefer if (!strings_transferred) {
        if (response_format_name) |name| services.alloc.free(name);
    };
    const response_format_description = if (request.response_format_description) |description|
        try services.alloc.dupe(u8, description)
    else
        null;
    errdefer if (!strings_transferred) {
        if (response_format_description) |description| services.alloc.free(description);
    };
    const lifecycle_session_id = try services.alloc.dupe(u8, request.run_id);
    errdefer if (!strings_transferred) services.alloc.free(lifecycle_session_id);

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
        .response_format_name = response_format_name,
        .response_format_description = response_format_description,
        .render_assistant_text = request.render_assistant_text,
        .lifecycle_session_id = lifecycle_session_id,
        .live_worker = services.live_worker,
        .web = web,
    };
    var owns_prepared = true;
    errdefer if (owns_prepared) owned_prepared.deinit(services.alloc);
    owns_prompt = false;
    owns_projection = false;
    owns_permission_rules = false;
    owns_web = false;
    strings_transferred = true;
    try services.state.runs.start(owned_prepared);
    owns_prepared = false;
}

/// Drains one orchestration event-loop tick: admits a pending extension
/// turn, applies steering or cancellation, then drains run completions.
/// Owns the turn-lifecycle glue so the composition root stays declarative.
pub fn drainAgentEvents(
    comptime Host: type,
    comptime Extension: type,
    app: anytype,
) !void {
    try startPendingTurn(Host, Extension, app);
    if (app.orchestration.active_source_turn_id != null) {
        if (app.worker.cancellationStopsTurn()) {
            // Cancellation applies to a live mode; a dangling source turn
            // without one is left for steering to observe, as before.
            if (app.orchestration.active) {
                _ = try orchestration_app_runtime.cancelActiveTurn(Host, Extension, app);
            }
        } else {
            try drainSteering(Host, Extension, app);
        }
    }
    try orchestration_app_runtime.drainRunEvents(Host, Extension, app);
}

fn startPendingTurn(
    comptime Host: type,
    comptime Extension: type,
    app: anytype,
) !void {
    const prompt = app.worker.takeExtensionTurnRequest() orelse return;
    var owns_prompt = true;
    defer if (owns_prompt) worker_runtime.freeQueuedPrompt(std.heap.c_allocator, prompt);

    const fallback_user = try types.dupeUserTurn(
        std.heap.c_allocator,
        .{ .text = prompt.prompt, .images = prompt.images },
    );
    var owns_fallback_user = true;
    defer if (owns_fallback_user) types.freeUserTurn(std.heap.c_allocator, fallback_user);

    if (!app.orchestration.active or prompt.executor != .extension) {
        const finished = types.FinishedPrompt{ .turn = .{ .interrupted = .{
            .user = fallback_user,
            .terminal_reason = .failed,
        } } };
        try app.worker.completeExtensionTurn(prompt.turn_id, finished);
        owns_fallback_user = false;
        return;
    }

    const captured = try orchestration_app_runtime.captureCanonicalTurn(
        Host,
        &app.orchestration,
        std.heap.c_allocator,
        prompt,
    );
    owns_prompt = false;
    if (!orchestration_app_runtime.dispatchCanonicalTurn(
        Host,
        Extension,
        app,
        captured,
        prompt.prompt,
    )) {
        const finished = types.FinishedPrompt{ .turn = .{ .interrupted = .{
            .user = fallback_user,
            .terminal_reason = .failed,
        } } };
        try app.worker.completeExtensionTurn(prompt.turn_id, finished);
        owns_fallback_user = false;
    }
}

fn drainSteering(
    comptime Host: type,
    comptime Extension: type,
    app: anytype,
) !void {
    const source_turn_id = app.orchestration.active_source_turn_id orelse return;
    const active_turn_id = app.worker.activeTurnId();
    if (active_turn_id == 0) return;
    const boundary = try app.worker.takeSteeringBoundary(
        std.heap.c_allocator,
        active_turn_id,
        if (app.worker.isCancelRequested())
            worker_runtime.SteeringBoundaryKind.cancelled
        else
            .model,
    );
    const messages = switch (boundary) {
        .continue_turn => |msgs| msgs,
        .none, .handoff, .interrupt => return,
    };
    defer {
        for (messages) |message| std.heap.c_allocator.free(message);
        if (messages.len > 0) std.heap.c_allocator.free(messages);
    }
    for (messages) |message| {
        const captured = try app.orchestration.canonical_turns.captureTextInstruction(
            std.heap.c_allocator,
            source_turn_id,
            message,
        );
        if (!orchestration_app_runtime.dispatchCanonicalInstruction(
            Host,
            Extension,
            app,
            captured,
            message,
        )) return;
    }
}

fn combinedUserForActiveTurn(app: anytype) !types.UserTurn {
    const source_turn_id = app.orchestration.active_source_turn_id orelse
        return error.OrchestrationSourceTurnUnavailable;
    return app.orchestration.canonical_turns.cloneCombinedUserTurn(
        std.heap.c_allocator,
        source_turn_id,
        app.orchestration.instruction_source_turn_ids.items,
    );
}

fn releaseTurnCustody(comptime Host: type, app: anytype) void {
    orchestration_app_runtime.releaseCanonicalCustody(
        Host,
        app.alloc,
        &app.orchestration,
    );
}

pub fn publishAnswer(
    comptime Host: type,
    app: anytype,
    text: []const u8,
) !void {
    const user = try combinedUserForActiveTurn(app);
    errdefer types.freeUserTurn(std.heap.c_allocator, user);
    const answer = try std.heap.c_allocator.dupe(u8, text);
    errdefer std.heap.c_allocator.free(answer);
    const finished = types.FinishedPrompt{ .turn = .{ .assistant = .{
        .user = user,
        .assistant = answer,
    } } };
    try app.worker.completeExtensionTurn(app.worker.activeTurnId(), finished);
    releaseTurnCustody(Host, app);
}

pub fn failTurn(comptime Host: type, app: anytype) !void {
    const user = try combinedUserForActiveTurn(app);
    errdefer types.freeUserTurn(std.heap.c_allocator, user);
    const finished = types.FinishedPrompt{ .turn = .{ .interrupted = .{
        .user = user,
        .terminal_reason = .failed,
    } } };
    try app.worker.completeExtensionTurn(app.worker.activeTurnId(), finished);
    releaseTurnCustody(Host, app);
}

pub fn interruptTurn(app: anytype, user: types.UserTurn) !void {
    const finished = types.FinishedPrompt{ .turn = .{ .interrupted = .{
        .user = user,
    } } };
    try app.worker.completeExtensionTurn(app.worker.activeTurnId(), finished);
}

fn routeOrchestrationCredential(
    comptime Host: type,
    services: *Services(Host),
    prompt: *worker_runtime.QueuedPrompt,
    provider: model_provider.ProviderId,
) !void {
    if (model_provider.authorizesCredential(provider, prompt.credential_source)) return;
    const resolution = try credentials.resolveForProvider(
        services.alloc,
        services.oauth_transport,
        services.secret_store,
        .refresh_if_needed,
        provider,
        prompt.credential_source,
    );
    var credential = resolution.credential orelse return error.OrchestrationCredentialMissing;
    defer credential.deinit(services.alloc);
    const token = try services.alloc.dupe(u8, credential.token);
    errdefer secret.zeroAndFree(services.alloc, token);
    const gateway_team = if (credential.gatewayTeam()) |team|
        try services.alloc.dupe(u8, team)
    else
        null;
    errdefer if (gateway_team) |team| services.alloc.free(team);
    const account_id = if (credential.accountId()) |id|
        try services.alloc.dupe(u8, id)
    else
        null;

    secret.zeroAndFree(services.alloc, prompt.api_key);
    if (prompt.gateway_team) |team| services.alloc.free(team);
    if (prompt.account_id) |id| services.alloc.free(id);
    prompt.api_key = token;
    prompt.gateway_team = gateway_team;
    prompt.account_id = account_id;
    prompt.credential_source = credential.source;
}
