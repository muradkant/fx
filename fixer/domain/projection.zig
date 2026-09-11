const std = @import("std");

pub const Status = enum { empty, running, completed, failed, cancelled };

pub const Event = struct {
    sequence: u64,
    data: Data,

    pub const Data = union(enum) {
        session_created: struct {
            session_id: []const u8,
            conversation_id: []const u8,
        },
        team_pinned: struct {
            team_id: []const u8,
            revision: u32,
            digest: []const u8,
        },
        leadership_transferred: struct {
            from_agent_id: []const u8 = "",
            to_agent_id: []const u8,
        },
        agent_turn_started: struct { agent_id: []const u8, turn: u32 },
        agent_turn_completed: struct { agent_id: []const u8, turn: u32 },
        agent_turn_interrupted: struct { agent_id: []const u8, turn: u32 },
        user_instruction_added: struct { source_turn_id: u64 },
        final_completed: struct { agent_id: []const u8 },
        session_failed,
        session_cancelled,
    };
};

/// Projection folds an already-admitted durable event stream. Team policy is
/// decided before events are appended; replay only enforces stream integrity.
pub const Projection = struct {
    last_sequence: u64 = 0,
    session_id: []const u8 = "",
    conversation_id: []const u8 = "",
    pinned_team_id: []const u8 = "",
    pinned_revision: u32 = 0,
    pinned_digest: []const u8 = "",
    leader_id: []const u8 = "",
    active_agent_id: []const u8 = "",
    active_turn: u32 = 0,
    agent_turns: u32 = 0,
    user_instructions: u32 = 0,
    status: Status = .empty,

    pub fn apply(self: *Projection, event: Event) ApplyError!void {
        if (event.sequence != self.last_sequence + 1) return error.NonContiguousSequence;
        if (self.terminal()) return error.SessionAlreadyTerminal;

        switch (event.data) {
            .session_created => |created| {
                if (self.status != .empty) return error.DuplicateSession;
                if (created.session_id.len == 0 or created.conversation_id.len == 0) {
                    return error.EmptySessionIdentity;
                }
                self.session_id = created.session_id;
                self.conversation_id = created.conversation_id;
                self.status = .running;
            },
            .team_pinned => |pinned| {
                try self.requireRunning();
                if (self.pinned_team_id.len != 0) return error.DuplicateTeamPin;
                if (pinned.team_id.len == 0 or pinned.revision == 0 or pinned.digest.len == 0) {
                    return error.InvalidTeamPin;
                }
                self.pinned_team_id = pinned.team_id;
                self.pinned_revision = pinned.revision;
                self.pinned_digest = pinned.digest;
            },
            .leadership_transferred => |transfer| {
                try self.requireReady();
                if (self.active_agent_id.len != 0) return error.AgentTurnActive;
                if (transfer.to_agent_id.len == 0) return error.EmptyLeader;
                if (self.leader_id.len == 0) {
                    if (transfer.from_agent_id.len != 0) return error.LeaderMismatch;
                } else if (!std.mem.eql(u8, transfer.from_agent_id, self.leader_id)) {
                    return error.LeaderMismatch;
                }
                self.leader_id = transfer.to_agent_id;
            },
            .agent_turn_started => |turn| {
                try self.requireReady();
                if (self.leader_id.len == 0) return error.MissingLeader;
                if (self.active_agent_id.len != 0) return error.AgentTurnActive;
                if (!std.mem.eql(u8, turn.agent_id, self.leader_id)) return error.LeaderMismatch;
                if (turn.turn != self.agent_turns + 1) return error.InvalidAgentTurn;
                self.active_agent_id = turn.agent_id;
                self.active_turn = turn.turn;
            },
            .agent_turn_completed => |turn| {
                try self.requireReady();
                if (!std.mem.eql(u8, turn.agent_id, self.active_agent_id) or turn.turn != self.active_turn) {
                    return error.InvalidAgentTurn;
                }
                self.agent_turns = turn.turn;
                self.active_agent_id = "";
                self.active_turn = 0;
            },
            .agent_turn_interrupted => |turn| {
                try self.requireReady();
                if (!std.mem.eql(u8, turn.agent_id, self.active_agent_id) or turn.turn != self.active_turn) {
                    return error.InvalidAgentTurn;
                }
                self.agent_turns = turn.turn;
                self.active_agent_id = "";
                self.active_turn = 0;
            },
            .user_instruction_added => |instruction| {
                try self.requireReady();
                if (instruction.source_turn_id == 0) return error.EmptyInstructionIdentity;
                self.user_instructions += 1;
            },
            .final_completed => |final| {
                try self.requireReady();
                if (self.active_agent_id.len != 0) return error.AgentTurnActive;
                if (!std.mem.eql(u8, final.agent_id, self.leader_id)) return error.LeaderMismatch;
                self.status = .completed;
            },
            .session_failed => {
                try self.requireRunning();
                self.status = .failed;
            },
            .session_cancelled => {
                try self.requireRunning();
                self.status = .cancelled;
            },
        }
        self.last_sequence = event.sequence;
    }

    pub fn terminal(self: Projection) bool {
        return switch (self.status) {
            .completed, .failed, .cancelled => true,
            .empty, .running => false,
        };
    }

    fn requireRunning(self: Projection) ApplyError!void {
        if (self.status != .running) return error.SessionNotRunning;
    }

    fn requireReady(self: Projection) ApplyError!void {
        try self.requireRunning();
        if (self.pinned_team_id.len == 0) return error.TeamNotPinned;
    }
};

