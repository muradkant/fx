const std = @import("std");
const provider_catalog = @import("../auth/provider_catalog.zig");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");
const app_session_runtime = @import("../app/app_session_runtime.zig");
const canonical_turn_store = @import("canonical_turn_store.zig");
const run_manager = @import("run_manager.zig");

pub fn State(comptime Host: type) type {
    return struct {
        engine: ?Host.Engine = null,
        /// Exact immutable extension document selected for this fx session.
        /// Null means this native fx session has no orchestration definition.
        definition_source: ?[]u8 = null,
        definition_metadata: ?Host.DefinitionMetadata = null,
        active: bool = false,
        canonical_turns: canonical_turn_store.Store = .{},
        active_source_turn_id: ?u64 = null,
        instruction_source_turn_ids: std.ArrayList(u64) = .empty,
        runs: run_manager.Manager = .{},
    };
}

pub fn deinit(comptime Host: type, allocator: std.mem.Allocator, state: *State(Host)) void {
    if (state.engine) |engine| engine.deinit(allocator);
    if (state.definition_source) |source| allocator.free(source);
    if (state.definition_metadata) |*metadata| metadata.deinit(allocator);
    state.runs.deinit();
    state.canonical_turns.deinit(allocator);
    state.instruction_source_turn_ids.deinit(allocator);
    state.* = .{};
}

pub fn installDefinition(
    comptime Host: type,
    comptime Extension: type,
    allocator: std.mem.Allocator,
    state: *State(Host),
    source: []const u8,
) !void {
    if (state.active or state.active_source_turn_id != null) {
        return error.OrchestrationSessionActive;
    }
    var metadata = try Extension.inspectDefinition(allocator, source);
    errdefer metadata.deinit(allocator);
    const owned_source = try allocator.dupe(u8, source);
    errdefer allocator.free(owned_source);
    if (state.engine) |engine| engine.deinit(allocator);
    if (state.definition_source) |prior| allocator.free(prior);
    if (state.definition_metadata) |*prior| prior.deinit(allocator);
    state.engine = null;
    state.definition_source = owned_source;
    state.definition_metadata = metadata;
}

pub fn isCommand(comptime Extension: type, input: []const u8) bool {
    return commandPayload(Extension, input) != null;
}

pub fn handleCommand(
    comptime Host: type,
    comptime Extension: type,
    app: anytype,
    input: []const u8,
) !bool {
    const payload = commandPayload(Extension, input) orelse return false;
    try handlePayload(Host, Extension, app, payload);
    return true;
}

/// Enabling orchestration must never hide or strand native child work.
/// Idle and terminal child records remain persisted and become visible
/// again after the extension mode is left. The composition root exposes
/// this check behind its `nativeSubagentWorkActive` seam so fixtures can
/// stub the gate; the recovery and registry logic lives here.
pub fn nativeSubagentWorkActive(app: anytype) !bool {
    const SessionRuntime = app_session_runtime.Runtime(@TypeOf(app.*));
    const host_runtime = SessionRuntime.subagentHost(app) orelse return false;
    host_runtime.requestBackgroundRecovery(io_mod.milliTimestamp()) catch {
        return error.NativeSubagentRecoveryUnsettled;
    };
    if (host_runtime.recoveryState() != .complete) {
        return error.NativeSubagentRecoveryUnsettled;
    }

    var lock = try host_runtime.managed.state_store.acquireLock(app.alloc);
    defer lock.release();
    var registry = try host_runtime.managed.state_store.load(app.alloc);
    defer registry.deinit(app.alloc);
    for (registry.children) |child| {
        switch (child.phase) {
            .running, .awaiting_approval => return true,
            .idle, .interrupted, .finished => {},
        }
    }
    return false;
}

