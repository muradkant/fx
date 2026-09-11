const std = @import("std");
const isolated_run = @import("../agent/isolated_run.zig");
const run_failure = @import("../agent/run_failure.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const session_runtime = @import("../session/session.zig");
const tool_projection = @import("../tooling/tool_projection.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");
const permission_request = @import("../permissions/permission_request.zig");
const diff_mod = @import("../output/diff.zig");

const Allocator = std.mem.Allocator;

const ContextSurface = struct {
    key: []u8,
    source_turn_id: u64,
    instruction_source_turn_ids: []u64,
    history: []types.HistoryTurn,

    fn deinit(self: *ContextSurface, alloc: Allocator) void {
        alloc.free(self.key);
        alloc.free(self.instruction_source_turn_ids);
        types.freeHistoryTurnSlice(alloc, self.history);
        self.* = undefined;
    }
};

pub const Prepared = struct {
    run_id: []u8,
    context_key: ?[]u8,
    source_turn_id: u64,
    instruction_source_turn_ids: []u64,
    prompt: worker_runtime.QueuedPrompt,
    tool_context: tool_runtime.Context,
    tool_projection: tool_projection.EffectiveToolProjection,
    permission_rules: types.PermissionRuleSet,
    system_prompt: []u8,
    model_prompt_overlay: ?[]u8,
    skills_prompt_section: []u8,
    explicit_skills_prompt_section: []u8,
    response_schema_json: ?[]u8,
    lifecycle_session_id: []u8,
    /// Live host worker receiving the run's presentation stream. Borrowed:
    /// it outlives the run. Null keeps the run capture-only.
    live_worker: ?*worker_runtime.WorkerRuntime = null,

    pub fn deinit(self: *Prepared, alloc: Allocator) void {
        alloc.free(self.run_id);
        if (self.context_key) |key| alloc.free(key);
        alloc.free(self.instruction_source_turn_ids);
        worker_runtime.freeQueuedPrompt(alloc, self.prompt);
        self.tool_projection.deinit(alloc);
        self.permission_rules.deinit(alloc);
        alloc.free(self.system_prompt);
        if (self.model_prompt_overlay) |overlay| alloc.free(overlay);
        alloc.free(self.skills_prompt_section);
        alloc.free(self.explicit_skills_prompt_section);
        if (self.response_schema_json) |schema| alloc.free(schema);
        alloc.free(self.lifecycle_session_id);
        self.* = undefined;
    }
};

pub const Event = union(enum) {
    started: struct { run_id: []u8 },
    completed: struct {
        run_id: []u8,
        output: []u8,
        input_tokens: u64,
        output_tokens: u64,
    },
    failed: struct {
        run_id: []u8,
        message: []u8,
        interrupted: bool,
        kind: run_failure.Kind = .runtime,
        http_status: ?u16 = null,
    },

    pub fn deinit(self: Event, alloc: Allocator) void {
        switch (self) {
            .started => |event| alloc.free(event.run_id),
            .completed => |event| {
                alloc.free(event.run_id);
                alloc.free(event.output);
            },
            .failed => |event| {
                alloc.free(event.run_id);
                alloc.free(event.message);
            },
        }
    }

    pub fn terminalRunId(self: Event) ?[]const u8 {
        return switch (self) {
            .started => null,
            .completed => |event| event.run_id,
            .failed => |event| event.run_id,
        };
    }
};

const Run = struct {
    manager: *Manager,
    prepared: Prepared,
    worker: worker_runtime.WorkerRuntime = .{},
    session: session_runtime.SessionRuntime = session_runtime.SessionRuntime.initWithProviders(32, .{}),
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    fn deinit(self: *Run, alloc: Allocator) void {
        self.worker.deinit(alloc);
        self.session.deinit(alloc);
        self.prepared.deinit(alloc);
        alloc.destroy(self);
    }

    fn main(self: *Run) void {
        self.worker.beginIsolatedProcessing(self.prepared.prompt.turn_id) catch |err| {
            self.manager.pushFailed(
                self.prepared.run_id,
                @errorName(err),
                false,
            ) catch {};
            return;
        };
        defer self.worker.finishProcessing();
        self.manager.pushStarted(self.prepared.run_id) catch {
            self.manager.pushFailed(
                self.prepared.run_id,
                "fx could not publish orchestration run admission.",
                false,
            ) catch {};
            return;
        };
        self.prepared.tool_context.permission_rules = self.prepared.permission_rules;
        if (self.prepared.prompt.history.len > 0) {
            self.session.restore(
                self.manager.alloc,
                session_runtime.ConversationLanguage.default(),
                self.prepared.prompt.history,
            ) catch |err| {
                self.manager.pushFailed(
                    self.prepared.run_id,
                    @errorName(err),
                    false,
                ) catch {};
                return;
            };
        }
        const result = isolated_run.run(.{
            .alloc = self.manager.alloc,
            .worker = &self.worker,
            .session = &self.session,
            .tool_context = self.prepared.tool_context,
            .lifecycle_session_id = self.prepared.lifecycle_session_id,
            .system_prompt = self.prepared.system_prompt,
            .model_prompt_overlay = self.prepared.model_prompt_overlay,
            .skills_prompt_section = self.prepared.skills_prompt_section,
            .explicit_skills_prompt_section = self.prepared.explicit_skills_prompt_section,
            .advertised_tool_names = self.prepared.tool_projection.advertised_names,
            .advertised_functions = self.prepared.tool_projection.advertised_functions,
            .custom_tool_guidance = self.prepared.tool_projection.custom_guidance,
            .response_schema_json = self.prepared.response_schema_json,
            .live_worker = self.prepared.live_worker,
        }, &self.prepared.prompt, &self.cancel) catch |err| {
            self.manager.pushFailed(
                self.prepared.run_id,
                @errorName(err),
                err == error.Cancelled or self.cancel.load(.seq_cst),
            ) catch {};
            return;
        };
        defer result.deinit(self.manager.alloc);
        if (result.outcome != .completed) {
            if (result.failure) |failure| {
                self.manager.pushFailure(
                    self.prepared.run_id,
                    failure,
                    result.outcome == .interrupted,
                ) catch {};
            } else {
                self.manager.pushFailed(
                    self.prepared.run_id,
                    "fx agent run did not complete.",
                    result.outcome == .interrupted,
                ) catch {};
            }
            return;
        }
        if (self.prepared.context_key) |key| {
            const history = self.session.snapshotHistory(self.manager.alloc) catch |err| {
                self.manager.pushFailed(
                    self.prepared.run_id,
                    @errorName(err),
                    false,
                ) catch {};
                return;
            };
            self.manager.commitContextSurface(
                key,
                self.prepared.source_turn_id,
                self.prepared.instruction_source_turn_ids,
                history,
            ) catch |err| {
                types.freeHistoryTurnSlice(self.manager.alloc, history);
                self.manager.pushFailed(
                    self.prepared.run_id,
                    @errorName(err),
                    false,
                ) catch {};
                return;
            };
        }
        self.manager.pushCompleted(
            self.prepared.run_id,
            result.output,
            result.input_tokens,
            result.output_tokens,
        ) catch {};
    }
};

pub const Manager = struct {
    const ApprovalBinding = struct {
        public_request_id: u64,
        local_request_id: u64,
        run: *Run,
    };

    alloc: Allocator = std.heap.c_allocator,
    mutex: std.Io.Mutex = .init,
    runs: std.ArrayList(*Run) = .empty,
    events: std.ArrayList(Event) = .empty,
    context_surfaces: std.ArrayList(ContextSurface) = .empty,
    next_approval_id: u64 = 1 << 63,
    approval_binding: ?ApprovalBinding = null,
    question_binding: ?*Run = null,

    pub fn deinit(self: *Manager) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        for (self.runs.items) |run| {
            run.cancel.store(true, .seq_cst);
            run.worker.requestCancel();
        }
        const runs = self.runs;
        self.runs = .empty;
        const events = self.events;
        self.events = .empty;
        const context_surfaces = self.context_surfaces;
        self.context_surfaces = .empty;
        self.mutex.unlock(io_mod.getIo());

        for (runs.items) |run| {
            if (run.thread) |thread| thread.join();
            run.deinit(self.alloc);
        }
        var owned_runs = runs;
        owned_runs.deinit(self.alloc);
        var owned_events = events;
        for (owned_events.items) |event| event.deinit(self.alloc);
        owned_events.deinit(self.alloc);
        var owned_surfaces = context_surfaces;
        for (owned_surfaces.items) |*surface| surface.deinit(self.alloc);
        owned_surfaces.deinit(self.alloc);
        self.* = .{};
    }

    /// Restores the exact fx-owned model/tool history for one context-bearing
    /// extension identity. Repeated work on the same canonical authority uses
    /// the supplied runtime snapshot as the new user message instead of
    /// duplicating the entire root turn and its images.
    pub fn attachContextSurface(
        self: *Manager,
        alloc: Allocator,
        key: []const u8,
        source_turn_id: u64,
        instruction_source_turn_ids: []const u64,
        continuation_prompt: []const u8,
        prompt: *worker_runtime.QueuedPrompt,
    ) !bool {
        if (key.len == 0) return error.EmptyContextSurfaceKey;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const surface = self.findContextSurface(key) orelse return false;
        const same_authority = surface.source_turn_id == source_turn_id and
            std.mem.eql(
                u64,
                surface.instruction_source_turn_ids,
                instruction_source_turn_ids,
            );
        if (same_authority and std.mem.trim(u8, continuation_prompt, " \t\r\n").len == 0) {
            return error.EmptyContextContinuation;
        }
        const history = try dupeHistory(alloc, surface.history);
        errdefer types.freeHistoryTurnSlice(alloc, history);
        const next_prompt = if (same_authority)
            try alloc.dupe(u8, continuation_prompt)
        else
            null;
        errdefer if (next_prompt) |value| alloc.free(value);

        types.freeHistoryTurnSlice(alloc, prompt.history);
        prompt.history = history;
        if (next_prompt) |value| {
            alloc.free(prompt.prompt);
            prompt.prompt = value;
            types.freeImageAttachmentSlice(alloc, prompt.images);
            prompt.images = &.{};
        }
        return same_authority;
    }

    fn commitContextSurface(
        self: *Manager,
        key: []const u8,
        source_turn_id: u64,
        instruction_source_turn_ids: []const u64,
        history: []types.HistoryTurn,
    ) !void {
        const instruction_ids = try self.alloc.dupe(u64, instruction_source_turn_ids);
        errdefer self.alloc.free(instruction_ids);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.findContextSurface(key)) |surface| {
            self.alloc.free(surface.instruction_source_turn_ids);
            types.freeHistoryTurnSlice(self.alloc, surface.history);
            surface.source_turn_id = source_turn_id;
            surface.instruction_source_turn_ids = instruction_ids;
            surface.history = history;
            return;
        }
        const owned_key = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(owned_key);
        try self.context_surfaces.append(self.alloc, .{
            .key = owned_key,
            .source_turn_id = source_turn_id,
            .instruction_source_turn_ids = instruction_ids,
            .history = history,
        });
    }

    fn findContextSurface(self: *Manager, key: []const u8) ?*ContextSurface {
        for (self.context_surfaces.items) |*surface| {
            if (std.mem.eql(u8, surface.key, key)) return surface;
        }
        return null;
    }

    /// Consumes `prepared` only after the run has entered manager custody.
    pub fn start(self: *Manager, prepared: Prepared) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.runs.items) |run| {
            if (std.mem.eql(u8, run.prepared.run_id, prepared.run_id)) {
                return error.DuplicateRunId;
            }
        }
        try self.runs.ensureUnusedCapacity(self.alloc, 1);
        const run = try self.alloc.create(Run);
        run.* = .{ .manager = self, .prepared = prepared };
        errdefer self.alloc.destroy(run);
        run.thread = try std.Thread.spawn(.{}, Run.main, .{run});
        self.runs.appendAssumeCapacity(run);
    }

    pub fn cancelRun(self: *Manager, run_id: []const u8) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.runs.items) |run| {
            if (!std.mem.eql(u8, run.prepared.run_id, run_id)) continue;
            run.cancel.store(true, .seq_cst);
            run.worker.requestCancel();
            return true;
        }
        return false;
    }

    pub fn takeEvents(self: *Manager) std.ArrayList(Event) {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const events = self.events;
        self.events = .empty;
        return events;
    }

    pub fn reap(self: *Manager, run_id: []const u8) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        var removed: ?*Run = null;
        for (self.runs.items, 0..) |run, index| {
            if (!std.mem.eql(u8, run.prepared.run_id, run_id)) continue;
            removed = self.runs.swapRemove(index);
            if (self.approval_binding) |binding| {
                if (binding.run == run) self.approval_binding = null;
            }
            if (self.question_binding == run) self.question_binding = null;
            break;
        }
        self.mutex.unlock(io_mod.getIo());
        const run = removed orelse return false;
        if (run.thread) |thread| thread.join();
        run.deinit(self.alloc);
        return true;
    }

    pub fn snapshotPendingApproval(
        self: *Manager,
        alloc: Allocator,
    ) !?permission_request.OwnedPermissionRequest {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        if (self.approval_binding) |binding| {
            if (try snapshotBoundApproval(alloc, binding)) |request| return request;
            self.approval_binding = null;
        }

        for (self.runs.items) |run| {
            var snapshot = try run.worker.snapshotState(alloc);
            defer snapshot.deinit(alloc);
            const pending = snapshot.pending_permission_request orelse continue;
            const public_request_id = self.next_approval_id;
            if (public_request_id == 0 or public_request_id == std.math.maxInt(u64)) {
                return error.OrchestrationApprovalIdExhausted;
            }
            self.next_approval_id = public_request_id + 1;
            self.approval_binding = .{
                .public_request_id = public_request_id,
                .local_request_id = pending.id,
                .run = run,
            };
            var owned = snapshot.pending_permission_request.?;
            snapshot.pending_permission_request = null;
            owned.id = public_request_id;
            return owned;
        }
        return null;
    }

    pub fn submitPermissionResponse(
        self: *Manager,
        public_request_id: u64,
        response: permission_request.OwnedPermissionResponse,
    ) worker_runtime.PermissionSubmissionResult {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const binding = self.approval_binding orelse {
            var owned = response;
            owned.deinit();
            return .no_pending;
        };
        if (binding.public_request_id != public_request_id) {
            var owned = response;
            owned.deinit();
            return .stale;
        }
        self.approval_binding = null;
        return binding.run.worker.submitPermissionResponse(
            binding.local_request_id,
            response,
        );
    }

    pub fn approvalBound(self: *Manager, public_request_id: u64) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const binding = self.approval_binding orelse return false;
        return binding.public_request_id == public_request_id;
    }

    pub fn approvalReview(
        self: *Manager,
        public_request_id: u64,
    ) ?*const diff_mod.FileReview {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const binding = self.approval_binding orelse return null;
        if (binding.public_request_id != public_request_id) return null;
        return binding.run.worker.pendingPermissionReview(
            binding.local_request_id,
        );
    }

    pub fn cancelApproval(self: *Manager, public_request_id: u64) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const binding = self.approval_binding orelse return false;
        if (binding.public_request_id != public_request_id) return false;
        self.approval_binding = null;
        binding.run.cancel.store(true, .seq_cst);
        binding.run.worker.cancelApprovalTurn();
        return true;
    }

    pub fn snapshotPendingQuestion(
        self: *Manager,
        alloc: Allocator,
    ) !?worker_runtime.PendingQuestionBatchSnapshot {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        if (self.question_binding) |run| {
            if (try run.worker.snapshotPendingQuestionBatch(alloc)) |snapshot| {
                return snapshot;
            }
            self.question_binding = null;
        }
        for (self.runs.items) |run| {
            if (try run.worker.snapshotPendingQuestionBatch(alloc)) |snapshot| {
                self.question_binding = run;
                return snapshot;
            }
        }
        return null;
    }

    pub fn questionBound(self: *Manager) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.question_binding != null;
    }

    pub fn questionSource(self: *Manager) ?worker_runtime.QuestionPromptSource {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const run = self.question_binding orelse return null;
        return run.worker.pendingQuestionBatchSource();
    }

    pub fn submitQuestionAnswer(
        self: *Manager,
        alloc: Allocator,
        answers: ?[]const []const u8,
    ) !bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const run = self.question_binding orelse return false;
        try run.worker.submitQuestionBatchAnswer(alloc, answers);
        self.question_binding = null;
        return true;
    }

    pub fn cancelQuestion(self: *Manager, alloc: Allocator) !bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const run = self.question_binding orelse return false;
        run.cancel.store(true, .seq_cst);
        run.worker.requestCancel();
        try run.worker.submitQuestionBatchAnswer(alloc, null);
        self.question_binding = null;
        return true;
    }

    fn pushStarted(self: *Manager, run_id: []const u8) !void {
        const owned = try self.alloc.dupe(u8, run_id);
        errdefer self.alloc.free(owned);
        try self.pushEvent(.{ .started = .{ .run_id = owned } });
    }

    fn pushCompleted(self: *Manager, run_id: []const u8, output: []const u8, input_tokens: u64, output_tokens: u64) !void {
        const owned_id = try self.alloc.dupe(u8, run_id);
        errdefer self.alloc.free(owned_id);
        const owned_output = try self.alloc.dupe(u8, output);
        errdefer self.alloc.free(owned_output);
        try self.pushEvent(.{ .completed = .{
            .run_id = owned_id,
            .output = owned_output,
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
        } });
    }

    fn pushFailed(self: *Manager, run_id: []const u8, message: []const u8, interrupted: bool) !void {
        return self.pushFailure(run_id, .{
            .kind = if (interrupted) .interrupted else .runtime,
            .message = message,
        }, interrupted);
    }

    fn pushFailure(self: *Manager, run_id: []const u8, failure: run_failure.Snapshot, interrupted: bool) !void {
        const owned_id = try self.alloc.dupe(u8, run_id);
        errdefer self.alloc.free(owned_id);
        const owned_message = try self.alloc.dupe(u8, failure.message);
        errdefer self.alloc.free(owned_message);
        try self.pushEvent(.{ .failed = .{
            .run_id = owned_id,
            .message = owned_message,
            .interrupted = interrupted,
            .kind = if (interrupted) .interrupted else failure.kind,
            .http_status = failure.http_status,
        } });
    }

    fn pushEvent(self: *Manager, event: Event) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        try self.events.append(self.alloc, event);
    }
};

fn dupeHistory(alloc: Allocator, history: []const types.HistoryTurn) ![]types.HistoryTurn {
    const copy = try alloc.alloc(types.HistoryTurn, history.len);
    var count: usize = 0;
    errdefer {
        for (copy[0..count]) |turn| session_runtime.freeHistoryTurn(alloc, turn);
        alloc.free(copy);
    }
    while (count < history.len) : (count += 1) {
        copy[count] = try session_runtime.dupeHistoryTurn(alloc, history[count]);
    }
    return copy;
}

fn snapshotBoundApproval(
    alloc: Allocator,
    binding: Manager.ApprovalBinding,
) !?permission_request.OwnedPermissionRequest {
    var snapshot = try binding.run.worker.snapshotState(alloc);
    defer snapshot.deinit(alloc);
    const pending = snapshot.pending_permission_request orelse return null;
    if (pending.id != binding.local_request_id) return null;
    var owned = snapshot.pending_permission_request.?;
    snapshot.pending_permission_request = null;
    owned.id = binding.public_request_id;
    return owned;
}

test "orchestration run manager has no native subagent dependency" {
    _ = Prepared;
    _ = Event;
    _ = Manager;
}
