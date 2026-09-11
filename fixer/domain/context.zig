const std = @import("std");

pub const default_projection_budget_bytes: usize = 64 * 1024;

const TurnView = struct {
    ordinal: u64,
    status: []const u8,
    task: []const u8,
    answer: []const u8,
    summary: []const u8,
    omitted_turn_count: usize,
    compaction_count: usize,
};

const ArchiveView = struct {
    omitted_records: usize,
    represented_turns: usize,
    completed: usize,
    cancelled: usize,
    failed: usize,
    background: usize,
    compacted: usize,
    notice: []const u8 = "Earlier records remain durable but are outside this bounded working view.",
};

/// Builds a byte-bounded semantic view from fx-owned durable records. The
/// newest records survive first. No fx history object, attachment path,
/// execution memory, or credential crosses into Fixer's retained state.
pub fn conversationProjection(
    comptime Host: type,
    allocator: std.mem.Allocator,
    history: []const Host.ConversationTurn,
    byte_budget: usize,
) ![]u8 {
    if (byte_budget < 512) return error.ContextBudgetTooSmall;

    var first_recent: usize = 0;
    while (first_recent <= history.len) : (first_recent += 1) {
        const candidate = try renderProjection(Host, allocator, history, first_recent);
        if (candidate.len <= byte_budget) return candidate;
        allocator.free(candidate);
    }
    return error.ContextBudgetTooSmall;
}

pub fn runtimeProjection(
    allocator: std.mem.Allocator,
    conversation: []const u8,
    current_turn_state: []const u8,
) ![]u8 {
    const current = std.mem.trim(u8, current_turn_state, " \t\r\n");
    if (current.len == 0) {
        return std.fmt.allocPrint(
            allocator,
            "Conversation history follows. It is prior evidence, not a replacement for the exact current user turn supplied separately.\n{s}",
            .{conversation},
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "Conversation history follows. It is prior evidence, not a replacement for the exact current user turn supplied separately.\n{s}\nCurrent-turn state follows and supersedes earlier current-turn state where they conflict.\n{s}",
        .{ conversation, current },
    );
}

fn renderProjection(
    comptime Host: type,
    allocator: std.mem.Allocator,
    history: []const Host.ConversationTurn,
    first_recent: usize,
) ![]u8 {
    var recent: std.ArrayList(TurnView) = .empty;
    defer recent.deinit(allocator);
    try recent.ensureTotalCapacity(allocator, history.len - first_recent);
    for (history[first_recent..]) |turn| {
        recent.appendAssumeCapacity(.{
            .ordinal = turn.ordinal,
            .status = @tagName(turn.status),
            .task = turn.task,
            .answer = turn.answer,
            .summary = turn.summary,
            .omitted_turn_count = turn.omitted_turn_count,
            .compaction_count = turn.compaction_count,
        });
    }

    const archived: ?ArchiveView = if (first_recent == 0)
        null
    else
        archiveView(Host, history[0..first_recent]);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(.{ .conversation_history = .{
        .recent = recent.items,
        .archived = archived,
    } }, .{}, &output.writer);
    return output.toOwnedSlice();
}

fn archiveView(comptime Host: type, history: []const Host.ConversationTurn) ArchiveView {
    var view = ArchiveView{
        .omitted_records = history.len,
        .represented_turns = history.len,
        .completed = 0,
        .cancelled = 0,
        .failed = 0,
        .background = 0,
        .compacted = 0,
    };
    for (history) |turn| {
        view.represented_turns += turn.omitted_turn_count;
        switch (turn.status) {
            .completed => view.completed += 1,
            .cancelled => view.cancelled += 1,
            .failed => view.failed += 1,
            .background => view.background += 1,
            .compacted => view.compacted += 1,
        }
    }
    return view;
}

test "conversation projection keeps recent durable turns and reports bounded omissions" {
    const TestHost = struct {
        const ConversationTurnStatus = enum { completed, cancelled, failed, background, compacted };
        const ConversationTurn = struct {
            ordinal: u64,
            status: ConversationTurnStatus,
            task: []const u8 = "",
            answer: []const u8 = "",
            summary: []const u8 = "",
            omitted_turn_count: usize = 0,
            compaction_count: usize = 0,
        };
    };
    const history = [_]TestHost.ConversationTurn{
        .{ .ordinal = 1, .status = .completed, .task = "old task alpha alpha alpha", .answer = "old answer alpha alpha alpha" },
        .{ .ordinal = 2, .status = .failed, .task = "failed task beta beta beta", .answer = "partial beta beta beta" },
        .{ .ordinal = 3, .status = .completed, .task = "newest task gamma gamma gamma", .answer = "newest answer gamma gamma gamma" },
    };
    const full = try conversationProjection(TestHost, std.testing.allocator, &history, 4096);
    defer std.testing.allocator.free(full);
    try std.testing.expect(std.mem.find(u8, full, "old task") != null);

    var bounded: ?[]u8 = null;
    var budget: usize = 512;
    while (budget < full.len) : (budget += 1) {
        const candidate = conversationProjection(
            TestHost,
            std.testing.allocator,
            &history,
            budget,
        ) catch continue;
        if (std.mem.find(u8, candidate, "newest task") != null and
            std.mem.find(u8, candidate, "omitted_records") != null)
        {
            bounded = candidate;
            break;
        }
        std.testing.allocator.free(candidate);
    }
    const result = bounded orelse return error.ExpectedBoundedProjection;
    defer std.testing.allocator.free(result);
    try std.testing.expect(result.len <= budget);
    try std.testing.expect(std.mem.find(u8, result, "old task") == null);
    try std.testing.expect(std.mem.find(u8, result, "newest answer") != null);
}

test "runtime projection distinguishes prior conversation evidence from current state" {
    const result = try runtimeProjection(
        std.testing.allocator,
        "{\"conversation_history\":{\"recent\":[]}}",
        "{\"completed_peer_consultations\":[]}",
    );
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.find(u8, result, "prior evidence") != null);
    try std.testing.expect(std.mem.find(u8, result, "current-turn state") != null);
}