pub fn handlePayload(
    comptime Host: type,
    comptime Extension: type,
    app: anytype,
    payload: []const u8,
) !void {
    const entering = payload.len == 0 or std.ascii.eqlIgnoreCase(payload, "on");
    if (entering) {
        const App = @TypeOf(app.*);
        if (comptime @hasDecl(App, "nativeSubagentWorkActive")) {
            const native_work_active = app.nativeSubagentWorkActive() catch {
                const descriptor = Extension.descriptor();
                try app.writeDomainNotice(.{
                    .topic = descriptor.id,
                    .tone = .@"error",
                    .body = "Fixer mode was not enabled because fx could not prove that native subagent work is idle. Retry after native subagent recovery settles.",
                }, true);
                return;
            };
            if (native_work_active) {
                const descriptor = Extension.descriptor();
                try app.writeDomainNotice(.{
                    .topic = descriptor.id,
                    .tone = .warning,
                    .body = "Fixer mode was not enabled because native fx subagent work is active. Settle or cancel that work first.",
                }, true);
                return;
            }
        }
    }
    const engine = app.orchestration.engine orelse blk: {
        const definition_source = app.orchestration.definition_source orelse {
            const descriptor = Extension.descriptor();
            try app.writeDomainNotice(.{
                .topic = descriptor.id,
                .tone = .@"error",
                .body = "No orchestration definition is selected for this session.",
            }, true);
            return;
        };
        const created = Extension.create(app.alloc, .{
            .definition_source = definition_source,
        }) catch |err| {
            try writeFailure(Extension, app, err);
            return;
        };
        app.orchestration.engine = created;
        break :blk created;
    };
    const App = @TypeOf(app.*);
    const sink = intentSink(Host, Extension, App, app);

    if (entering) {
        var provider_storage: [provider_catalog.entries.len]Host.ProviderDescriptor = undefined;
        var provider_count: usize = 0;
        for (provider_catalog.entries) |entry| {
            const bundle = app.providerSet().select(entry.id);
            if (bundle.agent_stream == null or bundle.model_catalog == null) continue;
            provider_storage[provider_count] = .{
                .id = entry.slug,
                .display_name = entry.name,
                .catalog_scope = switch (entry.catalog_scope) {
                    .provider_native => .provider_native,
                    .unified => .unified,
                },
            };
            provider_count += 1;
        }
        engine.dispatch(.{ .enter = .{
            .conversation_id = app.orchestrationConversationId(),
            .workspace_path = app.workspace_root,
            .providers = provider_storage[0..provider_count],
        } }, sink) catch |err| try writeFailure(Extension, app, err);
        return;
    }
    if (std.ascii.eqlIgnoreCase(payload, "off")) {
        _ = try cancelActiveTurn(Host, Extension, app);
        engine.dispatch(.leave, sink) catch |err| try writeFailure(Extension, app, err);
        return;
    }

    const descriptor = Extension.descriptor();
    try app.writeDomainNotice(.{
        .topic = descriptor.id,
        .tone = .@"error",
        .body = descriptor.usage,
    }, true);
}

pub fn captureCanonicalTurn(
    comptime Host: type,
    state: *State(Host),
    allocator: std.mem.Allocator,
    prompt: @import("../agent/worker_runtime.zig").QueuedPrompt,
) !canonical_turn_store.Capture {
    return state.canonical_turns.captureOwned(allocator, prompt);
}

