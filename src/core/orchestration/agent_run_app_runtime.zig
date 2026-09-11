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

test "Fixer preserves complete Cline model identities" {
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
        /// Web tool runtimes owned by the app; configured per run.
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
    const configured_backends = web_backends.configure(.{
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
    tool_context.web_search_backend = configured_backends.web_search;
    tool_context.web_fetch_backend = configured_backends.web_fetch;
    tool_context.web_search_runtime_ready = configured_backends.web_search_runtime_ready;
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
        .lifecycle_session_id = lifecycle_session_id,
        .live_worker = services.live_worker,
    };
    var owns_prepared = true;
    errdefer if (owns_prepared) owned_prepared.deinit(services.alloc);
    owns_prompt = false;
    owns_projection = false;
    owns_permission_rules = false;
    strings_transferred = true;
    try services.state.runs.start(owned_prepared);
    owns_prepared = false;
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
