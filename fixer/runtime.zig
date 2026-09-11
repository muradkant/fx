const std = @import("std");
const context_mod = @import("domain/context.zig");
const decision = @import("domain/decision.zig");
const peer_mod = @import("domain/peer.zig");
const projection_mod = @import("domain/projection.zig");
const specialist_mod = @import("domain/specialist.zig");
const team_mod = @import("domain/team.zig");
const test_host = @import("fx_orchestration_host");

// An invalid terminal control envelope gets one different recovery strategy:
// an explicit correction containing the observed defect and prior output.
// Transport failures are never retried here, and valid Team work is not bound
// by an invented Fixer iteration ceiling.
const max_protocol_corrections: u32 = 1;
const max_consultation_depth: u8 = 16;

const WireOutcome = struct {
    kind: []const u8,
    answer: ?[]const u8 = null,
    peer_id: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    delegations: ?[]const specialist_mod.Proposal = null,
    peer_turns: ?[]const peer_mod.Proposal = null,
};

const WorkOwner = union(enum) {
    leader,
    consultation: usize,
};

const ConsultationFrame = struct {
    id: []u8,
    parent: WorkOwner,
    agent_id: []const u8,
    depth: u8,
    protocol_corrections: u32 = 0,
    specialist_calls: ?[]specialist_mod.Call = null,
    peer_calls: ?[]peer_mod.Call = null,
    completed: bool = false,

    fn deinit(self: *ConsultationFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.specialist_calls) |calls| specialist_mod.deinitCalls(allocator, calls);
        if (self.peer_calls) |calls| peer_mod.deinitCalls(allocator, calls);
        self.* = undefined;
    }
};

const CallLocation = struct {
    owner: WorkOwner,
    index: usize,
};

const Instruction = struct {
    source_turn_id: u64,
    text: []u8,
    attachment_references: [][]u8,

    fn deinit(self: *Instruction, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        freeStrings(allocator, self.attachment_references);
        self.* = undefined;
    }
};

const Session = struct {
    source_turn_id: u64,
    session_id: []u8,
    attachment_references: [][]u8,
    conversation_context: []u8,
    instruction_source_turn_ids: std.ArrayList(u64) = .empty,
    instructions: std.ArrayList(Instruction) = .empty,
    projection: projection_mod.Projection = .{},
    current_run_id: ?[]u8 = null,
    current_agent_id: []const u8 = "",
    current_turn: u32 = 0,
    current_run_started: bool = false,
    protocol_corrections: u32 = 0,
    specialist_calls: ?[]specialist_mod.Call = null,
    peer_calls: ?[]peer_mod.Call = null,
    peer_history: std.ArrayList(peer_mod.Call) = .empty,
    consultation_frames: std.ArrayList(ConsultationFrame) = .empty,
    next_delegation_ordinal: u32 = 1,
    next_peer_ordinal: u32 = 1,
    next_run_ordinal: u32 = 1,

    fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        if (self.current_run_id) |run_id| allocator.free(run_id);
        allocator.free(self.session_id);
        freeStrings(allocator, self.attachment_references);
        allocator.free(self.conversation_context);
        self.instruction_source_turn_ids.deinit(allocator);
        for (self.instructions.items) |*instruction| instruction.deinit(allocator);
        self.instructions.deinit(allocator);
        if (self.specialist_calls) |calls| specialist_mod.deinitCalls(allocator, calls);
        if (self.peer_calls) |calls| peer_mod.deinitCalls(allocator, calls);
        for (self.consultation_frames.items) |*frame| frame.deinit(allocator);
        self.consultation_frames.deinit(allocator);
        for (self.peer_history.items) |*call| call.deinit(allocator);
        self.peer_history.deinit(allocator);
        self.* = undefined;
    }
};