/// Dispatches a turn that has already transferred into fx custody. Extension
/// failures are isolated and release that custody instead of falling back to
/// the ordinary single-agent queue with altered semantics.
pub fn dispatchCanonicalTurn(
    comptime Host: type,
    comptime Extension: type,
    app: anytype,
    captured: canonical_turn_store.Capture,
    text: []const u8,
) bool {
    const engine = app.orchestration.engine orelse {
        releaseFailedCanonicalTurn(Extension, app, captured, error.OrchestrationEngineUnavailable);
        return false;
    };
    app.orchestration.active_source_turn_id = captured.source_turn_id;
    const App = @TypeOf(app.*);
    var session_id_buffer: [64]u8 = undefined;
    const session_id = std.fmt.bufPrint(
        &session_id_buffer,
        "fixer-turn-{d}",
        .{captured.source_turn_id},
    ) catch {
        releaseFailedCanonicalTurn(Extension, app, captured, error.SourceTurnIdExhausted);
        return false;
    };
    const source = app.orchestration.canonical_turns.borrow(
        captured.source_turn_id,
    ) orelse {
        releaseFailedCanonicalTurn(
            Extension,
            app,
            captured,
            error.OrchestrationSourceTurnUnavailable,
        );
        return false;
    };
    const conversation_history = hostConversationHistory(
        Host,
        app.alloc,
        source.history,
    ) catch |err| {
        releaseFailedCanonicalTurn(Extension, app, captured, err);
        return false;
    };
    defer app.alloc.free(conversation_history);
    engine.dispatch(.{ .user_turn = .{
        .session_id = session_id,
        .source_turn_id = captured.source_turn_id,
        .text = text,
        .attachment_references = captured.attachment_references,
        .conversation_history = conversation_history,
    } }, intentSink(Host, Extension, App, app)) catch |err| {
        releaseFailedCanonicalTurn(Extension, app, captured, err);
        return false;
    };
    return true;
}

/// Adds another canonical user input to the active Fixer session without
/// replacing its root authority or creating a second orchestration session.
pub fn dispatchCanonicalInstruction(
    comptime Host: type,
    comptime Extension: type,
    app: anytype,
    captured: canonical_turn_store.Capture,
    text: []const u8,
) bool {
    if (app.orchestration.active_source_turn_id == null) {
        releaseFailedCanonicalTurn(
            Extension,
            app,
            captured,
            error.OrchestrationSourceTurnUnavailable,
        );
        return false;
    }
    const engine = app.orchestration.engine orelse {
        releaseFailedCanonicalTurn(
            Extension,
            app,
            captured,
            error.OrchestrationEngineUnavailable,
        );
        return false;
    };
    app.orchestration.instruction_source_turn_ids.ensureUnusedCapacity(
        app.alloc,
        1,
    ) catch |err| {
        releaseFailedCanonicalTurn(Extension, app, captured, err);
        return false;
    };
    app.orchestration.instruction_source_turn_ids.appendAssumeCapacity(
        captured.source_turn_id,
    );
    const App = @TypeOf(app.*);
    const sink = intentSink(Host, Extension, App, app);
    engine.dispatch(.{ .user_instruction = .{
        .source_turn_id = captured.source_turn_id,
        .text = text,
        .attachment_references = captured.attachment_references,
    } }, sink) catch |err| {
        writeFailure(Extension, app, err) catch |notice_err| {
            app.traceOrchestrationFailure(Extension.descriptor().id, notice_err);
        };
        abortActiveTurnAfterDispatchFailure(
            Host,
            Extension,
            App,
            app,
            engine,
            sink,
        );
        return false;
    };
    return true;
}

fn hostConversationHistory(
    comptime Host: type,
    allocator: std.mem.Allocator,
    history: []const types.HistoryTurn,
) ![]Host.ConversationTurn {
    const projected = try allocator.alloc(Host.ConversationTurn, history.len);
    for (history, 0..) |turn, index| {
        projected[index] = switch (turn) {
            .assistant => |entry| .{
                .ordinal = index + 1,
                .status = .completed,
                .task = entry.user.text,
                .answer = entry.assistant,
            },
            .interrupted => |entry| .{
                .ordinal = index + 1,
                .status = switch (entry.terminal_reason) {
                    .cancelled => .cancelled,
                    .failed => .failed,
                },
                .task = entry.user.text,
                .answer = entry.assistant orelse "",
            },
            .compacted_summary => |entry| .{
                .ordinal = index + 1,
                .status = .compacted,
                .summary = entry.summary,
                .omitted_turn_count = entry.removed_turn_count,
                .compaction_count = entry.compaction_count,
            },
        };
    }
    return projected;
}

