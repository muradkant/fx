const std = @import("std");
const projection_mod = @import("projection.zig");
const team_mod = @import("team.zig");

pub const Error = error{
    SessionNotReady,
    TeamPinMismatch,
    AgentTurnActive,
    LeadershipAlreadyAssigned,
    MissingLeader,
    UnknownLeader,
    InvalidHandoff,
};

pub fn primaryIngress(team: team_mod.Team, state: projection_mod.Projection) Error!projection_mod.Event.Data {
    try requirePinnedTeam(team, state);
    if (state.active_agent_id.len != 0) return error.AgentTurnActive;
    if (state.leader_id.len != 0) return error.LeadershipAlreadyAssigned;
    return .{ .leadership_transferred = .{ .to_agent_id = team.primary.id } };
}

pub fn handoff(
    team: team_mod.Team,
    state: projection_mod.Projection,
    to_agent_id: []const u8,
) Error!projection_mod.Event.Data {
    try requirePinnedTeam(team, state);
    if (state.active_agent_id.len != 0) return error.AgentTurnActive;
    if (state.leader_id.len == 0) return error.MissingLeader;
    const target = team.agent(to_agent_id) orelse return error.UnknownLeader;
    if (!team.arePeers(state.leader_id, to_agent_id)) return error.InvalidHandoff;
    return .{
        .leadership_transferred = .{
            .from_agent_id = state.leader_id,
            // Store the immutable Team-owned identity, never model-output bytes.
            .to_agent_id = target.id,
        },
    };
}

fn requirePinnedTeam(team: team_mod.Team, state: projection_mod.Projection) Error!void {
    if (state.status != .running or state.pinned_team_id.len == 0) return error.SessionNotReady;
    if (!std.mem.eql(u8, state.pinned_team_id, team.id) or state.pinned_revision != team.revision) {
        return error.TeamPinMismatch;
    }
}

fn pinnedState(team: team_mod.Team) !projection_mod.Projection {
    var state = projection_mod.Projection{};
    try state.apply(.{ .sequence = 1, .data = .{ .session_created = .{
        .session_id = "turn-1",
        .conversation_id = "conversation",
    } } });
    try state.apply(.{ .sequence = 2, .data = .{ .team_pinned = .{
        .team_id = team.id,
        .revision = team.revision,
        .digest = "digest",
    } } });
    return state;
}

test "admission owns primary ingress and peer handoff policy" {
    const team = team_mod.fixture();
    var state = try pinnedState(team);
    const ingress = try primaryIngress(team, state);
    try state.apply(.{ .sequence = 3, .data = ingress });

    try std.testing.expectError(error.UnknownLeader, handoff(team, state, "missing"));
    const transfer = try handoff(team, state, "researcher");
    try state.apply(.{ .sequence = 4, .data = transfer });
    try std.testing.expectEqualStrings("researcher", state.leader_id);
}

test "admission rejects a Team revision different from the pinned session" {
    var team = team_mod.fixture();
    const state = try pinnedState(team);
    team.revision += 1;
    try std.testing.expectError(error.TeamPinMismatch, primaryIngress(team, state));
}