pub fn Runtime(comptime host: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        team: team_mod.Team,
        active: bool = false,
        conversation_id: ?[]u8 = null,
        session: ?Session = null,

        pub fn init(allocator: std.mem.Allocator, team: team_mod.Team) Self {
            return .{ .allocator = allocator, .team = team };
        }

        pub fn deinit(self: *Self) void {
            self.clearSession();
            if (self.conversation_id) |conversation_id| self.allocator.free(conversation_id);
            self.* = undefined;
        }

        pub fn dispatch(self: *Self, event: host.HostEvent, sink: host.IntentSink) !void {
            switch (event) {
                .enter => |activation| try self.enter(activation, sink),
                .leave => try self.leave(sink),
                .user_turn => |turn| try self.beginUserTurn(turn, sink),
                .user_instruction => |instruction| try self.applyUserInstruction(instruction, sink),
                .agent_run_started => |started| try self.startAgentRunAccepted(started, sink),
                .agent_run_completed => |completed| try self.completeAgentRun(completed, sink),
                .agent_run_failed => |failed| try self.failAgentRun(failed, sink),
                .cancel_requested => try self.cancel(sink),
            }
        }

        fn enter(self: *Self, activation: host.Activation, sink: host.IntentSink) !void {
            var eligible = false;
            for (activation.providers) |provider| {
                eligible = eligible or (provider.catalog_scope == .unified and
                    std.mem.eql(u8, provider.id, self.team.provider_id));
            }
            if (!eligible) {
                try self.trace(sink, .{ .event = "activation_refused", .detail = "unified_provider_missing" });
                try sink.emit(.{ .notice = .{
                    .tone = .failure,
                    .text = "Fixer needs Vercel AI Gateway or OpenCode Go/Zen.",
                } });
                return;
            }
            if (self.active) {
                try self.trace(sink, .{ .event = "activation_idempotent" });
                try sink.emit(.{ .notice = .{
                    .tone = .info,
                    .text = "Fixer mode is already enabled.",
                } });
                return;
            }

            const conversation_id = try self.allocator.dupe(u8, activation.conversation_id);
            if (self.conversation_id) |previous| self.allocator.free(previous);
            self.conversation_id = conversation_id;
            self.active = true;
            try self.trace(sink, .{ .event = "activation_accepted" });
            try sink.emit(.{ .mode_entered = .{ .notice = "Fixer mode enabled." } });
        }

        fn leave(self: *Self, sink: host.IntentSink) !void {
            if (!self.active) {
                try self.trace(sink, .{ .event = "deactivation_idempotent" });
                try sink.emit(.{ .notice = .{
                    .tone = .info,
                    .text = "Fixer mode is already disabled.",
                } });
                return;
            }
            if (self.session) |*session| {
                if (!session.projection.terminal()) {
                    if (session.current_run_id) |run_id| {
                        try sink.emit(.{ .cancel_agent_run = .{ .run_id = run_id } });
                        self.allocator.free(run_id);
                        session.current_run_id = null;
                        session.current_agent_id = "";
                        session.current_turn = 0;
                        session.current_run_started = false;
                    }
                    try self.cancelAllSpecialistRuns(sink);
                    try self.cancelAllPeerRuns(sink);
                    try session.projection.apply(.{
                        .sequence = session.projection.last_sequence + 1,
                        .data = .session_cancelled,
                    });
                    try self.trace(sink, self.sessionTrace("session_cancelled", "mode_left"));
                }
            }
            self.active = false;
            try self.trace(sink, .{ .event = "deactivation_completed" });
            try sink.emit(.{ .mode_left = .{ .notice = "Fixer mode disabled." } });
        }

        fn beginUserTurn(self: *Self, turn: host.UserTurn, sink: host.IntentSink) !void {
            if (!self.active) {
                try sink.emit(.{ .notice = .{
                    .tone = .failure,
                    .text = "Enable Fixer mode before submitting a Fixer turn.",
                } });
                return;
            }
            if (turn.source_turn_id == 0 or turn.session_id.len == 0 or
                std.mem.trim(u8, turn.text, " \t\r\n").len == 0)
            {
                try sink.emit(.{ .notice = .{
                    .tone = .failure,
                    .text = "Fixer rejected an empty or unidentifiable user turn.",
                } });
                return;
            }
            if (self.session) |*session| {
                if (!session.projection.terminal()) {
                    try self.trace(sink, self.sessionTrace("user_turn_refused", "session_running"));
                    try sink.emit(.{ .notice = .{
                        .tone = .warning,
                        .text = "The current Fixer turn is still running.",
                    } });
                    return;
                }
            }
            self.clearSession();

            const session_id = try self.allocator.dupe(u8, turn.session_id);
            errdefer self.allocator.free(session_id);
            const attachment_references = try cloneStrings(
                self.allocator,
                turn.attachment_references,
            );
            errdefer freeStrings(self.allocator, attachment_references);
            const conversation_context = try context_mod.conversationProjection(
                host,
                self.allocator,
                turn.conversation_history,
                context_mod.default_projection_budget_bytes,
            );
            errdefer self.allocator.free(conversation_context);
            self.session = .{
                .source_turn_id = turn.source_turn_id,
                .session_id = session_id,
                .attachment_references = attachment_references,
                .conversation_context = conversation_context,
            };
            const session = &self.session.?;
            const team = self.team;
            try team.validate();
            try session.projection.apply(.{
                .sequence = 1,
                .data = .{ .session_created = .{
                    .session_id = session.session_id,
                    .conversation_id = self.conversation_id orelse "",
                } },
            });
            try session.projection.apply(.{
                .sequence = 2,
                .data = .{ .team_pinned = .{
                    .team_id = team.id,
                    .revision = team.revision,
                    .digest = &team.digest,
                } },
            });
            const ingress = try decision.primaryIngress(team, session.projection);
            try session.projection.apply(.{ .sequence = 3, .data = ingress });
            try self.trace(sink, self.sessionTrace("session_created", "team_pinned"));
            try self.trace(sink, self.sessionTrace("context_view_committed", "conversation_history"));
            try self.trace(sink, self.sessionTrace("leadership_transferred", team.primary.id));
            try self.startAgentRun(team.primary.id, .{ .leader = .{ .agent_id = team.primary.id } }, "", "", sink);
        }

        fn applyUserInstruction(
            self: *Self,
            instruction: host.UserInstruction,
            sink: host.IntentSink,
        ) !void {
            const session = if (self.session) |*value| value else {
                try sink.emit(.{ .notice = .{
                    .tone = .warning,
                    .text = "There is no active Fixer turn to steer.",
                } });
                return;
            };
            if (session.projection.terminal()) {
                try sink.emit(.{ .notice = .{
                    .tone = .warning,
                    .text = "The Fixer turn already finished; submit a new turn instead.",
                } });
                return;
            }
            const text = std.mem.trim(u8, instruction.text, " \t\r\n");
            if (instruction.source_turn_id == 0 or text.len == 0) {
                try sink.emit(.{ .notice = .{
                    .tone = .failure,
                    .text = "Fixer rejected an empty or unidentifiable instruction.",
                } });
                return;
            }
            for (session.instruction_source_turn_ids.items) |existing| {
                if (existing == instruction.source_turn_id) {
                    try sink.emit(.{ .notice = .{
                        .tone = .warning,
                        .text = "Fixer ignored a duplicate instruction.",
                    } });
                    return;
                }
            }

            var owned_instruction = Instruction{
                .source_turn_id = instruction.source_turn_id,
                .text = try self.allocator.dupe(u8, text),
                .attachment_references = &.{},
            };
            var owns_instruction = true;
            errdefer if (owns_instruction) owned_instruction.deinit(self.allocator);
            owned_instruction.attachment_references = try cloneStrings(
                self.allocator,
                instruction.attachment_references,
            );
            const merged_attachments = try mergeUniqueStrings(
                self.allocator,
                session.attachment_references,
                instruction.attachment_references,
            );
            var owns_merged_attachments = true;
            errdefer if (owns_merged_attachments)
                freeStrings(self.allocator, merged_attachments);
            try session.instruction_source_turn_ids.ensureUnusedCapacity(self.allocator, 1);
            try session.instructions.ensureUnusedCapacity(self.allocator, 1);

            session.instruction_source_turn_ids.appendAssumeCapacity(instruction.source_turn_id);
            session.instructions.appendAssumeCapacity(owned_instruction);
            owns_instruction = false;
            freeStrings(self.allocator, session.attachment_references);
            session.attachment_references = merged_attachments;
            owns_merged_attachments = false;
            try session.projection.apply(.{
                .sequence = session.projection.last_sequence + 1,
                .data = .{ .user_instruction_added = .{
                    .source_turn_id = instruction.source_turn_id,
                } },
            });

            var cause_buffer: [64]u8 = undefined;
            const caused_by = try std.fmt.bufPrint(
                &cause_buffer,
                "instruction:{d}",
                .{instruction.source_turn_id},
            );
            if (session.current_run_id) |run_id| {
                try sink.emit(.{ .cancel_agent_run = .{ .run_id = run_id } });
                if (session.current_run_started) {
                    try session.projection.apply(.{
                        .sequence = session.projection.last_sequence + 1,
                        .data = .{ .agent_turn_interrupted = .{
                            .agent_id = session.current_agent_id,
                            .turn = session.current_turn,
                        } },
                    });
                }
                try self.trace(sink, self.runTrace(
                    "agent_run_interrupted",
                    run_id,
                    caused_by,
                    session.current_agent_id,
                    "user_instruction",
                ));
                self.allocator.free(run_id);
                session.current_run_id = null;
                session.current_agent_id = "";
                session.current_turn = 0;
                session.current_run_started = false;
            }
            try self.cancelAllSpecialistRuns(sink);
            try self.cancelAllPeerRuns(sink);
            self.clearActiveTeamWork();
            session.protocol_corrections = 0;
            try self.trace(sink, self.sessionTrace(
                "user_instruction_committed",
                caused_by,
            ));
            const context_projection =
                "A new in-session user instruction was accepted. It is part of the same Fixer session and supersedes conflicting earlier current-turn state.";
            try self.startAgentRun(
                session.projection.leader_id,
                .{ .leader = .{ .agent_id = session.projection.leader_id } },
                caused_by,
                context_projection,
                sink,
            );
        }

        fn startAgentRunAccepted(
            self: *Self,
            started: host.AgentRunStarted,
            sink: host.IntentSink,
        ) !void {
            const session = if (self.session) |*value| value else {
                try self.trace(sink, .{ .event = "run_start_ignored", .run_id = started.run_id, .detail = "no_session" });
                return;
            };
            if (peerCallLocation(session, started.run_id)) |location| {
                const call = peerCallAt(session, location);
                if (call.status != .requested) {
                    try self.trace(sink, self.runTrace(
                        "run_start_ignored",
                        started.run_id,
                        "",
                        call.peer_id,
                        "peer_consultation_not_requested",
                    ));
                    return;
                }
                call.status = .running;
                try self.trace(sink, self.runTrace(
                    "peer_consultation_started",
                    started.run_id,
                    "",
                    call.peer_id,
                    call.id,
                ));
                try self.emitActivity(
                    sink,
                    ownerAgentId(session, location.owner),
                    call.peer_id,
                    "consultation started",
                    .info,
                );
                return;
            }
            if (specialistCallLocation(session, started.run_id)) |location| {
                const call = specialistCallAt(session, location);
                if (call.status != .requested) {
                    try self.trace(sink, self.runTrace(
                        "run_start_ignored",
                        started.run_id,
                        "",
                        call.specialist_id,
                        "specialist_not_requested",
                    ));
                    return;
                }
                call.status = .running;
                try self.trace(sink, self.runTrace(
                    "specialist_run_started",
                    started.run_id,
                    "",
                    call.specialist_id,
                    call.id,
                ));
                try self.emitActivity(
                    sink,
                    ownerAgentId(session, location.owner),
                    call.specialist_id,
                    "specialist started",
                    .info,
                );
                return;
            }
            const current_run_id = session.current_run_id orelse {
                try self.trace(sink, self.runTrace("run_start_ignored", started.run_id, "", "", "no_requested_run"));
                return;
            };
            if (!std.mem.eql(u8, current_run_id, started.run_id)) {
                try self.trace(sink, self.runTrace("run_start_ignored", started.run_id, current_run_id, "", "stale_run"));
                return;
            }
            if (session.current_run_started) {
                try self.trace(sink, self.runTrace("run_start_ignored", started.run_id, "", session.current_agent_id, "duplicate"));
                return;
            }
            try session.projection.apply(.{
                .sequence = session.projection.last_sequence + 1,
                .data = .{ .agent_turn_started = .{
                    .agent_id = session.current_agent_id,
                    .turn = session.current_turn,
                } },
            });
            session.current_run_started = true;
            try self.trace(sink, self.runTrace(
                "agent_run_started",
                started.run_id,
                "",
                session.current_agent_id,
                "",
            ));
            // The first accepted run proves that the user's turn crossed the
            // host boundary. Later leader runs already have a visible cause
            // (handoff, Team return, steering, or protocol recovery), so do
            // not repeat a generic activity line for those continuations.
            if (session.current_turn == 1) {
                try self.emitRoleActivity(
                    sink,
                    session.current_agent_id,
                    if (std.mem.eql(u8, session.current_agent_id, self.team.primary.id))
                        "primary working"
                    else
                        "leader working",
                );
            }
        }

        fn completeAgentRun(
            self: *Self,
            completed: host.AgentRunCompleted,
            sink: host.IntentSink,
        ) !void {
            const session = if (self.session) |*value| value else {
                try self.trace(sink, .{ .event = "run_completion_ignored", .run_id = completed.run_id, .detail = "no_session" });
                return;
            };
            if (peerCallLocation(session, completed.run_id)) |location| {
                try self.completePeerRun(location, completed, sink);
                return;
            }
            if (specialistCallLocation(session, completed.run_id)) |location| {
                try self.completeSpecialistRun(location, completed, sink);
                return;
            }
            const current_run_id = session.current_run_id orelse {
                try self.trace(sink, self.runTrace("run_completion_ignored", completed.run_id, "", "", "no_active_run"));
                return;
            };
            if (!std.mem.eql(u8, current_run_id, completed.run_id)) {
                try self.trace(sink, self.runTrace("run_completion_ignored", completed.run_id, current_run_id, "", "stale_run"));
                return;
            }
            if (!session.current_run_started) {
                try self.trace(sink, self.runTrace("run_completion_ignored", completed.run_id, current_run_id, session.current_agent_id, "run_not_started"));
                return;
            }

            const completed_run_owned = current_run_id;
            defer self.allocator.free(completed_run_owned);
            session.current_run_id = null;
            const completed_agent_id = session.current_agent_id;
            const completed_turn = session.current_turn;
            session.current_agent_id = "";
            session.current_turn = 0;
            session.current_run_started = false;
            try session.projection.apply(.{
                .sequence = session.projection.last_sequence + 1,
                .data = .{ .agent_turn_completed = .{
                    .agent_id = completed_agent_id,
                    .turn = completed_turn,
                } },
            });
            try self.trace(sink, self.runTrace(
                "agent_run_completed",
                completed.run_id,
                "",
                completed_agent_id,
                "",
            ));

            var parsed = std.json.parseFromSlice(
                WireOutcome,
                self.allocator,
                completed.output,
                .{ .ignore_unknown_fields = false },
            ) catch {
                try self.rejectAgentProtocol(
                    completed_agent_id,
                    "invalid_json",
                    completed.output,
                    completed.run_id,
                    sink,
                );
                return;
            };
            defer parsed.deinit();
            const outcome = parsed.value;
            if (std.mem.eql(u8, outcome.kind, "answer")) {
                if (outcome.peer_id != null or outcome.reason != null or
                    outcome.delegations != null or outcome.peer_turns != null)
                {
                    try self.rejectAgentProtocol(completed_agent_id, "invalid_answer_shape", completed.output, completed.run_id, sink);
                    return;
                }
                const answer = std.mem.trim(u8, outcome.answer orelse "", " \t\r\n");
                if (answer.len == 0) {
                    try self.rejectAgentProtocol(completed_agent_id, "empty_answer", completed.output, completed.run_id, sink);
                    return;
                }
                session.protocol_corrections = 0;
                try session.projection.apply(.{
                    .sequence = session.projection.last_sequence + 1,
                    .data = .{ .final_completed = .{ .agent_id = completed_agent_id } },
                });
                try self.trace(sink, self.runTrace(
                    "answer_published",
                    completed.run_id,
                    "",
                    completed_agent_id,
                    "",
                ));
                try sink.emit(.{ .publish_answer = .{
                    .agent_id = completed_agent_id,
                    .text = answer,
                } });
                return;
            }
            if (std.mem.eql(u8, outcome.kind, "coordinate")) {
                if (outcome.answer != null or outcome.peer_id != null or outcome.reason != null or
                    session.specialist_calls != null or session.peer_calls != null)
                {
                    try self.rejectAgentProtocol(completed_agent_id, "invalid_team_coordination", completed.output, completed.run_id, sink);
                    return;
                }
                const specialist_proposals: []const specialist_mod.Proposal =
                    outcome.delegations orelse &.{};
                const peer_proposals: []const peer_mod.Proposal =
                    outcome.peer_turns orelse &.{};
                if (specialist_proposals.len == 0 and peer_proposals.len == 0) {
                    try self.rejectAgentProtocol(completed_agent_id, "empty_team_coordination", completed.output, completed.run_id, sink);
                    return;
                }

                var new_specialists: ?[]specialist_mod.Call = null;
                if (specialist_proposals.len > 0) {
                    new_specialists = specialist_mod.materializeBatch(
                        self.allocator,
                        self.team,
                        completed_agent_id,
                        session.session_id,
                        session.next_delegation_ordinal,
                        specialist_proposals,
                        session.attachment_references,
                    ) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        try self.rejectAgentProtocol(completed_agent_id, "invalid_specialist_plan", completed.output, completed.run_id, sink);
                        return;
                    };
                }
                var new_peers: ?[]peer_mod.Call = null;
                if (peer_proposals.len > 0) {
                    new_peers = peer_mod.materializeBatch(
                        self.allocator,
                        self.team,
                        completed_agent_id,
                        session.session_id,
                        session.next_peer_ordinal,
                        peer_proposals,
                        session.peer_history.items,
                        session.attachment_references,
                    ) catch |err| {
                        if (new_specialists) |calls| specialist_mod.deinitCalls(self.allocator, calls);
                        if (err == error.OutOfMemory) return err;
                        try self.rejectAgentProtocol(completed_agent_id, "invalid_peer_consultation_plan", completed.output, completed.run_id, sink);
                        return;
                    };
                }

                session.protocol_corrections = 0;
                session.specialist_calls = new_specialists;
                session.peer_calls = new_peers;
                if (new_specialists) |calls| for (calls) |call| {
                    try self.trace(sink, self.runTrace(
                        "specialist_delegation_created",
                        "",
                        completed.run_id,
                        call.specialist_id,
                        call.id,
                    ));
                };
                if (new_peers) |calls| for (calls) |call| {
                    try self.trace(sink, self.runTrace(
                        "peer_consultation_created",
                        "",
                        completed.run_id,
                        call.peer_id,
                        call.id,
                    ));
                };
                session.next_delegation_ordinal += @intCast(specialist_proposals.len);
                session.next_peer_ordinal += @intCast(peer_proposals.len);
                try self.scheduleReadySpecialists(.leader, sink);
                try self.scheduleAllReadyPeers(sink);
                return;
            }
            if (!std.mem.eql(u8, outcome.kind, "handoff")) {
                try self.rejectAgentProtocol(completed_agent_id, "unknown_outcome_kind", completed.output, completed.run_id, sink);
                return;
            }
            if (outcome.answer != null or outcome.delegations != null or
                outcome.peer_turns != null)
            {
                try self.rejectAgentProtocol(completed_agent_id, "invalid_handoff_shape", completed.output, completed.run_id, sink);
                return;
            }
            const peer_id = std.mem.trim(u8, outcome.peer_id orelse "", " \t\r\n");
            const reason = std.mem.trim(u8, outcome.reason orelse "", " \t\r\n");
            if (peer_id.len == 0 or reason.len == 0) {
                try self.rejectAgentProtocol(completed_agent_id, "invalid_handoff", completed.output, completed.run_id, sink);
                return;
            }
            const team = self.team;
            const transfer = decision.handoff(team, session.projection, peer_id) catch {
                try self.rejectAgentProtocol(completed_agent_id, "unauthorized_handoff", completed.output, completed.run_id, sink);
                return;
            };
            session.protocol_corrections = 0;
            try session.projection.apply(.{
                .sequence = session.projection.last_sequence + 1,
                .data = transfer,
            });
            try self.trace(sink, self.runTrace(
                "leadership_transferred",
                "",
                completed.run_id,
                peer_id,
                "",
            ));
            try self.emitActivity(
                sink,
                completed_agent_id,
                peer_id,
                "leadership handed off",
                .info,
            );
            const context_projection = try std.fmt.allocPrint(
                self.allocator,
                "The previous leader transferred this exact user turn to you.\nReason: {s}",
                .{reason},
            );
            defer self.allocator.free(context_projection);
            try self.startAgentRun(
                peer_id,
                .{ .peer = .{
                    .agent_id = peer_id,
                    .collaboration_id = session.session_id,
                    .round = 1,
                } },
                completed.run_id,
                context_projection,
                sink,
            );
        }

        fn scheduleReadySpecialists(
            self: *Self,
            owner: WorkOwner,
            sink: host.IntentSink,
        ) !void {
            const session = &self.session.?;
            const calls = ownerSpecialistCalls(session, owner).* orelse return;
            var index: usize = 0;
            while (index < calls.len) : (index += 1) {
                if (specialist_mod.ready(calls[index], calls)) {
                    try self.requestSpecialistRun(.{ .owner = owner, .index = index }, sink);
                }
            }
        }

        fn requestSpecialistRun(
            self: *Self,
            location: CallLocation,
            sink: host.IntentSink,
        ) !void {
            const session = &self.session.?;
            const calls = ownerSpecialistCalls(session, location.owner).*.?;
            const index = location.index;
            const call = &calls[index];
            const specialist = self.team.specialist(call.specialist_id) orelse return error.UnknownSpecialist;
            const model = self.team.model(specialist.model_id) orelse return error.UnknownModel;
            const projected_content = try specialist_mod.projectedContent(
                self.allocator,
                call.*,
                calls,
            );
            defer self.allocator.free(projected_content);
            const run_id = try std.fmt.allocPrint(
                self.allocator,
                "{s}:attempt:{d}",
                .{ call.id, call.attempt + 1 },
            );
            errdefer self.allocator.free(run_id);
            const system_prompt = try std.fmt.allocPrint(
                self.allocator,
                "The user defined your role in these exact words:\n<role-definition>\n{s}\n</role-definition>\n\nComplete the supplied task. After any tool work, return exactly one JSON object and no Markdown: {{\"result\":\"concise result\",\"findings\":[\"grounded finding\"],\"risks\":[\"grounded risk\"],\"confidence\":0.0}}. Confidence must be between 0 and 1.",
                .{specialist.definition},
            );
            defer self.allocator.free(system_prompt);

            call.attempt += 1;
            call.run_id = run_id;
            call.status = .requested;
            errdefer {
                call.status = .pending;
                call.run_id = null;
                call.attempt -= 1;
            }
            try self.trace(sink, self.runTrace(
                "specialist_run_requested",
                run_id,
                "",
                call.specialist_id,
                call.id,
            ));
            try sink.emit(.{
                .start_agent_run = .{
                    .run_id = run_id,
                    .context_key = null,
                    .authority = .{
                        .source_turn_id = session.source_turn_id,
                        .instruction_source_turn_ids = session.instruction_source_turn_ids.items,
                    },
                    .model = .{
                        .provider_id = self.team.provider_id,
                        .route = model.route,
                        .name = model.name,
                        .reasoning_effort = model.reasoning_effort,
                    },
                    .scope = .{ .specialist = .{
                        .specialist_id = call.specialist_id,
                        .delegation_id = call.id,
                        .attempt = call.attempt,
                    } },
                    .system_prompt = system_prompt,
                    .visible_input = .{ .projected = .{
                        .content = projected_content,
                        .attachment_references = call.attachments,
                    } },
                    // A provider-level response format applies to every agent
                    // step and can suppress fx tool calls. Zig validates the
                    // terminal envelope after the ordinary fx tool loop instead.
                    .response_schema_json = null,
                },
            });
        }

        fn completeSpecialistRun(
            self: *Self,
            location: CallLocation,
            completed: host.AgentRunCompleted,
            sink: host.IntentSink,
        ) !void {
            const session = &self.session.?;
            const calls = ownerSpecialistCalls(session, location.owner).*.?;
            const call = &calls[location.index];
            if (call.status != .running) {
                try self.trace(sink, self.runTrace(
                    "run_completion_ignored",
                    completed.run_id,
                    "",
                    call.specialist_id,
                    "specialist_not_started",
                ));
                return;
            }
            const result = specialist_mod.parseResult(self.allocator, completed.output) catch |err| {
                if (err == error.OutOfMemory) return err;
                if (call.run_id) |run_id| self.allocator.free(run_id);
                call.run_id = null;
                try specialist_mod.recordFailure(
                    self.allocator,
                    call,
                    "specialist returned an invalid terminal result",
                );
                try self.trace(sink, self.runTrace(
                    "specialist_run_failed",
                    completed.run_id,
                    "",
                    call.specialist_id,
                    "invalid_terminal_result",
                ));
                try self.maybeResumeOwnerAfterTeamWork(location.owner, completed.run_id, sink);
                return;
            };
            if (call.run_id) |run_id| self.allocator.free(run_id);
            call.run_id = null;
            call.result = result;
            call.status = .completed;
            try self.trace(sink, self.runTrace(
                "specialist_run_completed",
                completed.run_id,
                "",
                call.specialist_id,
                call.id,
            ));
            try self.emitActivity(
                sink,
                call.specialist_id,
                ownerAgentId(session, location.owner),
                "specialist returned",
                .info,
            );
            try self.scheduleReadySpecialists(location.owner, sink);
            try self.maybeResumeOwnerAfterTeamWork(location.owner, completed.run_id, sink);
        }

        fn scheduleAllReadyPeers(self: *Self, sink: host.IntentSink) !void {
            try self.scheduleReadyPeers(.leader, sink);
            var index: usize = 0;
            while (index < self.session.?.consultation_frames.items.len) : (index += 1) {
                if (self.session.?.consultation_frames.items[index].completed) continue;
                try self.scheduleReadyPeers(.{ .consultation = index }, sink);
            }
        }

        fn scheduleReadyPeers(
            self: *Self,
            owner: WorkOwner,
            sink: host.IntentSink,
        ) !void {
            const session = &self.session.?;
            const calls = ownerPeerCalls(session, owner).* orelse return;
            for (calls, 0..) |_, index| {
                if (!peer_mod.ready(index, calls)) continue;
                if (peerSurfaceReserved(session, calls[index].peer_id)) continue;
                try self.requestPeerRun(.{ .owner = owner, .index = index }, sink);
            }
        }

        fn requestPeerRun(
            self: *Self,
            location: CallLocation,
            sink: host.IntentSink,
        ) !void {
            const session = &self.session.?;
            const call = peerCallAt(session, location);
            const caller_id = ownerAgentId(session, location.owner);
            const team_evidence = try self.teamEvidenceProjection(location.owner, caller_id);
            defer self.allocator.free(team_evidence);
            const context_projection = try peer_mod.consultationProjection(
                self.allocator,
                call.*,
                session.peer_history.items,
                team_evidence,
            );
            defer self.allocator.free(context_projection);
            const frame_index = try self.createConsultationFrame(location);
            try self.startConsultationRun(frame_index, context_projection, sink);
        }

        fn completePeerRun(
            self: *Self,
            location: CallLocation,
            completed: host.AgentRunCompleted,
            sink: host.IntentSink,
        ) !void {
            const session = &self.session.?;
            const call = peerCallAt(session, location);
            if (call.status != .running) {
                try self.trace(sink, self.runTrace(
                    "run_completion_ignored",
                    completed.run_id,
                    "",
                    call.peer_id,
                    "peer_consultation_not_started",
                ));
                return;
            }
            const frame_index = consultationFrameIndex(session, call.id) orelse
                return error.UnknownConsultationFrame;
            if (call.run_id) |run_id| self.allocator.free(run_id);
            call.run_id = null;
            call.status = .waiting;

            var parsed_control: ?std.json.Parsed(WireOutcome) =
                std.json.parseFromSlice(
                    WireOutcome,
                    self.allocator,
                    completed.output,
                    .{ .ignore_unknown_fields = false },
                ) catch null;
            defer if (parsed_control) |*parsed| parsed.deinit();
            if (parsed_control) |parsed| {
                const outcome = parsed.value;
                if (std.mem.eql(u8, outcome.kind, "coordinate")) {
                    if (outcome.answer != null or outcome.peer_id != null or outcome.reason != null) {
                        try self.rejectConsultationProtocol(frame_index, "invalid_consultation_coordination", completed.output, completed.run_id, sink);
                        return;
                    }
                    const specialist_proposals: []const specialist_mod.Proposal = outcome.delegations orelse &.{};
                    const peer_proposals: []const peer_mod.Proposal = outcome.peer_turns orelse &.{};
                    if (specialist_proposals.len == 0 and peer_proposals.len == 0) {
                        try self.rejectConsultationProtocol(frame_index, "empty_consultation_coordination", completed.output, completed.run_id, sink);
                        return;
                    }
                    self.materializeOwnerWork(
                        .{ .consultation = frame_index },
                        self.session.?.consultation_frames.items[frame_index].agent_id,
                        specialist_proposals,
                        peer_proposals,
                        completed.run_id,
                        sink,
                    ) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        try self.rejectConsultationProtocol(frame_index, "invalid_nested_consultation_plan", completed.output, completed.run_id, sink);
                        return;
                    };
                    try self.trace(sink, self.runTrace(
                        "peer_consultation_suspended",
                        completed.run_id,
                        "",
                        call.peer_id,
                        call.id,
                    ));
                    try self.scheduleReadySpecialists(.{ .consultation = frame_index }, sink);
                    try self.scheduleAllReadyPeers(sink);
                    return;
                }
                try self.rejectConsultationProtocol(frame_index, "consultation_cannot_answer_or_handoff", completed.output, completed.run_id, sink);
                return;
            }

            const result = specialist_mod.parseResult(self.allocator, completed.output) catch |err| {
                if (err == error.OutOfMemory) return err;
                try self.rejectConsultationProtocol(frame_index, "invalid_consultation_result", completed.output, completed.run_id, sink);
                return;
            };
            call.result = result;
            call.status = .completed;
            session.consultation_frames.items[frame_index].completed = true;
            try self.trace(sink, self.runTrace(
                "peer_consultation_completed",
                completed.run_id,
                "",
                call.peer_id,
                call.id,
            ));
            const parent = session.consultation_frames.items[frame_index].parent;
            try self.emitActivity(
                sink,
                call.peer_id,
                ownerAgentId(session, parent),
                "consultation returned",
                .info,
            );
            try self.scheduleAllReadyPeers(sink);
            try self.maybeResumeOwnerAfterTeamWork(parent, completed.run_id, sink);
        }

        fn maybeResumeOwnerAfterTeamWork(
            self: *Self,
            owner: WorkOwner,
            caused_by_run_id: []const u8,
            sink: host.IntentSink,
        ) !void {
            const session = &self.session.?;
            const specialist_slot = ownerSpecialistCalls(session, owner);
            const peer_slot = ownerPeerCalls(session, owner);
            if (specialist_slot.*) |calls| {
                try specialist_mod.settleBlockedDependencies(self.allocator, calls);
                if (!specialist_mod.allSettled(calls)) return;
            }
            if (peer_slot.*) |calls| {
                if (!peer_mod.allSettled(calls)) return;
            }
            if (specialist_slot.* == null and peer_slot.* == null) return;

            const specialist_projection = if (specialist_slot.*) |calls|
                try specialist_mod.settledProjection(self.allocator, calls)
            else
                try self.allocator.dupe(u8, "{\"specialist_outcomes\":[]}");
            defer self.allocator.free(specialist_projection);
            const peer_projection = if (peer_slot.*) |calls|
                try peer_mod.settledProjection(self.allocator, calls)
            else
                try self.allocator.dupe(u8, "{\"peer_consultation_outcomes\":[]}");
            defer self.allocator.free(peer_projection);
            const context_projection = try std.fmt.allocPrint(
                self.allocator,
                "Completed direct Team calls follow. These are returns to the current caller only.\nSpecialists: {s}\nPeer consultations: {s}",
                .{ specialist_projection, peer_projection },
            );
            defer self.allocator.free(context_projection);

            if (specialist_slot.*) |calls| {
                specialist_mod.deinitCalls(self.allocator, calls);
                specialist_slot.* = null;
            }
            if (peer_slot.*) |calls| {
                try session.peer_history.ensureUnusedCapacity(self.allocator, calls.len);
                for (calls) |call| session.peer_history.appendAssumeCapacity(call);
                self.allocator.free(calls);
                peer_slot.* = null;
            }
            try self.trace(sink, self.runTrace(
                "team_coordination_completed",
                "",
                caused_by_run_id,
                ownerAgentId(session, owner),
                "",
            ));
            switch (owner) {
                .leader => try self.startAgentRun(
                    session.projection.leader_id,
                    .{ .leader = .{ .agent_id = session.projection.leader_id } },
                    caused_by_run_id,
                    context_projection,
                    sink,
                ),
                .consultation => |frame_index| try self.startConsultationRun(
                    frame_index,
                    context_projection,
                    sink,
                ),
            }
        }

        fn teamEvidenceProjection(
            self: *Self,
            owner: WorkOwner,
            caller_id: []const u8,
        ) ![]u8 {
            const session = &self.session.?;
            const peer_history = if (session.peer_history.items.len > 0)
                try peer_mod.settledProjectionForCaller(
                    self.allocator,
                    session.peer_history.items,
                    caller_id,
                )
            else
                try self.allocator.dupe(u8, "{\"peer_consultation_outcomes\":[]}");
            defer self.allocator.free(peer_history);
            const specialist_results = if (ownerSpecialistCalls(session, owner).*) |calls| blk: {
                if (!specialist_mod.allSettled(calls)) break :blk try self.allocator.dupe(u8, "{\"specialist_outcomes\":[]}");
                break :blk try specialist_mod.settledProjection(self.allocator, calls);
            } else try self.allocator.dupe(u8, "{\"specialist_outcomes\":[]}");
            defer self.allocator.free(specialist_results);
            return std.fmt.allocPrint(
                self.allocator,
                "{s}\n{s}",
                .{ peer_history, specialist_results },
            );
        }

        fn materializeOwnerWork(
            self: *Self,
            owner: WorkOwner,
            caller_id: []const u8,
            specialist_proposals: []const specialist_mod.Proposal,
            peer_proposals: []const peer_mod.Proposal,
            caused_by_run_id: []const u8,
            sink: host.IntentSink,
        ) !void {
            const session = &self.session.?;
            const specialist_slot = ownerSpecialistCalls(session, owner);
            const peer_slot = ownerPeerCalls(session, owner);
            if (specialist_slot.* != null or peer_slot.* != null) {
                return error.OwnerAlreadyCoordinating;
            }
            if (specialist_proposals.len == 0 and peer_proposals.len == 0) {
                return error.EmptyTeamCoordination;
            }
            if (peer_proposals.len > 0 and ownerDepth(session, owner) >= max_consultation_depth) {
                return error.ConsultationDepthExceeded;
            }
            for (peer_proposals) |proposal| {
                if (agentInOwnerAncestry(session, owner, proposal.peer_id)) {
                    return error.ConsultationCycle;
                }
            }

            var new_specialists: ?[]specialist_mod.Call = null;
            if (specialist_proposals.len > 0) {
                new_specialists = try specialist_mod.materializeBatch(
                    self.allocator,
                    self.team,
                    caller_id,
                    session.session_id,
                    session.next_delegation_ordinal,
                    specialist_proposals,
                    session.attachment_references,
                );
            }
            errdefer if (new_specialists) |calls|
                specialist_mod.deinitCalls(self.allocator, calls);

            var new_peers: ?[]peer_mod.Call = null;
            if (peer_proposals.len > 0) {
                new_peers = try peer_mod.materializeBatch(
                    self.allocator,
                    self.team,
                    caller_id,
                    session.session_id,
                    session.next_peer_ordinal,
                    peer_proposals,
                    session.peer_history.items,
                    session.attachment_references,
                );
            }
            errdefer if (new_peers) |calls|
                peer_mod.deinitCalls(self.allocator, calls);

            specialist_slot.* = new_specialists;
            peer_slot.* = new_peers;
            for (new_specialists orelse &.{}) |call| {
                try self.trace(sink, self.runTrace(
                    "specialist_delegation_created",
                    "",
                    caused_by_run_id,
                    call.specialist_id,
                    call.id,
                ));
            }
            for (new_peers orelse &.{}) |call| {
                try self.trace(sink, self.runTrace(
                    "peer_consultation_created",
                    "",
                    caused_by_run_id,
                    call.peer_id,
                    call.id,
                ));
            }
            session.next_delegation_ordinal += @intCast(specialist_proposals.len);
            session.next_peer_ordinal += @intCast(peer_proposals.len);
        }

        fn createConsultationFrame(
            self: *Self,
            location: CallLocation,
        ) !usize {
            const session = &self.session.?;
            const call = peerCallAt(session, location);
            if (consultationFrameIndex(session, call.id)) |existing| return existing;
            const depth = std.math.add(u8, ownerDepth(session, location.owner), 1) catch
                return error.ConsultationDepthExceeded;
            if (depth > max_consultation_depth) return error.ConsultationDepthExceeded;
            const id = try self.allocator.dupe(u8, call.id);
            errdefer self.allocator.free(id);
            try session.consultation_frames.append(self.allocator, .{
                .id = id,
                .parent = location.owner,
                .agent_id = call.peer_id,
                .depth = depth,
            });
            return session.consultation_frames.items.len - 1;
        }

        fn startConsultationRun(
            self: *Self,
            frame_index: usize,
            context_projection: []const u8,
            sink: host.IntentSink,
        ) !void {
            const session = &self.session.?;
            const frame = &session.consultation_frames.items[frame_index];
            if (frame.completed) return error.CompletedConsultationFrame;
            const call = peerCallById(session, frame.parent, frame.id) orelse
                return error.UnknownConsultationCall;
            const peer = self.team.agent(frame.agent_id) orelse return error.UnknownPeer;
            const model = self.team.model(peer.model_id) orelse return error.UnknownModel;
            const visible_context = try self.contextBearingProjection(context_projection);
            defer self.allocator.free(visible_context);
            const system_prompt = try buildPeerConsultationSystemPrompt(
                self.allocator,
                self.team,
                peer,
            );
            defer self.allocator.free(system_prompt);
            const run_id = try std.fmt.allocPrint(
                self.allocator,
                "{s}:attempt:{d}",
                .{ frame.id, call.attempt + 1 },
            );
            errdefer self.allocator.free(run_id);
            const previous_status = call.status;
            call.attempt += 1;
            call.run_id = run_id;
            call.status = .requested;
            errdefer {
                call.status = previous_status;
                call.run_id = null;
                call.attempt -= 1;
            }
            try self.trace(sink, self.runTrace(
                "peer_consultation_requested",
                run_id,
                "",
                call.peer_id,
                call.id,
            ));
            try sink.emit(.{ .start_agent_run = .{
                .run_id = run_id,
                .context_key = peer.id,
                .authority = .{
                    .source_turn_id = session.source_turn_id,
                    .instruction_source_turn_ids = session.instruction_source_turn_ids.items,
                },
                .model = .{
                    .provider_id = self.team.provider_id,
                    .route = model.route,
                    .name = model.name,
                    .reasoning_effort = model.reasoning_effort,
                },
                .scope = .{ .peer = .{
                    .agent_id = call.peer_id,
                    .collaboration_id = call.collaboration_id,
                    .round = call.round,
                } },
                .system_prompt = system_prompt,
                .visible_input = .{ .canonical_turn = .{
                    .supplemental_context = visible_context,
                } },
                .response_schema_json = null,
            } });
        }

        fn rejectConsultationProtocol(
            self: *Self,
            frame_index: usize,
            reason: []const u8,
            previous_output: []const u8,
            caused_by_run_id: []const u8,
            sink: host.IntentSink,
        ) !void {
            const session = &self.session.?;
            const frame = &session.consultation_frames.items[frame_index];
            const call = peerCallById(session, frame.parent, frame.id) orelse
                return error.UnknownConsultationCall;
            if (frame.protocol_corrections < max_protocol_corrections) {
                frame.protocol_corrections += 1;
                var evidence: std.Io.Writer.Allocating = .init(self.allocator);
                defer evidence.deinit();
                try std.json.Stringify.value(.{ .protocol_correction = .{
                    .validation_error = reason,
                    .previous_terminal_output = previous_output,
                } }, .{}, &evidence.writer);
                const correction = try std.fmt.allocPrint(
                    self.allocator,
                    "Your previous consultation response was invalid. Return a contribution object, or coordinate direct child calls using the consultation protocol, with no surrounding prose.\n{s}",
                    .{evidence.written()},
                );
                defer self.allocator.free(correction);
                try self.emitRoleActivity(
                    sink,
                    frame.agent_id,
                    "correcting consultation response format",
                );
                try self.startConsultationRun(frame_index, correction, sink);
                return;
            }

            try peer_mod.recordFailure(
                self.allocator,
                call,
                "peer returned an invalid consultation result",
            );
            frame.completed = true;
            try self.trace(sink, self.runTrace(
                "peer_consultation_failed",
                caused_by_run_id,
                "",
                call.peer_id,
                reason,
            ));
            try sink.emit(.{ .notice = .{
                .tone = .warning,
                .text = "A Team consultation failed; its immediate caller will decide how to continue.",
            } });
            const parent = frame.parent;
            try self.scheduleAllReadyPeers(sink);
            try self.maybeResumeOwnerAfterTeamWork(parent, caused_by_run_id, sink);
        }

        fn contextBearingProjection(
            self: *Self,
            transient_state: []const u8,
        ) ![]u8 {
            const session = &self.session.?;
            var instruction_output: std.Io.Writer.Allocating = .init(self.allocator);
            defer instruction_output.deinit();
            try std.json.Stringify.value(.{
                .in_session_user_instructions = session.instructions.items,
            }, .{}, &instruction_output.writer);
            const instruction_projection = instruction_output.written();
            const transient = std.mem.trim(u8, transient_state, " \t\r\n");
            const current_state = if (transient.len == 0)
                try self.allocator.dupe(u8, instruction_projection)
            else
                try std.fmt.allocPrint(
                    self.allocator,
                    "{s}\n{s}",
                    .{ instruction_projection, transient },
                );
            defer self.allocator.free(current_state);
            return context_mod.runtimeProjection(
                self.allocator,
                session.conversation_context,
                current_state,
            );
        }

        fn cancelAllSpecialistRuns(self: *Self, sink: host.IntentSink) !void {
            try self.cancelOwnerSpecialistRuns(.leader, sink);
            var index: usize = 0;
            while (index < self.session.?.consultation_frames.items.len) : (index += 1) {
                try self.cancelOwnerSpecialistRuns(.{ .consultation = index }, sink);
            }
        }

        fn cancelOwnerSpecialistRuns(
            self: *Self,
            owner: WorkOwner,
            sink: host.IntentSink,
        ) !void {
            const calls = ownerSpecialistCalls(&self.session.?, owner).* orelse return;
            for (calls) |*call| {
                switch (call.status) {
                    .requested, .running => {
                        if (call.run_id) |run_id| {
                            try sink.emit(.{ .cancel_agent_run = .{ .run_id = run_id } });
                            self.allocator.free(run_id);
                            call.run_id = null;
                        }
                        call.status = .cancelled;
                    },
                    .pending => call.status = .cancelled,
                    .completed, .failed, .cancelled => {},
                }
            }
        }

        fn cancelAllPeerRuns(self: *Self, sink: host.IntentSink) !void {
            try self.cancelOwnerPeerRuns(.leader, sink);
            var index: usize = 0;
            while (index < self.session.?.consultation_frames.items.len) : (index += 1) {
                try self.cancelOwnerPeerRuns(.{ .consultation = index }, sink);
            }
        }

        fn cancelOwnerPeerRuns(
            self: *Self,
            owner: WorkOwner,
            sink: host.IntentSink,
        ) !void {
            const calls = ownerPeerCalls(&self.session.?, owner).* orelse return;
            for (calls) |*call| {
                switch (call.status) {
                    .requested, .running => {
                        if (call.run_id) |run_id| {
                            try sink.emit(.{ .cancel_agent_run = .{ .run_id = run_id } });
                            self.allocator.free(run_id);
                            call.run_id = null;
                        }
                        call.status = .cancelled;
                    },
                    .pending, .waiting => call.status = .cancelled,
                    .completed, .failed, .cancelled => {},
                }
            }
        }

        fn clearActiveTeamWork(self: *Self) void {
            const session = &self.session.?;
            if (session.specialist_calls) |calls| specialist_mod.deinitCalls(self.allocator, calls);
            session.specialist_calls = null;
            if (session.peer_calls) |calls| peer_mod.deinitCalls(self.allocator, calls);
            session.peer_calls = null;
            for (session.consultation_frames.items) |*frame| frame.deinit(self.allocator);
            session.consultation_frames.clearRetainingCapacity();
        }

        fn failAgentRun(self: *Self, failed: host.AgentRunFailed, sink: host.IntentSink) !void {
            const session = if (self.session) |*value| value else return;
            if (peerCallLocation(session, failed.run_id)) |location| {
                const call = peerCallAt(session, location);
                const frame_index = consultationFrameIndex(session, call.id) orelse
                    return error.UnknownConsultationFrame;
                if (call.run_id) |run_id| self.allocator.free(run_id);
                call.run_id = null;
                try peer_mod.recordFailure(self.allocator, call, failed.message);
                session.consultation_frames.items[frame_index].completed = true;
                try self.trace(sink, self.runTrace(
                    "peer_consultation_failed",
                    failed.run_id,
                    "",
                    call.peer_id,
                    if (failed.interrupted) "interrupted" else "provider_or_runtime_failure",
                ));
                const parent = session.consultation_frames.items[frame_index].parent;
                try self.emitActivity(
                    sink,
                    call.peer_id,
                    ownerAgentId(session, parent),
                    "consultation failed",
                    .warning,
                );
                try self.scheduleAllReadyPeers(sink);
                try self.maybeResumeOwnerAfterTeamWork(parent, failed.run_id, sink);
                return;
            }
            if (specialistCallLocation(session, failed.run_id)) |location| {
                const call = specialistCallAt(session, location);
                if (call.run_id) |run_id| self.allocator.free(run_id);
                call.run_id = null;
                try specialist_mod.recordFailure(self.allocator, call, failed.message);
                try self.trace(sink, self.runTrace(
                    "specialist_run_failed",
                    failed.run_id,
                    "",
                    call.specialist_id,
                    if (failed.interrupted) "interrupted" else "provider_or_runtime_failure",
                ));
                try self.emitActivity(
                    sink,
                    call.specialist_id,
                    ownerAgentId(session, location.owner),
                    "specialist failed",
                    .warning,
                );
                try self.maybeResumeOwnerAfterTeamWork(location.owner, failed.run_id, sink);
                return;
            }
            const current_run_id = session.current_run_id orelse return;
            if (!std.mem.eql(u8, current_run_id, failed.run_id)) {
                try self.trace(sink, self.runTrace("run_failure_ignored", failed.run_id, current_run_id, "", "stale_run"));
                return;
            }
            const failed_agent_id = session.current_agent_id;
            const failure_detail = try formatRunFailureDetail(
                self.allocator,
                failed.kind,
                failed.http_status,
                failed.message,
            );
            defer self.allocator.free(failure_detail);
            const failure_notice = try formatRunFailureNotice(
                self.allocator,
                self.team,
                failed_agent_id,
                failed.kind,
                failed.message,
            );
            defer self.allocator.free(failure_notice);
            self.allocator.free(current_run_id);
            session.current_run_id = null;
            session.current_agent_id = "";
            session.current_turn = 0;
            session.current_run_started = false;
            try session.projection.apply(.{
                .sequence = session.projection.last_sequence + 1,
                .data = .session_failed,
            });
            try self.trace(sink, self.runTrace(
                "agent_run_failed",
                failed.run_id,
                "",
                failed_agent_id,
                failure_detail,
            ));
            try sink.emit(.{ .notice = .{
                .tone = .failure,
                .text = failure_notice,
            } });
            try sink.emit(.turn_failed);
        }

        fn cancel(self: *Self, sink: host.IntentSink) !void {
            const session = if (self.session) |*value| value else return;
            if (session.projection.terminal()) return;
            if (session.current_run_id) |run_id| {
                try sink.emit(.{ .cancel_agent_run = .{ .run_id = run_id } });
                self.allocator.free(run_id);
                session.current_run_id = null;
                session.current_agent_id = "";
                session.current_turn = 0;
                session.current_run_started = false;
            }
            try self.cancelAllSpecialistRuns(sink);
            try self.cancelAllPeerRuns(sink);
            try session.projection.apply(.{
                .sequence = session.projection.last_sequence + 1,
                .data = .session_cancelled,
            });
            try self.trace(sink, self.sessionTrace("session_cancelled", "user_requested"));
        }

        fn startAgentRun(
            self: *Self,
            agent_id: []const u8,
            scope: host.AgentRunScope,
            caused_by_run_id: []const u8,
            context_projection: []const u8,
            sink: host.IntentSink,
        ) !void {
            const session = &self.session.?;
            const team = self.team;
            const agent = team.agent(agent_id) orelse return error.UnknownAgent;
            const model = team.model(agent.model_id) orelse return error.UnknownModel;
            const turn = session.projection.agent_turns + 1;
            const run_ordinal = session.next_run_ordinal;
            session.next_run_ordinal = std.math.add(u32, run_ordinal, 1) catch
                return error.SessionRunLimitReached;
            const run_id = try std.fmt.allocPrint(
                self.allocator,
                "{s}:run:{d}:request:{d}",
                .{ session.session_id, turn, run_ordinal },
            );
            errdefer self.allocator.free(run_id);
            session.current_run_id = run_id;
            // Canonicalize potentially model-authored handoff bytes back to
            // the pinned Team revision before retaining them asynchronously.
            session.current_agent_id = agent.id;
            session.current_turn = turn;
            session.current_run_started = false;
            errdefer {
                session.current_run_id = null;
                session.current_agent_id = "";
                session.current_turn = 0;
                session.current_run_started = false;
            }

            const system_prompt = try buildAgentSystemPrompt(
                self.allocator,
                team,
                agent,
            );
            defer self.allocator.free(system_prompt);
            const visible_context = try self.contextBearingProjection(context_projection);
            defer self.allocator.free(visible_context);
            try self.trace(sink, self.runTrace(
                "agent_run_requested",
                run_id,
                caused_by_run_id,
                agent_id,
                "",
            ));
            try sink.emit(.{
                .start_agent_run = .{
                    .run_id = run_id,
                    .context_key = agent.id,
                    .authority = .{
                        .source_turn_id = session.source_turn_id,
                        .instruction_source_turn_ids = session.instruction_source_turn_ids.items,
                    },
                    .model = .{
                        .provider_id = team.provider_id,
                        .route = model.route,
                        .name = model.name,
                        .reasoning_effort = model.reasoning_effort,
                    },
                    .scope = scope,
                    .system_prompt = system_prompt,
                    .visible_input = .{ .canonical_turn = .{
                        .supplemental_context = visible_context,
                    } },
                    // Do not force a terminal JSON response format onto every
                    // provider step: leaders and peers must remain able to enter
                    // fx's ordinary tool loop. The terminal bytes are parsed and
                    // policy-checked strictly in completeAgentRun.
                    .response_schema_json = null,
                },
            });
        }

        fn retryMalformedTerminalOutput(
            self: *Self,
            agent_id: []const u8,
            failure_reason: []const u8,
            previous_output: []const u8,
            caused_by_run_id: []const u8,
            sink: host.IntentSink,
        ) !bool {
            const session = &self.session.?;
            if (session.protocol_corrections >= max_protocol_corrections) return false;
            session.protocol_corrections += 1;
            try self.trace(sink, self.runTrace(
                "agent_protocol_correction_requested",
                "",
                caused_by_run_id,
                agent_id,
                failure_reason,
            ));
            var evidence: std.Io.Writer.Allocating = .init(self.allocator);
            defer evidence.deinit();
            try std.json.Stringify.value(.{ .protocol_correction = .{
                .validation_error = failure_reason,
                .previous_terminal_output = previous_output,
            } }, .{}, &evidence.writer);
            const correction = try std.fmt.allocPrint(
                self.allocator,
                "Your previous terminal response was invalid. Correct the exact defect recorded below. The exact user turn remains available separately. After any necessary tool work, return exactly one of the answer, coordinate, or handoff JSON objects defined by your system prompt, with no Markdown or surrounding prose.\n{s}",
                .{evidence.written()},
            );
            defer self.allocator.free(correction);
            try self.emitRoleActivity(
                sink,
                agent_id,
                "correcting response format",
            );
            try self.startAgentRun(
                agent_id,
                .{ .leader = .{ .agent_id = agent_id } },
                caused_by_run_id,
                correction,
                sink,
            );
            return true;
        }

        fn rejectAgentProtocol(
            self: *Self,
            agent_id: []const u8,
            reason: []const u8,
            previous_output: []const u8,
            caused_by_run_id: []const u8,
            sink: host.IntentSink,
        ) !void {
            if (try self.retryMalformedTerminalOutput(
                agent_id,
                reason,
                previous_output,
                caused_by_run_id,
                sink,
            )) return;
            try self.failProtocol(reason, caused_by_run_id, sink);
        }

        fn failProtocol(
            self: *Self,
            reason: []const u8,
            caused_by_run_id: []const u8,
            sink: host.IntentSink,
        ) !void {
            const session = &self.session.?;
            try session.projection.apply(.{
                .sequence = session.projection.last_sequence + 1,
                .data = .session_failed,
            });
            try self.trace(sink, self.runTrace(
                "agent_protocol_rejected",
                "",
                caused_by_run_id,
                "",
                reason,
            ));
            try sink.emit(.{ .notice = .{
                .tone = .failure,
                .text = "Fixer rejected an invalid agent coordination result.",
            } });
            try sink.emit(.turn_failed);
        }

        fn clearSession(self: *Self) void {
            if (self.session) |*session| session.deinit(self.allocator);
            self.session = null;
        }

        fn ownerSpecialistCalls(
            session: *Session,
            owner: WorkOwner,
        ) *?[]specialist_mod.Call {
            return switch (owner) {
                .leader => &session.specialist_calls,
                .consultation => |index| &session.consultation_frames.items[index].specialist_calls,
            };
        }

        fn ownerPeerCalls(session: *Session, owner: WorkOwner) *?[]peer_mod.Call {
            return switch (owner) {
                .leader => &session.peer_calls,
                .consultation => |index| &session.consultation_frames.items[index].peer_calls,
            };
        }

        fn ownerAgentId(session: *Session, owner: WorkOwner) []const u8 {
            return switch (owner) {
                .leader => session.projection.leader_id,
                .consultation => |index| session.consultation_frames.items[index].agent_id,
            };
        }

        fn ownerDepth(session: *Session, owner: WorkOwner) u8 {
            return switch (owner) {
                .leader => 0,
                .consultation => |index| session.consultation_frames.items[index].depth,
            };
        }

        fn specialistCallAt(
            session: *Session,
            location: CallLocation,
        ) *specialist_mod.Call {
            return &ownerSpecialistCalls(session, location.owner).*.?[location.index];
        }

        fn peerCallAt(session: *Session, location: CallLocation) *peer_mod.Call {
            return &ownerPeerCalls(session, location.owner).*.?[location.index];
        }

        fn peerCallById(
            session: *Session,
            owner: WorkOwner,
            id: []const u8,
        ) ?*peer_mod.Call {
            const calls = ownerPeerCalls(session, owner).* orelse return null;
            for (calls) |*call| {
                if (std.mem.eql(u8, call.id, id)) return call;
            }
            return null;
        }

        fn specialistCallLocation(
            session: *Session,
            run_id: []const u8,
        ) ?CallLocation {
            if (callIndexByRunId(specialist_mod.Call, session.specialist_calls, run_id)) |index| {
                return .{ .owner = .leader, .index = index };
            }
            for (session.consultation_frames.items, 0..) |frame, frame_index| {
                if (callIndexByRunId(specialist_mod.Call, frame.specialist_calls, run_id)) |index| {
                    return .{ .owner = .{ .consultation = frame_index }, .index = index };
                }
            }
            return null;
        }

        fn peerCallLocation(session: *Session, run_id: []const u8) ?CallLocation {
            if (callIndexByRunId(peer_mod.Call, session.peer_calls, run_id)) |index| {
                return .{ .owner = .leader, .index = index };
            }
            for (session.consultation_frames.items, 0..) |frame, frame_index| {
                if (callIndexByRunId(peer_mod.Call, frame.peer_calls, run_id)) |index| {
                    return .{ .owner = .{ .consultation = frame_index }, .index = index };
                }
            }
            return null;
        }

        fn callIndexByRunId(
            comptime Call: type,
            optional_calls: ?[]Call,
            run_id: []const u8,
        ) ?usize {
            const calls = optional_calls orelse return null;
            for (calls, 0..) |call, index| {
                if (call.run_id) |candidate| {
                    if (std.mem.eql(u8, candidate, run_id)) return index;
                }
            }
            return null;
        }

        fn consultationFrameIndex(session: *Session, id: []const u8) ?usize {
            for (session.consultation_frames.items, 0..) |frame, index| {
                if (std.mem.eql(u8, frame.id, id)) return index;
            }
            return null;
        }

        fn peerSurfaceReserved(session: *Session, peer_id: []const u8) bool {
            if (peerCallsReserveSurface(session.peer_calls, peer_id)) return true;
            for (session.consultation_frames.items) |frame| {
                if (peerCallsReserveSurface(frame.peer_calls, peer_id)) return true;
            }
            return false;
        }

        fn peerCallsReserveSurface(
            optional_calls: ?[]peer_mod.Call,
            peer_id: []const u8,
        ) bool {
            const calls = optional_calls orelse return false;
            for (calls) |call| {
                if (!std.mem.eql(u8, call.peer_id, peer_id)) continue;
                switch (call.status) {
                    .requested, .running, .waiting => return true,
                    .pending, .completed, .failed, .cancelled => {},
                }
            }
            return false;
        }

        fn agentInOwnerAncestry(
            session: *Session,
            initial_owner: WorkOwner,
            agent_id: []const u8,
        ) bool {
            var owner = initial_owner;
            var remaining: u8 = max_consultation_depth + 1;
            while (remaining > 0) : (remaining -= 1) {
                if (std.mem.eql(u8, ownerAgentId(session, owner), agent_id)) return true;
                switch (owner) {
                    .leader => return false,
                    .consultation => |index| owner = session.consultation_frames.items[index].parent,
                }
            }
            return true;
        }

        fn trace(_: *Self, sink: host.IntentSink, record: host.TraceRecord) !void {
            try sink.emit(.{ .trace = record });
        }

        fn roleModel(self: *Self, role_id: []const u8) ?team_mod.Model {
            const model_id = if (self.team.agent(role_id)) |agent|
                agent.model_id
            else if (self.team.specialist(role_id)) |specialist|
                specialist.model_id
            else
                return null;
            return self.team.model(model_id);
        }

        fn modelLabel(self: *Self, role_id: []const u8) ![]u8 {
            const model = self.roleModel(role_id) orelse return error.UnknownModel;
            if (std.mem.eql(u8, self.team.provider_id, "opencode") and
                std.mem.eql(u8, model.route, "zen"))
            {
                return self.allocator.dupe(u8, model.name);
            }
            return std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ model.route, model.name },
            );
        }

        fn emitActivity(
            self: *Self,
            sink: host.IntentSink,
            from_role_id: []const u8,
            to_role_id: []const u8,
            action: []const u8,
            tone: host.NoticeTone,
        ) !void {
            const from_model = try self.modelLabel(from_role_id);
            defer self.allocator.free(from_model);
            const to_model = try self.modelLabel(to_role_id);
            defer self.allocator.free(to_model);
            const text = try std.fmt.allocPrint(
                self.allocator,
                "{s} → {s} · {s}.",
                .{ from_model, to_model, action },
            );
            defer self.allocator.free(text);
            try sink.emit(.{ .notice = .{
                .tone = tone,
                .text = text,
            } });
        }

        fn emitRoleActivity(
            self: *Self,
            sink: host.IntentSink,
            role_id: []const u8,
            action: []const u8,
        ) !void {
            const model = try self.modelLabel(role_id);
            defer self.allocator.free(model);
            const text = try std.fmt.allocPrint(
                self.allocator,
                "{s} · {s}.",
                .{ model, action },
            );
            defer self.allocator.free(text);
            try sink.emit(.{ .notice = .{
                .tone = .info,
                .text = text,
            } });
        }

        fn sessionTrace(self: *Self, event: []const u8, detail: []const u8) host.TraceRecord {
            const session = &self.session.?;
            return .{
                .event = event,
                .session_id = session.session_id,
                .detail = detail,
            };
        }

        fn runTrace(
            self: *Self,
            event: []const u8,
            run_id: []const u8,
            caused_by_run_id: []const u8,
            agent_id: []const u8,
            detail: []const u8,
        ) host.TraceRecord {
            const session = &self.session.?;
            return .{
                .event = event,
                .session_id = session.session_id,
                .run_id = run_id,
                .caused_by_run_id = caused_by_run_id,
                .agent_id = agent_id,
                .detail = detail,
            };
        }
    };
}