pub fn drainRunEvents(
    comptime Host: type,
    comptime Extension: type,
    app: anytype,
) !void {
    var events = app.orchestration.runs.takeEvents();
    defer events.deinit(app.alloc);
    const engine = app.orchestration.engine orelse {
        for (events.items) |event| event.deinit(app.alloc);
        return;
    };
    const App = @TypeOf(app.*);
    for (events.items) |event| {
        const terminal_run_id = event.terminalRunId();
        const host_event: Host.HostEvent = switch (event) {
            .started => |started| .{ .agent_run_started = .{
                .run_id = started.run_id,
            } },
            .completed => |completed| .{ .agent_run_completed = .{
                .run_id = completed.run_id,
                .output = completed.output,
                .input_tokens = completed.input_tokens,
                .output_tokens = completed.output_tokens,
            } },
            .failed => |failed| .{ .agent_run_failed = .{
                .run_id = failed.run_id,
                .message = failed.message,
                .interrupted = failed.interrupted,
                .kind = switch (failed.kind) {
                    .interrupted => .interrupted,
                    .authentication => .authentication,
                    .forbidden => .forbidden,
                    .invalid_request => .invalid_request,
                    .request_too_large => .request_too_large,
                    .rate_limited => .rate_limited,
                    .provider_unavailable => .provider_unavailable,
                    .provider_error => .provider_error,
                    .runtime => .runtime,
                },
                .http_status = failed.http_status,
            } },
        };
        const sink = intentSink(Host, Extension, App, app);
        engine.dispatch(host_event, sink) catch |err| {
            writeFailure(Extension, app, err) catch |notice_err| {
                app.traceOrchestrationFailure(Extension.descriptor().id, notice_err);
            };
            abortActiveTurnAfterDispatchFailure(
                Host,
                Extension,
                App,
                app,
                engine,
                sink,
            );
        };
        if (terminal_run_id) |run_id| {
            _ = app.orchestration.runs.reap(run_id);
        }
        event.deinit(app.alloc);
    }
}

fn abortActiveTurnAfterDispatchFailure(
    comptime Host: type,
    comptime Extension: type,
    comptime App: type,
    app: *App,
    engine: Host.Engine,
    sink: Host.IntentSink,
) void {
    engine.dispatch(.cancel_requested, sink) catch |err| {
        app.traceOrchestrationFailure(Extension.descriptor().id, err);
    };
    if (comptime @hasDecl(App, "failOrchestrationTurn")) {
        app.failOrchestrationTurn() catch |err| {
            app.traceOrchestrationFailure(Extension.descriptor().id, err);
        };
    }
}

pub fn cancelActiveTurn(
    comptime Host: type,
    comptime Extension: type,
    app: anytype,
) !bool {
    const source_turn_id = app.orchestration.active_source_turn_id orelse
        return false;
    const engine = app.orchestration.engine orelse return false;
    const user = try app.orchestration.canonical_turns.cloneCombinedUserTurn(
        std.heap.c_allocator,
        source_turn_id,
        app.orchestration.instruction_source_turn_ids.items,
    );
    var owns_user = true;
    defer if (owns_user) types.freeUserTurn(std.heap.c_allocator, user);
    const App = @TypeOf(app.*);
    app.worker.requestCancel();
    engine.dispatch(
        .cancel_requested,
        intentSink(Host, Extension, App, app),
    ) catch |err| {
        try writeFailure(Extension, app, err);
    };
    if (comptime @hasDecl(App, "interruptOrchestrationTurn")) {
        try app.interruptOrchestrationTurn(user);
        owns_user = false;
    } else {
        return error.OrchestrationIntentNotConnected;
    }
    releaseCanonicalCustody(Host, app.alloc, &app.orchestration);
    return true;
}