pub const ApplyError = error{
    NonContiguousSequence,
    SessionAlreadyTerminal,
    DuplicateSession,
    EmptySessionIdentity,
    SessionNotRunning,
    DuplicateTeamPin,
    InvalidTeamPin,
    TeamNotPinned,
    AgentTurnActive,
    EmptyLeader,
    LeaderMismatch,
    MissingLeader,
    InvalidAgentTurn,
    EmptyInstructionIdentity,
};

fn readyProjection() !Projection {
    var state = Projection{};
    try state.apply(.{ .sequence = 1, .data = .{ .session_created = .{
        .session_id = "turn-1",
        .conversation_id = "conversation",
    } } });
    try state.apply(.{ .sequence = 2, .data = .{ .team_pinned = .{
        .team_id = "coding-team",
        .revision = 1,
        .digest = "digest",
    } } });
    return state;
}

test "fold records admitted leadership and turn events without owning Team policy" {
    var state = try readyProjection();
    try state.apply(.{ .sequence = 3, .data = .{ .leadership_transferred = .{
        .to_agent_id = "coder",
    } } });
    try state.apply(.{ .sequence = 4, .data = .{ .leadership_transferred = .{
        .from_agent_id = "coder",
        .to_agent_id = "researcher",
    } } });
    try state.apply(.{ .sequence = 5, .data = .{ .agent_turn_started = .{
        .agent_id = "researcher",
        .turn = 1,
    } } });
    try state.apply(.{ .sequence = 6, .data = .{ .agent_turn_completed = .{
        .agent_id = "researcher",
        .turn = 1,
    } } });
    try state.apply(.{ .sequence = 7, .data = .{ .final_completed = .{
        .agent_id = "researcher",
    } } });

    try std.testing.expectEqual(Status.completed, state.status);
    try std.testing.expectEqualStrings("researcher", state.leader_id);
}

test "noncontiguous event is rejected without mutating the fold" {
    var state = try readyProjection();
    try std.testing.expectError(error.NonContiguousSequence, state.apply(.{
        .sequence = 4,
        .data = .{ .leadership_transferred = .{ .to_agent_id = "coder" } },
    }));
    try std.testing.expectEqual(@as(u64, 2), state.last_sequence);
    try std.testing.expectEqualStrings("", state.leader_id);
}

test "late completion cannot mutate a terminal stream" {
    var state = try readyProjection();
    try state.apply(.{ .sequence = 3, .data = .session_cancelled });
    try std.testing.expectError(error.SessionAlreadyTerminal, state.apply(.{
        .sequence = 4,
        .data = .{ .leadership_transferred = .{ .to_agent_id = "coder" } },
    }));
    try std.testing.expectEqual(Status.cancelled, state.status);
    try std.testing.expectEqual(@as(u64, 3), state.last_sequence);
}