fn formatRunFailureDetail(
    allocator: std.mem.Allocator,
    kind: test_host.AgentRunFailureKind,
    http_status: ?u16,
    message: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("kind={s}", .{@tagName(kind)});
    if (http_status) |status| try out.writer.print(" http_status={d}", .{status});
    if (message.len > 0) try out.writer.print(" message={s}", .{message});
    return out.toOwnedSlice();
}

fn formatRunFailureNotice(
    allocator: std.mem.Allocator,
    team: team_mod.Team,
    agent_id: []const u8,
    kind: test_host.AgentRunFailureKind,
    message: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.print("Team \"{s}\" could not run", .{team.name});
    if (agent_id.len > 0) try out.writer.print(" {s}", .{agent_id});
    if (team.agent(agent_id)) |agent| {
        if (team.model(agent.model_id)) |model| {
            try out.writer.print(" ({s} {s}/{s})", .{ team.provider_id, model.route, model.name });
        }
    }
    if (message.len > 0) try out.writer.print(": {s}", .{message});

    const recovery = switch (kind) {
        .authentication, .forbidden => "Check this Team model's provider access, choose another Team model, or sign in again.",
        .rate_limited => "Retry later or choose another Team model.",
        .invalid_request, .request_too_large => "Choose a compatible Team model or revise the Team configuration.",
        .provider_unavailable, .provider_error => "Retry or choose another Team model.",
        .interrupted => "The run was interrupted.",
        .runtime => "Check the orchestration trace for the retained runtime diagnosis.",
    };
    try out.writer.print(" · {s} Native fx remains available.", .{recovery});
    return out.toOwnedSlice();
}