pub fn releaseCanonicalCustody(
    comptime Host: type,
    allocator: std.mem.Allocator,
    state: *State(Host),
) void {
    if (state.active_source_turn_id) |source_turn_id| {
        _ = state.canonical_turns.remove(allocator, source_turn_id);
    }
    for (state.instruction_source_turn_ids.items) |source_turn_id| {
        _ = state.canonical_turns.remove(allocator, source_turn_id);
    }
    state.instruction_source_turn_ids.clearRetainingCapacity();
    state.active_source_turn_id = null;
}

fn releaseFailedCanonicalTurn(
    comptime Extension: type,
    app: anytype,
    captured: canonical_turn_store.Capture,
    err: anyerror,
) void {
    _ = app.orchestration.canonical_turns.remove(
        app.alloc,
        captured.source_turn_id,
    );
    for (app.orchestration.instruction_source_turn_ids.items) |source_turn_id| {
        _ = app.orchestration.canonical_turns.remove(app.alloc, source_turn_id);
    }
    app.orchestration.instruction_source_turn_ids.clearRetainingCapacity();
    app.orchestration.active_source_turn_id = null;
    writeFailure(Extension, app, err) catch |notice_err| {
        app.traceOrchestrationFailure(Extension.descriptor().id, notice_err);
    };
}

fn IntentEmitter(
    comptime Host: type,
    comptime Extension: type,
    comptime App: type,
) type {
    return struct {
        fn emit(context: *anyopaque, intent: Host.Intent) !void {
            const target: *App = @ptrCast(@alignCast(context));
            const descriptor = Extension.descriptor();
            switch (intent) {
                .mode_entered => |entered| {
                    target.orchestration.active = true;
                    if (comptime @hasDecl(App, "orchestrationModeEntered")) {
                        target.orchestrationModeEntered();
                    }
                    try target.writeDomainNotice(.{
                        .topic = descriptor.id,
                        .tone = .neutral,
                        .body = entered.notice,
                    }, true);
                },
                .mode_left => |left| {
                    target.orchestration.active = false;
                    if (comptime @hasDecl(App, "orchestrationModeLeft")) {
                        target.orchestrationModeLeft();
                    }
                    try target.writeDomainNotice(.{
                        .topic = descriptor.id,
                        .tone = .neutral,
                        .body = left.notice,
                    }, true);
                },
                .notice => |notice| try target.writeDomainNotice(.{
                    .topic = descriptor.id,
                    .tone = switch (notice.tone) {
                        .info => .neutral,
                        .warning => .warning,
                        .failure => .@"error",
                    },
                    .body = notice.text,
                }, true),
                .trace => |record| target.traceOrchestrationRecord(
                    descriptor.id,
                    record,
                ),
                .start_agent_run => |request| {
                    if (comptime @hasDecl(App, "startOrchestrationAgentRun")) {
                        try target.startOrchestrationAgentRun(request);
                    } else {
                        return error.OrchestrationIntentNotConnected;
                    }
                },
                .cancel_agent_run => |request| {
                    if (comptime @hasDecl(App, "cancelOrchestrationAgentRun")) {
                        try target.cancelOrchestrationAgentRun(request.run_id);
                    } else {
                        return error.OrchestrationIntentNotConnected;
                    }
                },
                .publish_answer => |answer| {
                    if (comptime @hasDecl(App, "publishOrchestrationAnswer")) {
                        try target.publishOrchestrationAnswer(answer.agent_id, answer.text);
                    } else {
                        return error.OrchestrationIntentNotConnected;
                    }
                },
                .turn_failed => {
                    if (comptime @hasDecl(App, "failOrchestrationTurn")) {
                        try target.failOrchestrationTurn();
                    } else {
                        return error.OrchestrationIntentNotConnected;
                    }
                },
            }
        }
    };
}

fn intentSink(
    comptime Host: type,
    comptime Extension: type,
    comptime App: type,
    app: *App,
) Host.IntentSink {
    return .{
        .context = app,
        .emit_fn = IntentEmitter(Host, Extension, App).emit,
    };
}