test "top-level failure notice identifies pinned Team role model and recovery" {
    const notice = try formatRunFailureNotice(
        std.testing.allocator,
        team_mod.fixture(),
        "coder",
        .authentication,
        "API access denied · HTTP 401 · CreditsError: Insufficient balance",
    );
    defer std.testing.allocator.free(notice);

    try std.testing.expect(std.mem.find(u8, notice, "Coding team") != null);
    try std.testing.expect(std.mem.find(u8, notice, "coder") != null);
    try std.testing.expect(std.mem.find(u8, notice, "opencode free/deepseek-code") != null);
    try std.testing.expect(std.mem.find(u8, notice, "Insufficient balance") != null);
    try std.testing.expect(std.mem.find(u8, notice, "Native fx remains available") != null);
}

fn buildAgentSystemPrompt(
    allocator: std.mem.Allocator,
    team: team_mod.Team,
    agent: team_mod.Agent,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(
        \\You are a durable, context-bearing Team agent and currently hold sole leadership for the exact user turn supplied separately.
        \\Work on that turn and answer directly when you can. Collaboration is optional, not a ritual. Do not transfer leadership merely because another role could also perform the work, and honor an explicit user constraint not to call peers or specialists. A handoff is only for transferring ownership of the user's requested final result.
        \\A peer who receives leadership runs this same loop and may answer, coordinate, or hand leadership onward. A consultation is different: leadership remains here while the consulted peer may make its own authorized calls, synthesize their returns, and return one contribution. Every nested result unwinds only to its immediate caller. A specialist is a stateless leaf and receives only its caller-authored projection and explicitly selected attachments.
        \\Return exactly one JSON object and no Markdown after tool work. Answer with {"kind":"answer","answer":"..."}. Transfer leadership with {"kind":"handoff","peer_id":"exact-authorized-id","reason":"observable reason"}. Coordinate non-handoff Team work with {"kind":"coordinate","delegations":[{"key":"local-key","specialist_id":"exact-authorized-id","objective":"standalone task","context":"all explicit context","attachments":["selected turn reference"],"depends_on":["earlier local-key"]}],"peer_turns":[{"key":"local-key","peer_id":"exact-authorized-id","collaboration_id":"optional existing collaboration ID","objective":"requested contribution","context":"relevant durable context","attachments":["selected turn reference"]}]}. Either array may be omitted, but at least one call is required. Never invent a relationship or identifier. The next user turn begins at the Team primary regardless of who answers this one. Never expose private chain-of-thought.
        \\
        \\Pinned Team identity and relationships follow.
    );
    try writer.print(
        \\Pinned Team primary: {s}
        \\Current leader: {s}
        \\The user defined this role in these exact words:
        \\<role-definition>
        \\{s}
        \\</role-definition>
        \\Authorized leadership peers (IDs are exact and case-sensitive):
    , .{ team.primary.id, agent.id, agent.definition });
    var peer_count: usize = 0;
    if (team.arePeers(agent.id, team.primary.id) and
        !std.mem.eql(u8, agent.id, team.primary.id))
    {
        try writeRosterEntry(writer, team.primary.id, team.primary.definition);
        peer_count += 1;
    }
    for (team.peers) |peer| {
        if (std.mem.eql(u8, peer.id, agent.id) or
            !team.arePeers(agent.id, peer.id)) continue;
        try writeRosterEntry(writer, peer.id, peer.definition);
        peer_count += 1;
    }
    if (peer_count == 0) try writer.writeAll("(none)\n");

    try writer.writeAll(
        "Authorized stateless specialists (IDs are exact and case-sensitive):\n",
    );
    var specialist_count: usize = 0;
    for (team.specialists) |specialist_entry| {
        if (!team.canUseSpecialist(agent.id, specialist_entry.id)) continue;
        try writeRosterEntry(
            writer,
            specialist_entry.id,
            specialist_entry.definition,
        );
        specialist_count += 1;
    }
    if (specialist_count == 0) try writer.writeAll("(none)\n");
    return out.toOwnedSlice();
}

fn buildPeerConsultationSystemPrompt(
    allocator: std.mem.Allocator,
    team: team_mod.Team,
    peer: team_mod.Agent,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(
        \\You are a durable, context-bearing Team peer working on a consultation. You do not hold leadership, and this call does not transfer it. Work only on the supplied consultation objective, return only to your immediate caller, and do not answer the user.
        \\You may use ordinary tools and may call only the peers and specialists authorized below. Child calls may run independently, and their results return only to you. When you need child work, return {"kind":"coordinate","delegations":[{"key":"local-key","specialist_id":"exact-authorized-id","objective":"standalone task","context":"all explicit context","attachments":["selected turn reference"],"depends_on":["earlier local-key"]}],"peer_turns":[{"key":"local-key","peer_id":"exact-authorized-id","collaboration_id":"optional existing collaboration ID","objective":"requested contribution","context":"relevant durable context","attachments":["selected turn reference"]}]}. Either array may be omitted, but at least one call is required.
        \\After all direct and nested work is complete, return exactly one JSON object and no Markdown: {"result":"concise but complete contribution","findings":["material finding"],"risks":["material risk or uncertainty"],"confidence":0.0}. Confidence must be between 0 and 1. Never invent a relationship or identifier. Never expose private chain-of-thought.
        \\
        \\Pinned consultation identity and relationships follow.
    );
    try writer.print(
        \\Pinned Team primary: {s}
        \\Consulting peer: {s}
        \\The user defined this role in these exact words:
        \\<role-definition>
        \\{s}
        \\</role-definition>
        \\Authorized peers (IDs are exact and case-sensitive):
    , .{ team.primary.id, peer.id, peer.definition });
    var peer_count: usize = 0;
    if (team.arePeers(peer.id, team.primary.id) and
        !std.mem.eql(u8, peer.id, team.primary.id))
    {
        try writeRosterEntry(writer, team.primary.id, team.primary.definition);
        peer_count += 1;
    }
    for (team.peers) |candidate| {
        if (std.mem.eql(u8, candidate.id, peer.id) or
            !team.arePeers(peer.id, candidate.id)) continue;
        try writeRosterEntry(writer, candidate.id, candidate.definition);
        peer_count += 1;
    }
    if (peer_count == 0) try writer.writeAll("(none)\n");
    try writer.writeAll("Authorized specialists (IDs are exact and case-sensitive):\n");
    var specialist_count: usize = 0;
    for (team.specialists) |specialist_entry| {
        if (!team.canUseSpecialist(peer.id, specialist_entry.id)) continue;
        try writeRosterEntry(writer, specialist_entry.id, specialist_entry.definition);
        specialist_count += 1;
    }
    if (specialist_count == 0) try writer.writeAll("(none)\n");
    return out.toOwnedSlice();
}

fn writeRosterEntry(
    writer: *std.Io.Writer,
    id: []const u8,
    definition: []const u8,
) !void {
    try writer.print("ID {s}\n<definition>\n{s}\n</definition>\n", .{
        id,
        definition,
    });
}

test "leader prompt names only exact authorized Team relationships" {
    const team = team_mod.fixture();
    const coder_prompt = try buildAgentSystemPrompt(
        std.testing.allocator,
        team,
        team.primary,
    );
    defer std.testing.allocator.free(coder_prompt);
    try std.testing.expect(std.mem.find(u8, coder_prompt, "ID researcher") != null);
    try std.testing.expect(std.mem.find(u8, coder_prompt, "ID vision-reader") != null);
    try std.testing.expect(std.mem.find(u8, coder_prompt, "IDs are exact and case-sensitive") != null);

    const researcher = team.agent("researcher").?;
    const researcher_prompt = try buildAgentSystemPrompt(
        std.testing.allocator,
        team,
        researcher,
    );
    defer std.testing.allocator.free(researcher_prompt);
    try std.testing.expect(std.mem.find(u8, researcher_prompt, "ID coder") != null);
    try std.testing.expect(std.mem.find(u8, researcher_prompt, "ID vision-reader") == null);
}