fn commandPayload(comptime Extension: type, input: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    const command = Extension.descriptor().slash_command;
    if (!std.mem.startsWith(u8, trimmed, command)) return null;
    if (trimmed.len == command.len) return "";
    if (!std.ascii.isWhitespace(trimmed[command.len])) return null;
    return std.mem.trim(u8, trimmed[command.len..], " \t\r\n");
}

fn writeFailure(comptime Extension: type, app: anytype, err: anyerror) !void {
    const descriptor = Extension.descriptor();
    app.traceOrchestrationFailure(descriptor.id, err);
    try app.writeDomainNotice(.{
        .topic = descriptor.id,
        .tone = .@"error",
        .body = "The orchestration extension failed. Native fx remains available.",
    }, true);
}

test "durable fx history crosses the host seam as secret-free semantic turns" {
    const Host = @import("fx_orchestration_host");
    const history = [_]types.HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("first task") },
            .assistant = @constCast("first answer"),
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("failed task") },
            .terminal_reason = .failed,
        } },
        .{ .compacted_summary = .{
            .summary = @constCast("older exact history summary"),
            .removed_turn_count = 4,
            .compaction_count = 2,
        } },
    };
    const projected = try hostConversationHistory(Host, std.testing.allocator, &history);
    defer std.testing.allocator.free(projected);
    try std.testing.expectEqual(@as(usize, 3), projected.len);
    try std.testing.expectEqual(Host.ConversationTurnStatus.completed, projected[0].status);
    try std.testing.expectEqualStrings("first task", projected[0].task);
    try std.testing.expectEqualStrings("first answer", projected[0].answer);
    try std.testing.expectEqual(Host.ConversationTurnStatus.failed, projected[1].status);
    try std.testing.expectEqual(Host.ConversationTurnStatus.compacted, projected[2].status);
    try std.testing.expectEqual(@as(usize, 4), projected[2].omitted_turn_count);
}

test "extension failure becomes a notice instead of escaping the host event loop" {
    const Host = @import("fx_orchestration_host");
    const Extension = struct {
        const EngineState = struct {
            fn dispatch(_: *anyopaque, _: Host.HostEvent, _: Host.IntentSink) !void {
                return error.InjectedExtensionFailure;
            }

            fn deinit(context: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(context));
                allocator.destroy(self);
            }
        };

        const vtable = Host.Engine.VTable{
            .dispatch = EngineState.dispatch,
            .deinit = EngineState.deinit,
        };

        fn descriptor() Host.ExtensionDescriptor {
            return .{
                .id = "failing-extension",
                .display_name = "Failing extension",
                .slash_command = "/failing",
                .summary = "Exercise host failure isolation",
                .usage = "Use /failing or /failing off.",
                .definition_kind = "fixture",
                .definition_collection = "fixtures",
            };
        }

        fn inspectDefinition(allocator: std.mem.Allocator, _: []const u8) !Host.DefinitionMetadata {
            return .{
                .id = try allocator.dupe(u8, "fixture"),
                .revision = 1,
                .digest = [_]u8{'0'} ** 64,
                .name = try allocator.dupe(u8, "Fixture"),
            };
        }

        fn create(allocator: std.mem.Allocator, _: Host.CreateOptions) !Host.Engine {
            const state = try allocator.create(EngineState);
            state.* = .{};
            return .{ .context = state, .vtable = &vtable };
        }
    };
    const FakeBundle = struct {
        agent_stream: ?u8 = null,
        model_catalog: ?u8 = null,
    };
    const FakeProviderSet = struct {
        fn select(_: @This(), _: anytype) FakeBundle {
            return .{};
        }
    };
    const FakeWorker = struct {
        fn pushEvent(_: *@This(), _: std.mem.Allocator, _: anytype) !void {}

        fn requestCancel(_: *@This()) void {}
    };
    const FakeApp = struct {
        const Tone = enum { neutral, warning, @"error" };
        const Notice = struct {
            topic: []const u8,
            tone: Tone,
            body: []const u8,
        };

        alloc: std.mem.Allocator,
        orchestration: State(Host) = .{},
        workspace_root: []const u8 = "/workspace",
        worker: FakeWorker = .{},
        notice_count: usize = 0,
        last_notice: []const u8 = "",

        fn providerSet(_: *@This()) FakeProviderSet {
            return .{};
        }

        fn orchestrationConversationId(_: *@This()) []const u8 {
            return "conversation";
        }

        fn traceOrchestrationFailure(_: *@This(), _: []const u8, _: anyerror) void {}

        fn traceOrchestrationRecord(_: *@This(), _: []const u8, _: Host.TraceRecord) void {}

        fn writeDomainNotice(self: *@This(), notice: Notice, _: bool) !void {
            self.notice_count += 1;
            self.last_notice = notice.body;
        }
    };

    var app = FakeApp{ .alloc = std.testing.allocator };
    defer deinit(Host, app.alloc, &app.orchestration);
    app.orchestration.definition_source = try app.alloc.dupe(u8, "fixture");
    try std.testing.expect(try handleCommand(Host, Extension, &app, "/failing"));
    try std.testing.expectEqual(@as(usize, 1), app.notice_count);
    try std.testing.expectEqualStrings(
        "The orchestration extension failed. Native fx remains available.",
        app.last_notice,
    );
    try std.testing.expect(!app.orchestration.active);
}