fn cloneStrings(allocator: std.mem.Allocator, values: []const []const u8) ![][]u8 {
    const result = try allocator.alloc([]u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |value| allocator.free(value);
        allocator.free(result);
    }
    for (values, 0..) |value, index| {
        result[index] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return result;
}

fn mergeUniqueStrings(
    allocator: std.mem.Allocator,
    existing: []const []const u8,
    additions: []const []const u8,
) ![][]u8 {
    var count = existing.len;
    for (additions, 0..) |addition, index| {
        var found = false;
        for (existing) |value| {
            if (std.mem.eql(u8, value, addition)) {
                found = true;
                break;
            }
        }
        if (!found) for (additions[0..index]) |prior| {
            if (std.mem.eql(u8, prior, addition)) {
                found = true;
                break;
            }
        };
        if (!found) count += 1;
    }
    const result = try allocator.alloc([]u8, count);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |value| allocator.free(value);
        allocator.free(result);
    }
    for (existing) |value| {
        result[initialized] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    for (additions) |addition| {
        var found = false;
        for (existing) |value| {
            if (std.mem.eql(u8, value, addition)) {
                found = true;
                break;
            }
        }
        if (found) continue;
        for (result[existing.len..initialized]) |prior| {
            if (std.mem.eql(u8, prior, addition)) {
                found = true;
                break;
            }
        }
        if (found) continue;
        result[initialized] = try allocator.dupe(u8, addition);
        initialized += 1;
    }
    std.debug.assert(initialized == result.len);
    return result;
}

fn freeStrings(allocator: std.mem.Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "in-session user instruction interrupts and restarts the same leader with canonical authority" {
    const Capture = struct {
        run_count: usize = 0,
        run_ids: [2][192]u8 = undefined,
        run_id_lens: [2]usize = .{ 0, 0 },
        supplemental: [2][4096]u8 = undefined,
        supplemental_lens: [2]usize = .{ 0, 0 },
        instruction_counts: [2]usize = .{ 0, 0 },
        instruction_ids: [2]u64 = .{ 0, 0 },
        cancel_count: usize = 0,
        cancelled_run: [192]u8 = undefined,
        cancelled_run_len: usize = 0,
        answer: [128]u8 = undefined,
        answer_len: usize = 0,

        fn copyInto(destination: []u8, source: []const u8) usize {
            const len = @min(destination.len, source.len);
            @memcpy(destination[0..len], source[0..len]);
            return len;
        }

        fn emit(context: *anyopaque, intent: test_host.Intent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (intent) {
                .start_agent_run => |request| {
                    const index = self.run_count;
                    if (index >= self.run_ids.len) return error.TooManyRuns;
                    self.run_id_lens[index] = copyInto(&self.run_ids[index], request.run_id);
                    self.instruction_counts[index] = request.authority.instruction_source_turn_ids.len;
                    if (request.authority.instruction_source_turn_ids.len > 0) {
                        self.instruction_ids[index] = request.authority.instruction_source_turn_ids[0];
                    }
                    switch (request.visible_input) {
                        .canonical_turn => |input| self.supplemental_lens[index] = copyInto(
                            &self.supplemental[index],
                            input.supplemental_context,
                        ),
                        .projected => return error.LeaderReceivedProjectedInput,
                    }
                    self.run_count += 1;
                },
                .cancel_agent_run => |request| {
                    self.cancel_count += 1;
                    self.cancelled_run_len = copyInto(&self.cancelled_run, request.run_id);
                },
                .publish_answer => |answer| {
                    self.answer_len = copyInto(&self.answer, answer.text);
                },
                .trace, .mode_entered, .mode_left, .notice, .turn_failed => {},
            }
        }

        fn runId(self: *@This(), index: usize) []const u8 {
            return self.run_ids[index][0..self.run_id_lens[index]];
        }

        fn visible(self: *@This(), index: usize) []const u8 {
            return self.supplemental[index][0..self.supplemental_lens[index]];
        }
    };

    var runtime = Runtime(test_host).init(std.testing.allocator, team_mod.fixture());
    defer runtime.deinit();
    var capture = Capture{};
    const sink = test_host.IntentSink{ .context = &capture, .emit_fn = Capture.emit };
    const providers = [_]test_host.ProviderDescriptor{.{
        .id = "opencode",
        .display_name = "OpenCode",
        .catalog_scope = .unified,
    }};
    try runtime.dispatch(.{ .enter = .{
        .conversation_id = "conversation-steering",
        .workspace_path = "/workspace",
        .providers = &providers,
    } }, sink);
    try runtime.dispatch(.{ .user_turn = .{
        .session_id = "steering-session",
        .source_turn_id = 401,
        .text = "Implement the original request.",
        .attachment_references = &.{"image:1"},
    } }, sink);
    const first_run = try std.testing.allocator.dupe(u8, capture.runId(0));
    defer std.testing.allocator.free(first_run);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = first_run } }, sink);

    try runtime.dispatch(.{ .user_instruction = .{
        .source_turn_id = 402,
        .text = "Preserve the fast path and inspect the new image.",
        .attachment_references = &.{"image:101"},
    } }, sink);
    try std.testing.expectEqual(@as(usize, 1), capture.cancel_count);
    try std.testing.expectEqualStrings(
        first_run,
        capture.cancelled_run[0..capture.cancelled_run_len],
    );
    try std.testing.expectEqual(@as(usize, 2), capture.run_count);
    try std.testing.expect(!std.mem.eql(u8, first_run, capture.runId(1)));
    try std.testing.expectEqual(@as(usize, 1), capture.instruction_counts[1]);
    try std.testing.expectEqual(@as(u64, 402), capture.instruction_ids[1]);
    try std.testing.expect(std.mem.find(u8, capture.visible(1), "Preserve the fast path") != null);
    try std.testing.expect(std.mem.find(u8, capture.visible(1), "image:101") != null);
    try std.testing.expectEqualStrings("steering-session", runtime.session.?.session_id);
    try std.testing.expectEqual(@as(u32, 1), runtime.session.?.projection.user_instructions);
    try std.testing.expectEqual(@as(u32, 1), runtime.session.?.projection.agent_turns);
    try std.testing.expectEqualStrings("coder", runtime.session.?.projection.leader_id);

    try runtime.dispatch(.{ .agent_run_failed = .{
        .run_id = first_run,
        .message = "cancelled for steering",
        .interrupted = true,
    } }, sink);
    try std.testing.expectEqual(projection_mod.Status.running, runtime.session.?.projection.status);
    try std.testing.expectEqualStrings(capture.runId(1), runtime.session.?.current_run_id.?);

    const second_run = try std.testing.allocator.dupe(u8, capture.runId(1));
    defer std.testing.allocator.free(second_run);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = second_run } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = second_run,
        .output = "{\"kind\":\"answer\",\"answer\":\"Steered answer\"}",
    } }, sink);
    try std.testing.expectEqualStrings("Steered answer", capture.answer[0..capture.answer_len]);
    try std.testing.expectEqual(projection_mod.Status.completed, runtime.session.?.projection.status);
}

test "one user turn can hand leadership to a peer and publish that peer answer" {
    const Capture = struct {
        run_count: usize = 0,
        run_ids: [2][128]u8 = undefined,
        run_id_lens: [2]usize = .{ 0, 0 },
        agent_ids: [2][64]u8 = undefined,
        agent_id_lens: [2]usize = .{ 0, 0 },
        source_turn_ids: [2]u64 = .{ 0, 0 },
        exact_models: bool = true,
        canonical_inputs: usize = 0,
        trace_events: [16][64]u8 = undefined,
        trace_lens: [16]usize = [_]usize{0} ** 16,
        trace_causes: [16][128]u8 = undefined,
        trace_cause_lens: [16]usize = [_]usize{0} ** 16,
        trace_runs: [16][128]u8 = undefined,
        trace_run_lens: [16]usize = [_]usize{0} ** 16,
        trace_count: usize = 0,
        answer: [256]u8 = undefined,
        answer_len: usize = 0,
        answer_agent: [64]u8 = undefined,
        answer_agent_len: usize = 0,
        handoff_notice: [128]u8 = undefined,
        handoff_notice_len: usize = 0,
        leader_activity: [1][128]u8 = undefined,
        leader_activity_lens: [1]usize = .{0},
        leader_activity_count: usize = 0,

        fn copyInto(destination: []u8, source: []const u8) usize {
            const len = @min(destination.len, source.len);
            @memcpy(destination[0..len], source[0..len]);
            return len;
        }

        fn emit(context: *anyopaque, intent: test_host.Intent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (intent) {
                .start_agent_run => |request| {
                    const index = self.run_count;
                    if (index >= self.run_ids.len) return error.TooManyRuns;
                    self.run_id_lens[index] = copyInto(&self.run_ids[index], request.run_id);
                    const agent_id = switch (request.scope) {
                        .leader => |scope| scope.agent_id,
                        .peer => |scope| scope.agent_id,
                        .specialist => |scope| scope.specialist_id,
                    };
                    self.agent_id_lens[index] = copyInto(&self.agent_ids[index], agent_id);
                    self.source_turn_ids[index] = request.authority.source_turn_id;
                    self.exact_models = self.exact_models and
                        std.mem.eql(u8, request.model.provider_id, "opencode") and
                        std.mem.eql(u8, request.model.route, "free") and
                        std.mem.eql(
                            u8,
                            request.model.name,
                            if (index == 0) "deepseek-code" else "research-model",
                        );
                    switch (request.visible_input) {
                        .canonical_turn => self.canonical_inputs += 1,
                        .projected => return error.LeaderReceivedProjectedInput,
                    }
                    self.run_count += 1;
                },
                .trace => |record| {
                    const index = self.trace_count;
                    if (index >= self.trace_events.len) return error.TooManyTraces;
                    self.trace_lens[index] = copyInto(&self.trace_events[index], record.event);
                    self.trace_cause_lens[index] = copyInto(
                        &self.trace_causes[index],
                        record.caused_by_run_id,
                    );
                    self.trace_run_lens[index] = copyInto(&self.trace_runs[index], record.run_id);
                    self.trace_count += 1;
                },
                .publish_answer => |answer| {
                    self.answer_len = copyInto(&self.answer, answer.text);
                    self.answer_agent_len = copyInto(&self.answer_agent, answer.agent_id);
                },
                .notice => |notice| {
                    if (std.mem.find(u8, notice.text, "leadership handed off") != null) {
                        self.handoff_notice_len = copyInto(&self.handoff_notice, notice.text);
                    }
                    if (std.mem.endsWith(u8, notice.text, "working.")) {
                        const index = self.leader_activity_count;
                        if (index >= self.leader_activity.len) return error.TooManyLeaderActivities;
                        self.leader_activity_lens[index] = copyInto(
                            &self.leader_activity[index],
                            notice.text,
                        );
                        self.leader_activity_count += 1;
                    }
                },
                .mode_entered, .mode_left, .cancel_agent_run, .turn_failed => {},
            }
        }

        fn runId(self: *@This(), index: usize) []const u8 {
            return self.run_ids[index][0..self.run_id_lens[index]];
        }

        fn agentId(self: *@This(), index: usize) []const u8 {
            return self.agent_ids[index][0..self.agent_id_lens[index]];
        }

        fn traceEvent(self: *@This(), index: usize) []const u8 {
            return self.trace_events[index][0..self.trace_lens[index]];
        }

        fn traceCause(self: *@This(), index: usize) []const u8 {
            return self.trace_causes[index][0..self.trace_cause_lens[index]];
        }

        fn traceRun(self: *@This(), index: usize) []const u8 {
            return self.trace_runs[index][0..self.trace_run_lens[index]];
        }

        fn leaderActivity(self: *@This(), index: usize) []const u8 {
            return self.leader_activity[index][0..self.leader_activity_lens[index]];
        }
    };

    var runtime = Runtime(test_host).init(std.testing.allocator, team_mod.fixture());
    defer runtime.deinit();
    var capture = Capture{};
    const sink = test_host.IntentSink{ .context = &capture, .emit_fn = Capture.emit };
    const providers = [_]test_host.ProviderDescriptor{.{
        .id = "opencode",
        .display_name = "OpenCode",
        .catalog_scope = .unified,
    }};
    try runtime.dispatch(.{ .enter = .{
        .conversation_id = "conversation-7",
        .workspace_path = "/workspace",
        .providers = &providers,
    } }, sink);
    try runtime.dispatch(.{ .user_turn = .{
        .session_id = "session-9",
        .source_turn_id = 41,
        .text = "Audit the evidence and answer.",
    } }, sink);
    try std.testing.expectEqual(@as(usize, 1), capture.run_count);
    try std.testing.expectEqualStrings("coder", capture.agentId(0));
    try std.testing.expectEqual(@as(u64, 41), capture.source_turn_ids[0]);
    try std.testing.expect(capture.exact_models);
    try std.testing.expectEqual(@as(usize, 1), capture.canonical_inputs);

    const primary_run_id = try std.testing.allocator.dupe(u8, capture.runId(0));
    defer std.testing.allocator.free(primary_run_id);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = primary_run_id } }, sink);
    try std.testing.expectEqualStrings(
        "free/deepseek-code · primary working.",
        capture.leaderActivity(0),
    );
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = primary_run_id,
        .output = "{\"kind\":\"handoff\",\"peer_id\":\"researcher\",\"reason\":\"Evidence is the deliverable\"}",
    } }, sink);
    try std.testing.expectEqual(@as(usize, 2), capture.run_count);
    try std.testing.expectEqualStrings("researcher", capture.agentId(1));
    try std.testing.expectEqual(@as(u64, 41), capture.source_turn_ids[1]);
    try std.testing.expect(capture.exact_models);
    try std.testing.expectEqual(@as(usize, 2), capture.canonical_inputs);
    try std.testing.expectEqualStrings(
        "free/deepseek-code → free/research-model · leadership handed off.",
        capture.handoff_notice[0..capture.handoff_notice_len],
    );

    const peer_run_id = try std.testing.allocator.dupe(u8, capture.runId(1));
    defer std.testing.allocator.free(peer_run_id);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = peer_run_id } }, sink);
    try std.testing.expectEqual(@as(usize, 1), capture.leader_activity_count);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = peer_run_id,
        .output = "{\"kind\":\"answer\",\"answer\":\"The audited answer.\"}",
    } }, sink);
    try std.testing.expectEqualStrings("researcher", capture.answer_agent[0..capture.answer_agent_len]);
    try std.testing.expectEqualStrings("The audited answer.", capture.answer[0..capture.answer_len]);
    try std.testing.expectEqual(projection_mod.Status.completed, runtime.session.?.projection.status);

    const expected_trace = [_][]const u8{
        "activation_accepted",
        "session_created",
        "context_view_committed",
        "leadership_transferred",
        "agent_run_requested",
        "agent_run_started",
        "agent_run_completed",
        "leadership_transferred",
        "agent_run_requested",
        "agent_run_started",
        "agent_run_completed",
        "answer_published",
    };
    try std.testing.expectEqual(expected_trace.len, capture.trace_count);
    for (expected_trace, 0..) |expected, index| {
        try std.testing.expectEqualStrings(expected, capture.traceEvent(index));
    }
    try std.testing.expectEqualStrings(primary_run_id, capture.traceCause(7));
    try std.testing.expectEqualStrings(primary_run_id, capture.traceCause(8));
    try std.testing.expectEqualStrings(peer_run_id, capture.traceRun(11));
}

test "leadership movement has no invented Fixer handoff ceiling" {
    const Capture = struct {
        run_count: usize = 0,
        run_ids: [8][128]u8 = undefined,
        run_id_lens: [8]usize = [_]usize{0} ** 8,
        agent_ids: [8][32]u8 = undefined,
        agent_id_lens: [8]usize = [_]usize{0} ** 8,
        answer_seen: bool = false,
        failed: bool = false,

        fn emit(context: *anyopaque, intent: test_host.Intent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (intent) {
                .start_agent_run => |request| {
                    const index = self.run_count;
                    if (index >= self.run_ids.len) return error.TooManyRuns;
                    self.run_id_lens[index] = copyInto(&self.run_ids[index], request.run_id);
                    const agent_id = switch (request.scope) {
                        .leader => |scope| scope.agent_id,
                        .peer => |scope| scope.agent_id,
                        .specialist => |scope| scope.specialist_id,
                    };
                    self.agent_id_lens[index] = copyInto(&self.agent_ids[index], agent_id);
                    self.run_count += 1;
                },
                .publish_answer => self.answer_seen = true,
                .turn_failed => self.failed = true,
                .mode_entered, .mode_left, .notice, .cancel_agent_run, .trace => {},
            }
        }

        fn copyInto(destination: []u8, source: []const u8) usize {
            const len = @min(destination.len, source.len);
            @memcpy(destination[0..len], source[0..len]);
            return len;
        }

        fn runId(self: *@This(), index: usize) []const u8 {
            return self.run_ids[index][0..self.run_id_lens[index]];
        }

        fn agentId(self: *@This(), index: usize) []const u8 {
            return self.agent_ids[index][0..self.agent_id_lens[index]];
        }
    };

    var runtime = Runtime(test_host).init(std.testing.allocator, team_mod.fixture());
    defer runtime.deinit();
    var capture = Capture{};
    const sink = test_host.IntentSink{ .context = &capture, .emit_fn = Capture.emit };
    const providers = [_]test_host.ProviderDescriptor{.{
        .id = "opencode",
        .display_name = "OpenCode",
        .catalog_scope = .unified,
    }};
    try runtime.dispatch(.{ .enter = .{
        .conversation_id = "conversation-unbounded-handoff",
        .workspace_path = "/workspace",
        .providers = &providers,
    } }, sink);
    try runtime.dispatch(.{ .user_turn = .{
        .session_id = "session-unbounded-handoff",
        .source_turn_id = 91,
        .text = "Follow the required ownership path.",
    } }, sink);

    for (0..6) |index| {
        const run_id = capture.runId(index);
        try runtime.dispatch(.{ .agent_run_started = .{ .run_id = run_id } }, sink);
        const target = if (index % 2 == 0) "researcher" else "coder";
        var output_buffer: [192]u8 = undefined;
        const output = try std.fmt.bufPrint(
            &output_buffer,
            "{{\"kind\":\"handoff\",\"peer_id\":\"{s}\",\"reason\":\"required ownership transition {d}\"}}",
            .{ target, index + 1 },
        );
        try runtime.dispatch(.{ .agent_run_completed = .{
            .run_id = run_id,
            .output = output,
        } }, sink);
        try std.testing.expectEqualStrings(target, capture.agentId(index + 1));
    }

    const final_run = capture.runId(6);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = final_run } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = final_run,
        .output = "{\"kind\":\"answer\",\"answer\":\"Ownership path complete.\"}",
    } }, sink);
    try std.testing.expectEqual(@as(usize, 7), capture.run_count);
    try std.testing.expect(capture.answer_seen);
    try std.testing.expect(!capture.failed);
    try std.testing.expectEqual(projection_mod.Status.completed, runtime.session.?.projection.status);

    try runtime.dispatch(.{ .user_turn = .{
        .session_id = "session-after-handoffs",
        .source_turn_id = 92,
        .text = "Start the next turn at the configured ingress.",
    } }, sink);
    try std.testing.expectEqual(@as(usize, 8), capture.run_count);
    try std.testing.expectEqualStrings("coder", capture.agentId(7));
    try std.testing.expectEqualStrings("coder", runtime.session.?.projection.leader_id);
}