test "active native subagent work refuses orchestration before extension creation" {
    const Host = @import("fx_orchestration_host");
    const Extension = struct {
        var create_count: usize = 0;

        fn descriptor() Host.ExtensionDescriptor {
            return .{
                .id = "test-extension",
                .display_name = "Test extension",
                .slash_command = "/test",
                .summary = "Exercise native-subagent isolation",
                .usage = "Use /test or /test off.",
                .definition_kind = "fixture",
                .definition_collection = "fixtures",
            };
        }

        fn inspectDefinition(allocator: std.mem.Allocator, _: []const u8) !Host.DefinitionMetadata {
            return .{
                .id = try allocator.dupe(u8, "fixture"),
                .revision = 1,
                .digest = [_]u8{'0'} ** 64,
                .name = try allocator.dupe(u8, "Fixture"),
            };
        }

        fn create(_: std.mem.Allocator, _: Host.CreateOptions) !Host.Engine {
            create_count += 1;
            return error.UnexpectedExtensionCreation;
        }
    };
    const FakeBundle = struct {
        agent_stream: ?u8 = null,
        model_catalog: ?u8 = null,
    };
    const FakeProviderSet = struct {
        fn select(_: @This(), _: anytype) FakeBundle {
            return .{};
        }
    };
    const FakeWorker = struct {
        fn pushEvent(_: *@This(), _: std.mem.Allocator, _: anytype) !void {}

        fn requestCancel(_: *@This()) void {}
    };
    const FakeApp = struct {
        const Tone = enum { neutral, warning, @"error" };
        const Notice = struct {
            topic: []const u8,
            tone: Tone,
            body: []const u8,
        };

        alloc: std.mem.Allocator,
        orchestration: State(Host) = .{},
        workspace_root: []const u8 = "/workspace",
        worker: FakeWorker = .{},
        notice_count: usize = 0,
        last_notice: []const u8 = "",

        fn providerSet(_: *@This()) FakeProviderSet {
            return .{};
        }

        fn orchestrationConversationId(_: *@This()) []const u8 {
            return "conversation";
        }

        fn nativeSubagentWorkActive(_: *@This()) !bool {
            return true;
        }

        fn traceOrchestrationFailure(_: *@This(), _: []const u8, _: anyerror) void {}

        fn traceOrchestrationRecord(_: *@This(), _: []const u8, _: Host.TraceRecord) void {}

        fn writeDomainNotice(self: *@This(), notice: Notice, _: bool) !void {
            self.notice_count += 1;
            self.last_notice = notice.body;
        }
    };

    Extension.create_count = 0;
    var app = FakeApp{ .alloc = std.testing.allocator };
    try std.testing.expect(try handleCommand(Host, Extension, &app, "/test"));
    try std.testing.expectEqual(@as(usize, 0), Extension.create_count);
    try std.testing.expectEqual(@as(usize, 1), app.notice_count);
    try std.testing.expectEqualStrings(
        "Fixer mode was not enabled because native fx subagent work is active. Settle or cancel that work first.",
        app.last_notice,
    );
    try std.testing.expect(!app.orchestration.active);
}

test "unsettled native subagent recovery fails orchestration admission closed" {
    const Host = @import("fx_orchestration_host");
    const Extension = struct {
        var create_count: usize = 0;

        fn descriptor() Host.ExtensionDescriptor {
            return .{
                .id = "test-extension",
                .display_name = "Test extension",
                .slash_command = "/test",
                .summary = "Exercise native-subagent isolation",
                .usage = "Use /test or /test off.",
                .definition_kind = "fixture",
                .definition_collection = "fixtures",
            };
        }

        fn inspectDefinition(allocator: std.mem.Allocator, _: []const u8) !Host.DefinitionMetadata {
            return .{
                .id = try allocator.dupe(u8, "fixture"),
                .revision = 1,
                .digest = [_]u8{'0'} ** 64,
                .name = try allocator.dupe(u8, "Fixture"),
            };
        }

        fn create(_: std.mem.Allocator, _: Host.CreateOptions) !Host.Engine {
            create_count += 1;
            return error.UnexpectedExtensionCreation;
        }
    };
    const FakeBundle = struct {
        agent_stream: ?u8 = null,
        model_catalog: ?u8 = null,
    };
    const FakeProviderSet = struct {
        fn select(_: @This(), _: anytype) FakeBundle {
            return .{};
        }
    };
    const FakeWorker = struct {
        fn pushEvent(_: *@This(), _: std.mem.Allocator, _: anytype) !void {}

        fn requestCancel(_: *@This()) void {}
    };
    const FakeApp = struct {
        const Tone = enum { neutral, warning, @"error" };
        const Notice = struct {
            topic: []const u8,
            tone: Tone,
            body: []const u8,
        };

        alloc: std.mem.Allocator,
        orchestration: State(Host) = .{},
        workspace_root: []const u8 = "/workspace",
        worker: FakeWorker = .{},
        notice_count: usize = 0,
        last_notice: []const u8 = "",

        fn providerSet(_: *@This()) FakeProviderSet {
            return .{};
        }

        fn orchestrationConversationId(_: *@This()) []const u8 {
            return "conversation";
        }

        fn nativeSubagentWorkActive(_: *@This()) !bool {
            return error.RecoveryUnsettled;
        }

        fn traceOrchestrationFailure(_: *@This(), _: []const u8, _: anyerror) void {}

        fn traceOrchestrationRecord(_: *@This(), _: []const u8, _: Host.TraceRecord) void {}

        fn writeDomainNotice(self: *@This(), notice: Notice, _: bool) !void {
            self.notice_count += 1;
            self.last_notice = notice.body;
        }
    };

    Extension.create_count = 0;
    var app = FakeApp{ .alloc = std.testing.allocator };
    try std.testing.expect(try handleCommand(Host, Extension, &app, "/test on"));
    try std.testing.expectEqual(@as(usize, 0), Extension.create_count);
    try std.testing.expectEqual(@as(usize, 1), app.notice_count);
    try std.testing.expectEqualStrings(
        "Fixer mode was not enabled because fx could not prove that native subagent work is idle. Retry after native subagent recovery settles.",
        app.last_notice,
    );
    try std.testing.expect(!app.orchestration.active);
}