test "nested consultations unwind one caller at a time while child work remains concurrent" {
    const models = [_]team_mod.Model{
        .{ .id = "alpha-model", .route = "go", .name = "alpha" },
        .{ .id = "beta-model", .route = "go", .name = "beta" },
        .{ .id = "gamma-model", .route = "go", .name = "gamma" },
        .{ .id = "lens-model", .route = "go", .name = "lens" },
    };
    const shared_specialists = [_][]const u8{"lens"};
    const peers = [_]team_mod.Agent{
        .{
            .id = "beta",
            .model_id = "beta-model",
            .definition = "Synthesize implementation evidence.",
            .specialists = &shared_specialists,
        },
        .{
            .id = "gamma",
            .model_id = "gamma-model",
            .definition = "Audit one bounded question.",
            .specialists = &shared_specialists,
        },
    };
    const specialists = [_]team_mod.Specialist{.{
        .id = "lens",
        .model_id = "lens-model",
        .definition = "Inspect only the supplied projection.",
    }};
    const team = team_mod.Team{
        .id = "recursive-team",
        .revision = 1,
        .digest = [_]u8{'0'} ** 64,
        .name = "Recursive team",
        .provider_id = "opencode",
        .models = &models,
        .primary = .{
            .id = "alpha",
            .model_id = "alpha-model",
            .definition = "Own the final answer.",
        },
        .peers = &peers,
        .specialists = &specialists,
    };
    try team.validate();

    const RunKind = enum { leader, peer, specialist };
    const Capture = struct {
        run_count: usize = 0,
        run_ids: [9][192]u8 = undefined,
        run_id_lens: [9]usize = [_]usize{0} ** 9,
        agent_ids: [9][32]u8 = undefined,
        agent_id_lens: [9]usize = [_]usize{0} ** 9,
        kinds: [9]RunKind = undefined,
        visible: [9][8192]u8 = undefined,
        visible_lens: [9]usize = [_]usize{0} ** 9,
        answer: [128]u8 = undefined,
        answer_len: usize = 0,
        notices: [16][128]u8 = undefined,
        notice_lens: [16]usize = [_]usize{0} ** 16,
        notice_count: usize = 0,
        failed: bool = false,

        fn copyInto(destination: []u8, source: []const u8) usize {
            const len = @min(destination.len, source.len);
            @memcpy(destination[0..len], source[0..len]);
            return len;
        }

        fn emit(context: *anyopaque, intent: test_host.Intent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (intent) {
                .start_agent_run => |request| {
                    const index = self.run_count;
                    if (index >= self.run_ids.len) return error.TooManyRuns;
                    self.run_id_lens[index] = copyInto(&self.run_ids[index], request.run_id);
                    const agent_id = switch (request.scope) {
                        .leader => |scope| scope.agent_id,
                        .peer => |scope| scope.agent_id,
                        .specialist => |scope| scope.specialist_id,
                    };
                    self.agent_id_lens[index] = copyInto(&self.agent_ids[index], agent_id);
                    self.kinds[index] = switch (request.scope) {
                        .leader => .leader,
                        .peer => .peer,
                        .specialist => .specialist,
                    };
                    const input = switch (request.visible_input) {
                        .canonical_turn => |value| value.supplemental_context,
                        .projected => |value| value.content,
                    };
                    self.visible_lens[index] = copyInto(&self.visible[index], input);
                    self.run_count += 1;
                },
                .publish_answer => |answer| {
                    self.answer_len = copyInto(&self.answer, answer.text);
                },
                .notice => |notice| {
                    if (self.notice_count >= self.notices.len) return error.TooManyNotices;
                    self.notice_lens[self.notice_count] = copyInto(
                        &self.notices[self.notice_count],
                        notice.text,
                    );
                    self.notice_count += 1;
                },
                .turn_failed => self.failed = true,
                .trace, .mode_entered, .mode_left, .cancel_agent_run => {},
            }
        }

        fn runId(self: *@This(), index: usize) []const u8 {
            return self.run_ids[index][0..self.run_id_lens[index]];
        }

        fn agentId(self: *@This(), index: usize) []const u8 {
            return self.agent_ids[index][0..self.agent_id_lens[index]];
        }

        fn visibleInput(self: *@This(), index: usize) []const u8 {
            return self.visible[index][0..self.visible_lens[index]];
        }

        fn hasNotice(self: *@This(), expected: []const u8) bool {
            for (self.notices[0..self.notice_count], 0..) |_, index| {
                if (std.mem.eql(
                    u8,
                    self.notices[index][0..self.notice_lens[index]],
                    expected,
                )) return true;
            }
            return false;
        }
    };

    var runtime = Runtime(test_host).init(std.testing.allocator, team);
    defer runtime.deinit();
    var capture = Capture{};
    const sink = test_host.IntentSink{ .context = &capture, .emit_fn = Capture.emit };
    const providers = [_]test_host.ProviderDescriptor{.{
        .id = "opencode",
        .display_name = "OpenCode",
        .catalog_scope = .unified,
    }};
    try runtime.dispatch(.{ .enter = .{
        .conversation_id = "recursive-conversation",
        .workspace_path = "/workspace",
        .providers = &providers,
    } }, sink);
    try runtime.dispatch(.{ .user_turn = .{
        .session_id = "recursive-session",
        .source_turn_id = 501,
        .text = "Exercise a recursive Team call tree.",
    } }, sink);

    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = capture.runId(0) } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = capture.runId(0),
        .output =
        \\{"kind":"coordinate","peer_turns":[{"key":"beta-review","peer_id":"beta","objective":"Synthesize a bounded review."}]}
        ,
    } }, sink);
    try std.testing.expectEqual(@as(usize, 2), capture.run_count);
    try std.testing.expectEqualStrings("beta", capture.agentId(1));

    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = capture.runId(1) } }, sink);
    try std.testing.expect(capture.hasNotice("go/alpha → go/beta · consultation started."));
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = capture.runId(1),
        .output =
        \\{"kind":"coordinate","delegations":[{"key":"beta-scan","specialist_id":"lens","objective":"Produce BETA-RAW."},{"key":"beta-compare","specialist_id":"lens","objective":"Compare BETA-RAW.","depends_on":["beta-scan"]}],"peer_turns":[{"key":"gamma-audit","peer_id":"gamma","objective":"Audit through your own specialist."}]}
        ,
    } }, sink);
    try std.testing.expectEqual(@as(usize, 4), capture.run_count);
    try std.testing.expectEqual(RunKind.specialist, capture.kinds[2]);
    try std.testing.expectEqualStrings("lens", capture.agentId(2));
    try std.testing.expectEqual(RunKind.peer, capture.kinds[3]);
    try std.testing.expectEqualStrings("gamma", capture.agentId(3));

    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = capture.runId(3) } }, sink);
    try std.testing.expect(capture.hasNotice("go/beta → go/gamma · consultation started."));
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = capture.runId(3),
        .output =
        \\{"kind":"coordinate","delegations":[{"key":"gamma-leaf","specialist_id":"lens","objective":"Produce GAMMA-RAW-LEAF."}]}
        ,
    } }, sink);
    try std.testing.expectEqual(@as(usize, 5), capture.run_count);
    try std.testing.expectEqual(RunKind.specialist, capture.kinds[4]);
    try std.testing.expectEqualStrings("lens", capture.agentId(4));

    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = capture.runId(4) } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = capture.runId(4),
        .output = "{\"result\":\"GAMMA-RAW-LEAF\",\"findings\":[],\"risks\":[],\"confidence\":1}",
    } }, sink);
    try std.testing.expect(capture.hasNotice("go/lens → go/gamma · specialist returned."));
    try std.testing.expectEqual(@as(usize, 6), capture.run_count);
    try std.testing.expectEqualStrings("gamma", capture.agentId(5));
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(5), "GAMMA-RAW-LEAF") != null);

    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = capture.runId(5) } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = capture.runId(5),
        .output = "{\"result\":\"GAMMA-SYNTHESIS\",\"findings\":[],\"risks\":[],\"confidence\":0.9}",
    } }, sink);
    try std.testing.expect(capture.hasNotice("go/gamma → go/beta · consultation returned."));
    try std.testing.expectEqual(@as(usize, 6), capture.run_count);

    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = capture.runId(2) } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = capture.runId(2),
        .output = "{\"result\":\"BETA-RAW\",\"findings\":[],\"risks\":[],\"confidence\":1}",
    } }, sink);
    try std.testing.expectEqual(@as(usize, 7), capture.run_count);
    try std.testing.expectEqual(RunKind.specialist, capture.kinds[6]);
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(6), "BETA-RAW") != null);

    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = capture.runId(6) } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = capture.runId(6),
        .output = "{\"result\":\"BETA-COMPARED\",\"findings\":[],\"risks\":[],\"confidence\":0.8}",
    } }, sink);
    try std.testing.expectEqual(@as(usize, 8), capture.run_count);
    try std.testing.expectEqualStrings("beta", capture.agentId(7));
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(7), "BETA-RAW") != null);
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(7), "BETA-COMPARED") != null);
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(7), "GAMMA-SYNTHESIS") != null);
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(7), "GAMMA-RAW-LEAF") == null);

    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = capture.runId(7) } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = capture.runId(7),
        .output = "{\"result\":\"BETA-SYNTHESIS\",\"findings\":[],\"risks\":[],\"confidence\":0.95}",
    } }, sink);
    try std.testing.expect(capture.hasNotice("go/beta → go/alpha · consultation returned."));
    try std.testing.expectEqual(@as(usize, 9), capture.run_count);
    try std.testing.expectEqualStrings("alpha", capture.agentId(8));
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(8), "BETA-SYNTHESIS") != null);
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(8), "GAMMA-SYNTHESIS") == null);
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(8), "BETA-RAW") == null);

    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = capture.runId(8) } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = capture.runId(8),
        .output = "{\"kind\":\"answer\",\"answer\":\"Recursive call tree complete.\"}",
    } }, sink);
    try std.testing.expectEqualStrings(
        "Recursive call tree complete.",
        capture.answer[0..capture.answer_len],
    );
    try std.testing.expect(!capture.failed);
    try std.testing.expectEqual(projection_mod.Status.completed, runtime.session.?.projection.status);
}

test "specialists run fresh in parallel and dependencies resume the leader" {
    const RunKind = enum { leader, peer, specialist };
    const Capture = struct {
        run_count: usize = 0,
        run_ids: [5][160]u8 = undefined,
        run_id_lens: [5]usize = [_]usize{0} ** 5,
        kinds: [5]RunKind = undefined,
        visible: [5][2048]u8 = undefined,
        visible_lens: [5]usize = [_]usize{0} ** 5,
        attachment_counts: [5]usize = [_]usize{0} ** 5,
        answer: [256]u8 = undefined,
        answer_len: usize = 0,

        fn copyInto(destination: []u8, source: []const u8) usize {
            const len = @min(destination.len, source.len);
            @memcpy(destination[0..len], source[0..len]);
            return len;
        }

        fn emit(context: *anyopaque, intent: test_host.Intent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (intent) {
                .start_agent_run => |request| {
                    const index = self.run_count;
                    if (index >= self.run_ids.len) return error.TooManyRuns;
                    self.run_id_lens[index] = copyInto(&self.run_ids[index], request.run_id);
                    self.kinds[index] = switch (request.scope) {
                        .leader => .leader,
                        .peer => .peer,
                        .specialist => .specialist,
                    };
                    switch (request.visible_input) {
                        .canonical_turn => |input| {
                            self.visible_lens[index] = copyInto(
                                &self.visible[index],
                                input.supplemental_context,
                            );
                        },
                        .projected => |input| {
                            self.visible_lens[index] = copyInto(&self.visible[index], input.content);
                            self.attachment_counts[index] = input.attachment_references.len;
                        },
                    }
                    self.run_count += 1;
                },
                .publish_answer => |answer| {
                    self.answer_len = copyInto(&self.answer, answer.text);
                },
                .trace, .mode_entered, .mode_left, .notice, .cancel_agent_run, .turn_failed => {},
            }
        }

        fn runId(self: *@This(), index: usize) []const u8 {
            return self.run_ids[index][0..self.run_id_lens[index]];
        }

        fn visibleInput(self: *@This(), index: usize) []const u8 {
            return self.visible[index][0..self.visible_lens[index]];
        }
    };

    var runtime = Runtime(test_host).init(std.testing.allocator, team_mod.fixture());
    defer runtime.deinit();
    var capture = Capture{};
    const sink = test_host.IntentSink{ .context = &capture, .emit_fn = Capture.emit };
    const providers = [_]test_host.ProviderDescriptor{.{
        .id = "opencode",
        .display_name = "OpenCode",
        .catalog_scope = .unified,
    }};
    try runtime.dispatch(.{ .enter = .{
        .conversation_id = "conversation",
        .workspace_path = "/workspace",
        .providers = &providers,
    } }, sink);
    const conversation_history = [_]test_host.ConversationTurn{.{
        .ordinal = 1,
        .status = .completed,
        .task = "PRIOR CONVERSATION TASK",
        .answer = "PRIOR CONVERSATION ANSWER",
    }};
    try runtime.dispatch(.{ .user_turn = .{
        .session_id = "specialist-session",
        .source_turn_id = 73,
        .text = "SECRET ORIGINAL USER TURN",
        .attachment_references = &.{ "image-a", "image-b" },
        .conversation_history = &conversation_history,
    } }, sink);
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(0), "PRIOR CONVERSATION ANSWER") != null);

    const leader_run = try std.testing.allocator.dupe(u8, capture.runId(0));
    defer std.testing.allocator.free(leader_run);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = leader_run } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = leader_run,
        .output =
        \\{"kind":"coordinate","delegations":[{"key":"read-a","specialist_id":"vision-reader","objective":"Read A.","attachments":["image-a"]},{"key":"read-b","specialist_id":"vision-reader","objective":"Read B.","attachments":["image-b"]},{"key":"compare","specialist_id":"vision-reader","objective":"Compare.","depends_on":["read-a","read-b"]}]}
        ,
    } }, sink);
    try std.testing.expectEqual(@as(usize, 3), capture.run_count);
    try std.testing.expectEqual(RunKind.specialist, capture.kinds[1]);
    try std.testing.expectEqual(RunKind.specialist, capture.kinds[2]);
    try std.testing.expectEqual(@as(usize, 1), capture.attachment_counts[1]);
    try std.testing.expectEqual(@as(usize, 1), capture.attachment_counts[2]);
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(1), "SECRET ORIGINAL") == null);
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(2), "SECRET ORIGINAL") == null);
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(1), "PRIOR CONVERSATION") == null);
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(2), "PRIOR CONVERSATION") == null);

    const read_a_run = try std.testing.allocator.dupe(u8, capture.runId(1));
    defer std.testing.allocator.free(read_a_run);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = read_a_run } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = read_a_run,
        .output = "{\"result\":\"alpha\",\"findings\":[],\"risks\":[],\"confidence\":1}",
    } }, sink);
    try std.testing.expectEqual(@as(usize, 3), capture.run_count);

    const read_b_run = try std.testing.allocator.dupe(u8, capture.runId(2));
    defer std.testing.allocator.free(read_b_run);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = read_b_run } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = read_b_run,
        .output = "{\"result\":\"beta\",\"findings\":[],\"risks\":[],\"confidence\":0.9}",
    } }, sink);
    try std.testing.expectEqual(@as(usize, 4), capture.run_count);
    try std.testing.expectEqual(RunKind.specialist, capture.kinds[3]);
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(3), "alpha") != null);
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(3), "beta") != null);
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(3), "SECRET ORIGINAL") == null);

    const compare_run = try std.testing.allocator.dupe(u8, capture.runId(3));
    defer std.testing.allocator.free(compare_run);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = compare_run } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = compare_run,
        .output = "{\"result\":\"alpha differs from beta\",\"findings\":[\"difference\"],\"risks\":[],\"confidence\":0.8}",
    } }, sink);
    try std.testing.expectEqual(@as(usize, 5), capture.run_count);
    try std.testing.expectEqual(RunKind.leader, capture.kinds[4]);
    try std.testing.expect(std.mem.find(u8, capture.visibleInput(4), "alpha differs from beta") != null);

    const resumed_leader_run = try std.testing.allocator.dupe(u8, capture.runId(4));
    defer std.testing.allocator.free(resumed_leader_run);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = resumed_leader_run } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = resumed_leader_run,
        .output = "{\"kind\":\"answer\",\"answer\":\"Compared answer\"}",
    } }, sink);
    try std.testing.expectEqualStrings("Compared answer", capture.answer[0..capture.answer_len]);
    try std.testing.expectEqual(projection_mod.Status.completed, runtime.session.?.projection.status);
}

test "peer consultations retain leadership and continue with durable rounds" {
    const RunKind = enum { leader, peer, specialist };
    const Capture = struct {
        run_count: usize = 0,
        run_ids: [5][192]u8 = undefined,
        run_id_lens: [5]usize = [_]usize{0} ** 5,
        kinds: [5]RunKind = undefined,
        supplemental: [5][4096]u8 = undefined,
        supplemental_lens: [5]usize = [_]usize{0} ** 5,
        systems: [5][4096]u8 = undefined,
        system_lens: [5]usize = [_]usize{0} ** 5,
        answer: [128]u8 = undefined,
        answer_len: usize = 0,

        fn copyInto(destination: []u8, source: []const u8) usize {
            const len = @min(destination.len, source.len);
            @memcpy(destination[0..len], source[0..len]);
            return len;
        }

        fn emit(context: *anyopaque, intent: test_host.Intent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (intent) {
                .start_agent_run => |request| {
                    const index = self.run_count;
                    if (index >= self.run_ids.len) return error.TooManyRuns;
                    self.run_id_lens[index] = copyInto(&self.run_ids[index], request.run_id);
                    self.kinds[index] = switch (request.scope) {
                        .leader => .leader,
                        .peer => .peer,
                        .specialist => .specialist,
                    };
                    self.system_lens[index] = copyInto(&self.systems[index], request.system_prompt);
                    switch (request.visible_input) {
                        .canonical_turn => |input| self.supplemental_lens[index] = copyInto(
                            &self.supplemental[index],
                            input.supplemental_context,
                        ),
                        .projected => return error.PeerReceivedStatelessProjection,
                    }
                    self.run_count += 1;
                },
                .publish_answer => |answer| self.answer_len = copyInto(&self.answer, answer.text),
                .trace, .mode_entered, .mode_left, .notice, .cancel_agent_run, .turn_failed => {},
            }
        }

        fn runId(self: *@This(), index: usize) []const u8 {
            return self.run_ids[index][0..self.run_id_lens[index]];
        }

        fn supplementalContext(self: *@This(), index: usize) []const u8 {
            return self.supplemental[index][0..self.supplemental_lens[index]];
        }

        fn system(self: *@This(), index: usize) []const u8 {
            return self.systems[index][0..self.system_lens[index]];
        }
    };

    var runtime = Runtime(test_host).init(std.testing.allocator, team_mod.fixture());
    defer runtime.deinit();
    var capture = Capture{};
    const sink = test_host.IntentSink{ .context = &capture, .emit_fn = Capture.emit };
    const providers = [_]test_host.ProviderDescriptor{.{
        .id = "opencode",
        .display_name = "OpenCode",
        .catalog_scope = .unified,
    }};
    try runtime.dispatch(.{ .enter = .{
        .conversation_id = "conversation",
        .workspace_path = "/workspace",
        .providers = &providers,
    } }, sink);
    const conversation_history = [_]test_host.ConversationTurn{.{
        .ordinal = 1,
        .status = .completed,
        .task = "Earlier review request",
        .answer = "DURABLE PRIOR ANSWER",
    }};
    try runtime.dispatch(.{ .user_turn = .{
        .session_id = "peer-session",
        .source_turn_id = 91,
        .text = "Review and answer.",
        .conversation_history = &conversation_history,
    } }, sink);
    try std.testing.expect(std.mem.find(u8, capture.supplementalContext(0), "DURABLE PRIOR ANSWER") != null);

    const leader_one = try std.testing.allocator.dupe(u8, capture.runId(0));
    defer std.testing.allocator.free(leader_one);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = leader_one } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = leader_one,
        .output =
        \\{"kind":"coordinate","peer_turns":[{"key":"review","peer_id":"researcher","objective":"Audit the approach.","context":"Focus on correctness."}]}
        ,
    } }, sink);
    try std.testing.expectEqual(@as(usize, 2), capture.run_count);
    try std.testing.expectEqual(RunKind.peer, capture.kinds[1]);
    try std.testing.expectEqualStrings("coder", runtime.session.?.projection.leader_id);
    try std.testing.expect(std.mem.find(u8, capture.supplementalContext(1), "\"holds_leadership\":false") != null);
    try std.testing.expect(std.mem.find(u8, capture.supplementalContext(1), "DURABLE PRIOR ANSWER") != null);
    try std.testing.expect(std.mem.find(u8, capture.system(1), "do not answer the user") != null);

    const peer_one = try std.testing.allocator.dupe(u8, capture.runId(1));
    defer std.testing.allocator.free(peer_one);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = peer_one } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = peer_one,
        .output = "{\"result\":\"first review\",\"findings\":[\"f1\"],\"risks\":[],\"confidence\":0.8}",
    } }, sink);
    try std.testing.expectEqual(@as(usize, 3), capture.run_count);
    try std.testing.expectEqual(RunKind.leader, capture.kinds[2]);
    try std.testing.expect(std.mem.find(u8, capture.supplementalContext(2), "first review") != null);
    try std.testing.expectEqual(@as(usize, 1), runtime.session.?.peer_history.items.len);
    const collaboration_id = runtime.session.?.peer_history.items[0].collaboration_id;

    const leader_two = try std.testing.allocator.dupe(u8, capture.runId(2));
    defer std.testing.allocator.free(leader_two);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = leader_two } }, sink);
    const continue_output = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"kind\":\"coordinate\",\"peer_turns\":[{{\"key\":\"review-again\",\"peer_id\":\"researcher\",\"collaboration_id\":\"{s}\",\"objective\":\"Recheck the revision.\"}}]}}",
        .{collaboration_id},
    );
    defer std.testing.allocator.free(continue_output);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = leader_two,
        .output = continue_output,
    } }, sink);
    try std.testing.expectEqual(@as(usize, 4), capture.run_count);
    try std.testing.expectEqual(RunKind.peer, capture.kinds[3]);
    try std.testing.expect(std.mem.find(u8, capture.supplementalContext(3), "first review") != null);
    try std.testing.expect(std.mem.find(u8, capture.supplementalContext(3), "\"current_round\":2") != null);
    try std.testing.expectEqualStrings("coder", runtime.session.?.projection.leader_id);

    const peer_two = try std.testing.allocator.dupe(u8, capture.runId(3));
    defer std.testing.allocator.free(peer_two);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = peer_two } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = peer_two,
        .output = "{\"result\":\"second review\",\"findings\":[],\"risks\":[],\"confidence\":0.9}",
    } }, sink);
    try std.testing.expectEqual(@as(usize, 5), capture.run_count);
    try std.testing.expect(std.mem.find(u8, capture.supplementalContext(4), "second review") != null);

    const leader_three = try std.testing.allocator.dupe(u8, capture.runId(4));
    defer std.testing.allocator.free(leader_three);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = leader_three } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = leader_three,
        .output = "{\"kind\":\"answer\",\"answer\":\"Reviewed answer\"}",
    } }, sink);
    try std.testing.expectEqualStrings("Reviewed answer", capture.answer[0..capture.answer_len]);
    try std.testing.expectEqualStrings("coder", runtime.session.?.projection.leader_id);
}

test "invalid model control output fails visibly without escaping dispatch" {
    const Capture = struct {
        run_id: [128]u8 = undefined,
        run_id_len: usize = 0,
        failed_notice: bool = false,
        rejected_trace: bool = false,
        correction_requested: bool = false,
        correction_preserved_evidence: bool = false,
        correction_notice: bool = false,
        turn_failed: bool = false,

        fn emit(context: *anyopaque, intent: test_host.Intent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (intent) {
                .start_agent_run => |request| {
                    self.run_id_len = @min(self.run_id.len, request.run_id.len);
                    @memcpy(self.run_id[0..self.run_id_len], request.run_id[0..self.run_id_len]);
                    switch (request.visible_input) {
                        .canonical_turn => |input| {
                            self.correction_preserved_evidence = self.correction_preserved_evidence or
                                (std.mem.find(u8, input.supplemental_context, "invalid_json") != null and
                                    std.mem.find(u8, input.supplemental_context, "not coordination JSON") != null);
                        },
                        .projected => {},
                    }
                },
                .notice => |notice| {
                    self.failed_notice = self.failed_notice or notice.tone == .failure;
                    self.correction_notice = self.correction_notice or
                        std.mem.eql(
                            u8,
                            notice.text,
                            "free/deepseek-code · correcting response format.",
                        );
                },
                .trace => |record| {
                    self.rejected_trace = self.rejected_trace or
                        std.mem.eql(u8, record.event, "agent_protocol_rejected");
                    self.correction_requested = self.correction_requested or
                        std.mem.eql(u8, record.event, "agent_protocol_correction_requested");
                },
                .turn_failed => self.turn_failed = true,
                .mode_entered, .mode_left, .cancel_agent_run, .publish_answer => {},
            }
        }
    };

    var runtime = Runtime(test_host).init(std.testing.allocator, team_mod.fixture());
    defer runtime.deinit();
    var capture = Capture{};
    const sink = test_host.IntentSink{ .context = &capture, .emit_fn = Capture.emit };
    const providers = [_]test_host.ProviderDescriptor{.{
        .id = "opencode",
        .display_name = "OpenCode",
        .catalog_scope = .unified,
    }};
    try runtime.dispatch(.{ .enter = .{
        .conversation_id = "conversation",
        .workspace_path = "/workspace",
        .providers = &providers,
    } }, sink);
    try runtime.dispatch(.{ .user_turn = .{
        .session_id = "session",
        .source_turn_id = 8,
        .text = "Do the work",
    } }, sink);
    for (0..max_protocol_corrections + 1) |_| {
        const run_id = try std.testing.allocator.dupe(
            u8,
            capture.run_id[0..capture.run_id_len],
        );
        defer std.testing.allocator.free(run_id);
        try runtime.dispatch(.{ .agent_run_started = .{ .run_id = run_id } }, sink);
        try runtime.dispatch(.{ .agent_run_completed = .{
            .run_id = run_id,
            .output = "not coordination JSON",
        } }, sink);
    }
    try std.testing.expect(capture.correction_requested);
    try std.testing.expect(capture.correction_preserved_evidence);
    try std.testing.expect(capture.correction_notice);
    try std.testing.expect(capture.failed_notice);
    try std.testing.expect(capture.rejected_trace);
    try std.testing.expect(capture.turn_failed);
    try std.testing.expectEqual(projection_mod.Status.failed, runtime.session.?.projection.status);
}

test "failed peer consultation returns typed failure evidence to the sole leader" {
    const Capture = struct {
        run_count: usize = 0,
        run_ids: [3][128]u8 = undefined,
        run_id_lens: [3]usize = [_]usize{0} ** 3,
        contexts: [3][2048]u8 = undefined,
        context_lens: [3]usize = [_]usize{0} ** 3,
        warning_seen: bool = false,
        turn_failed: bool = false,
        answer_seen: bool = false,

        fn copyInto(destination: []u8, source: []const u8) usize {
            const len = @min(destination.len, source.len);
            @memcpy(destination[0..len], source[0..len]);
            return len;
        }

        fn emit(context: *anyopaque, intent: test_host.Intent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (intent) {
                .start_agent_run => |request| {
                    const index = self.run_count;
                    if (index >= self.run_ids.len) return error.TooManyRuns;
                    self.run_id_lens[index] = copyInto(&self.run_ids[index], request.run_id);
                    switch (request.visible_input) {
                        .canonical_turn => |input| self.context_lens[index] = copyInto(
                            &self.contexts[index],
                            input.supplemental_context,
                        ),
                        .projected => {},
                    }
                    self.run_count += 1;
                },
                .notice => |notice| self.warning_seen = self.warning_seen or notice.tone == .warning,
                .turn_failed => self.turn_failed = true,
                .publish_answer => self.answer_seen = true,
                .mode_entered, .mode_left, .cancel_agent_run, .trace => {},
            }
        }

        fn runId(self: *@This(), index: usize) []const u8 {
            return self.run_ids[index][0..self.run_id_lens[index]];
        }

        fn visible(self: *@This(), index: usize) []const u8 {
            return self.contexts[index][0..self.context_lens[index]];
        }
    };

    var runtime = Runtime(test_host).init(std.testing.allocator, team_mod.fixture());
    defer runtime.deinit();
    var capture = Capture{};
    const sink = test_host.IntentSink{ .context = &capture, .emit_fn = Capture.emit };
    const providers = [_]test_host.ProviderDescriptor{.{
        .id = "opencode",
        .display_name = "OpenCode",
        .catalog_scope = .unified,
    }};
    try runtime.dispatch(.{ .enter = .{
        .conversation_id = "conversation-peer-failure",
        .workspace_path = "/workspace",
        .providers = &providers,
    } }, sink);
    try runtime.dispatch(.{ .user_turn = .{
        .session_id = "session-peer-failure",
        .source_turn_id = 92,
        .text = "Consult and recover.",
    } }, sink);

    const leader = capture.runId(0);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = leader } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = leader,
        .output = "{\"kind\":\"coordinate\",\"peer_turns\":[{\"key\":\"review\",\"peer_id\":\"researcher\",\"objective\":\"Review the approach.\"}]}",
    } }, sink);
    const peer = capture.runId(1);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = peer } }, sink);
    try runtime.dispatch(.{ .agent_run_failed = .{
        .run_id = peer,
        .message = "peer route unavailable sentinel",
    } }, sink);

    try std.testing.expectEqual(@as(usize, 3), capture.run_count);
    try std.testing.expect(capture.warning_seen);
    try std.testing.expect(!capture.turn_failed);
    try std.testing.expect(std.mem.find(u8, capture.visible(2), "peer route unavailable sentinel") != null);
    try std.testing.expect(std.mem.find(u8, capture.visible(2), "\"status\":\"failed\"") != null);
    try std.testing.expectEqual(projection_mod.Status.running, runtime.session.?.projection.status);

    const resumed = capture.runId(2);
    try runtime.dispatch(.{ .agent_run_started = .{ .run_id = resumed } }, sink);
    try runtime.dispatch(.{ .agent_run_completed = .{
        .run_id = resumed,
        .output = "{\"kind\":\"answer\",\"answer\":\"Recovered answer.\"}",
    } }, sink);
    try std.testing.expect(capture.answer_seen);
    try std.testing.expectEqual(projection_mod.Status.completed, runtime.session.?.projection.status);
}
