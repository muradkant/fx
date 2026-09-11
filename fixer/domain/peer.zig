const std = @import("std");
const specialist_mod = @import("specialist.zig");
const team_mod = @import("team.zig");

const Allocator = std.mem.Allocator;

pub const max_batch_calls: usize = 16;

pub const Proposal = struct {
    key: []const u8,
    peer_id: []const u8,
    collaboration_id: []const u8 = "",
    objective: []const u8,
    context: []const u8 = "",
    attachments: []const []const u8 = &.{},
};

pub const Status = enum { pending, requested, running, waiting, completed, failed, cancelled };

pub const Call = struct {
    id: []u8,
    key: []u8,
    peer_id: []u8,
    caller_id: []u8,
    collaboration_id: []u8,
    objective: []u8,
    context: []u8,
    attachments: [][]u8,
    round: u32,
    status: Status = .pending,
    attempt: u32 = 0,
    run_id: ?[]u8 = null,
    result: ?specialist_mod.Result = null,
    failure: ?[]u8 = null,

    pub fn deinit(self: *Call, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.key);
        allocator.free(self.peer_id);
        allocator.free(self.caller_id);
        allocator.free(self.collaboration_id);
        allocator.free(self.objective);
        allocator.free(self.context);
        freeStrings(allocator, self.attachments);
        if (self.run_id) |run_id| allocator.free(run_id);
        if (self.result) |*result| result.deinit(allocator);
        if (self.failure) |failure| allocator.free(failure);
        self.* = undefined;
    }
};

pub const PlanError = error{
    EmptyBatch,
    BatchTooLarge,
    EmptyKey,
    DuplicateKey,
    EmptyObjective,
    UnauthorizedPeer,
    UnknownAttachment,
    CollaborationOwnershipMismatch,
    DuplicateActiveCollaboration,
};

const Collaboration = struct {
    caller_id: []const u8,
    peer_id: []const u8,
    last_round: u32,
};

pub fn materializeBatch(
    allocator: Allocator,
    team: team_mod.Team,
    caller_id: []const u8,
    session_id: []const u8,
    starting_ordinal: u32,
    proposals: []const Proposal,
    history: []const Call,
    allowed_attachments: []const []const u8,
) (Allocator.Error || PlanError)![]Call {
    if (proposals.len == 0) return error.EmptyBatch;
    if (proposals.len > max_batch_calls) return error.BatchTooLarge;

    var calls: std.ArrayList(Call) = .empty;
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit(allocator);
    }
    for (proposals, 0..) |proposal, index| {
        const key = std.mem.trim(u8, proposal.key, " \t\r\n");
        const peer_id = std.mem.trim(u8, proposal.peer_id, " \t\r\n");
        const objective = std.mem.trim(u8, proposal.objective, " \t\r\n");
        const context = std.mem.trim(u8, proposal.context, " \t\r\n");
        if (key.len == 0) return error.EmptyKey;
        if (findByKey(calls.items, key) != null) return error.DuplicateKey;
        if (objective.len == 0) return error.EmptyObjective;
        if (!team.arePeers(caller_id, peer_id)) return error.UnauthorizedPeer;
        for (proposal.attachments) |reference| {
            if (!contains(allowed_attachments, reference)) return error.UnknownAttachment;
        }

        const ordinal = starting_ordinal + @as(u32, @intCast(index));
        const requested_collaboration = std.mem.trim(
            u8,
            proposal.collaboration_id,
            " \t\r\n",
        );
        const collaboration = if (requested_collaboration.len == 0)
            try std.fmt.allocPrint(
                allocator,
                "{s}:collaboration:{d}",
                .{ session_id, ordinal },
            )
        else
            try allocator.dupe(u8, requested_collaboration);
        errdefer allocator.free(collaboration);

        var round: u32 = 1;
        if (findCollaboration(history, collaboration)) |known| {
            if (!std.mem.eql(u8, known.caller_id, caller_id) or
                !std.mem.eql(u8, known.peer_id, peer_id))
            {
                return error.CollaborationOwnershipMismatch;
            }
            round = std.math.add(u32, known.last_round, 1) catch
                return error.CollaborationOwnershipMismatch;
        }
        if (findByCollaboration(calls.items, collaboration) != null) {
            return error.DuplicateActiveCollaboration;
        }

        const id = try std.fmt.allocPrint(
            allocator,
            "{s}:peer-turn:{d}",
            .{ session_id, ordinal },
        );
        errdefer allocator.free(id);
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_peer_id = try allocator.dupe(u8, peer_id);
        errdefer allocator.free(owned_peer_id);
        const owned_caller_id = try allocator.dupe(u8, caller_id);
        errdefer allocator.free(owned_caller_id);
        const owned_objective = try allocator.dupe(u8, objective);
        errdefer allocator.free(owned_objective);
        const owned_context = try allocator.dupe(u8, context);
        errdefer allocator.free(owned_context);
        const attachments = try cloneStrings(allocator, proposal.attachments);
        errdefer freeStrings(allocator, attachments);
        try calls.append(allocator, .{
            .id = id,
            .key = owned_key,
            .peer_id = owned_peer_id,
            .caller_id = owned_caller_id,
            .collaboration_id = collaboration,
            .objective = owned_objective,
            .context = owned_context,
            .attachments = attachments,
            .round = round,
        });
    }
    return calls.toOwnedSlice(allocator);
}

pub fn deinitCalls(allocator: Allocator, calls: []Call) void {
    for (calls) |*call| call.deinit(allocator);
    allocator.free(calls);
}

pub fn allCompleted(calls: []const Call) bool {
    if (calls.len == 0) return false;
    for (calls) |call| if (call.status != .completed) return false;
    return true;
}

pub fn ready(index: usize, calls: []const Call) bool {
    if (index >= calls.len or calls[index].status != .pending) return false;
    for (calls, 0..) |other, other_index| {
        if (other_index == index or !std.mem.eql(u8, other.peer_id, calls[index].peer_id)) continue;
        if (other.status == .requested or other.status == .running or other.status == .waiting) return false;
        // Preserve the model-authored order for multiple consultations to the
        // same context-bearing peer while unrelated peers remain parallel.
        if (other_index < index and other.status == .pending) return false;
    }
    return true;
}

pub fn allSettled(calls: []const Call) bool {
    if (calls.len == 0) return false;
    for (calls) |call| switch (call.status) {
        .completed, .failed, .cancelled => {},
        .pending, .requested, .running, .waiting => return false,
    };
    return true;
}

pub fn recordFailure(allocator: Allocator, call: *Call, message: []const u8) !void {
    const owned = try allocator.dupe(u8, std.mem.trim(u8, message, " \t\r\n"));
    if (call.failure) |prior| allocator.free(prior);
    call.failure = owned;
    call.status = .failed;
}

pub fn consultationProjection(
    allocator: Allocator,
    call: Call,
    history: []const Call,
    team_evidence: []const u8,
) ![]u8 {
    const PriorRound = struct {
        round: u32,
        objective: []const u8,
        result: []const u8,
        findings: []const []const u8,
        risks: []const []const u8,
        confidence: f64,
    };
    var prior: std.ArrayList(PriorRound) = .empty;
    defer prior.deinit(allocator);
    for (history) |earlier| {
        if (!std.mem.eql(u8, earlier.collaboration_id, call.collaboration_id) or
            earlier.status != .completed)
        {
            continue;
        }
        const result = earlier.result orelse continue;
        try prior.append(allocator, .{
            .round = earlier.round,
            .objective = earlier.objective,
            .result = result.text,
            .findings = result.findings,
            .risks = result.risks,
            .confidence = result.confidence,
        });
    }

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(.{
        .invocation_mode = "peer_consultation",
        .holds_leadership = false,
        .caller = call.caller_id,
        .collaboration_id = call.collaboration_id,
        .prior_rounds = prior.items,
        .current_round = call.round,
        .objective = call.objective,
        .context = call.context,
        .team_evidence = team_evidence,
    }, .{}, &output.writer);
    return output.toOwnedSlice();
}

pub fn resultsProjection(allocator: Allocator, calls: []const Call) ![]u8 {
    const View = struct {
        peer_turn_id: []const u8,
        key: []const u8,
        peer_id: []const u8,
        collaboration_id: []const u8,
        round: u32,
        result: []const u8,
        findings: []const []const u8,
        risks: []const []const u8,
        confidence: f64,
    };
    var views: std.ArrayList(View) = .empty;
    defer views.deinit(allocator);
    for (calls) |call| {
        const result = call.result orelse return error.PeerResultMissing;
        try views.append(allocator, .{
            .peer_turn_id = call.id,
            .key = call.key,
            .peer_id = call.peer_id,
            .collaboration_id = call.collaboration_id,
            .round = call.round,
            .result = result.text,
            .findings = result.findings,
            .risks = result.risks,
            .confidence = result.confidence,
        });
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(.{ .completed_peer_consultations = views.items }, .{}, &output.writer);
    return output.toOwnedSlice();
}

pub fn settledProjection(allocator: Allocator, calls: []const Call) ![]u8 {
    return settledProjectionForCaller(allocator, calls, null);
}

/// Projects only direct returns owned by one caller when `caller_id` is set.
/// Nested consultation evidence must unwind through its immediate parent
/// instead of leaking raw descendant results into unrelated model views.
pub fn settledProjectionForCaller(
    allocator: Allocator,
    calls: []const Call,
    caller_id: ?[]const u8,
) ![]u8 {
    const View = struct {
        peer_turn_id: []const u8,
        key: []const u8,
        peer_id: []const u8,
        collaboration_id: []const u8,
        round: u32,
        status: []const u8,
        result: ?[]const u8 = null,
        findings: []const []const u8 = &.{},
        risks: []const []const u8 = &.{},
        confidence: ?f64 = null,
        error_message: ?[]const u8 = null,
    };
    var views: std.ArrayList(View) = .empty;
    defer views.deinit(allocator);
    for (calls) |call| {
        if (caller_id) |expected| {
            if (!std.mem.eql(u8, call.caller_id, expected)) continue;
        }
        const result = call.result;
        try views.append(allocator, .{
            .peer_turn_id = call.id,
            .key = call.key,
            .peer_id = call.peer_id,
            .collaboration_id = call.collaboration_id,
            .round = call.round,
            .status = @tagName(call.status),
            .result = if (result) |value| value.text else null,
            .findings = if (result) |value| value.findings else &.{},
            .risks = if (result) |value| value.risks else &.{},
            .confidence = if (result) |value| value.confidence else null,
            .error_message = call.failure,
        });
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(.{ .peer_consultation_outcomes = views.items }, .{}, &output.writer);
    return output.toOwnedSlice();
}

fn findByKey(calls: []const Call, key: []const u8) ?*const Call {
    for (calls) |*call| if (std.mem.eql(u8, call.key, key)) return call;
    return null;
}

fn findByCollaboration(calls: []const Call, id: []const u8) ?*const Call {
    for (calls) |*call| if (std.mem.eql(u8, call.collaboration_id, id)) return call;
    return null;
}

fn findCollaboration(history: []const Call, id: []const u8) ?Collaboration {
    var found: ?Collaboration = null;
    for (history) |call| {
        if (!std.mem.eql(u8, call.collaboration_id, id)) continue;
        if (found == null) {
            found = .{
                .caller_id = call.caller_id,
                .peer_id = call.peer_id,
                .last_round = call.round,
            };
        } else if (call.round > found.?.last_round) {
            found.?.last_round = call.round;
        }
    }
    return found;
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn cloneStrings(allocator: Allocator, values: []const []const u8) ![][]u8 {
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

fn freeStrings(allocator: Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "peer consultation retains leadership ownership and continues by collaboration" {
    const first_proposal = [_]Proposal{.{
        .key = "review",
        .peer_id = "researcher",
        .objective = "Review the bounded implementation.",
    }};
    var first = try materializeBatch(
        std.testing.allocator,
        team_mod.fixture(),
        "coder",
        "session",
        1,
        &first_proposal,
        &.{},
        &.{},
    );
    defer deinitCalls(std.testing.allocator, first);
    first[0].status = .completed;
    first[0].result = try specialist_mod.parseResult(std.testing.allocator,
        \\{"result":"bounded review","findings":["f"],"risks":[],"confidence":0.8}
    );

    const second_proposal = [_]Proposal{.{
        .key = "review-again",
        .peer_id = "researcher",
        .collaboration_id = first[0].collaboration_id,
        .objective = "Recheck after the change.",
    }};
    const second = try materializeBatch(
        std.testing.allocator,
        team_mod.fixture(),
        "coder",
        "session",
        2,
        &second_proposal,
        first,
        &.{},
    );
    defer deinitCalls(std.testing.allocator, second);
    try std.testing.expectEqual(@as(u32, 2), second[0].round);
    const view = try consultationProjection(
        std.testing.allocator,
        second[0],
        first,
        "durable evidence",
    );
    defer std.testing.allocator.free(view);
    try std.testing.expect(std.mem.find(u8, view, "bounded review") != null);
    try std.testing.expect(std.mem.find(u8, view, "\"holds_leadership\":false") != null);
}

test "same-peer consultations serialize while preserving declared order" {
    const proposals = [_]Proposal{
        .{ .key = "first", .peer_id = "researcher", .objective = "First review." },
        .{ .key = "second", .peer_id = "researcher", .objective = "Second review." },
    };
    const calls = try materializeBatch(
        std.testing.allocator,
        team_mod.fixture(),
        "coder",
        "session",
        1,
        &proposals,
        &.{},
        &.{},
    );
    defer deinitCalls(std.testing.allocator, calls);
    try std.testing.expect(ready(0, calls));
    try std.testing.expect(!ready(1, calls));
    calls[0].status = .running;
    try std.testing.expect(!ready(1, calls));
    calls[0].status = .completed;
    try std.testing.expect(ready(1, calls));
}

test "peer consultation rejects invented relationships and attachment escalation" {
    const invented = [_]Proposal{.{
        .key = "review",
        .peer_id = "vision-reader",
        .objective = "Review.",
    }};
    try std.testing.expectError(error.UnauthorizedPeer, materializeBatch(
        std.testing.allocator,
        team_mod.fixture(),
        "coder",
        "session",
        1,
        &invented,
        &.{},
        &.{},
    ));
    const escalated = [_]Proposal{.{
        .key = "review",
        .peer_id = "researcher",
        .objective = "Review.",
        .attachments = &.{"image:missing"},
    }};
    try std.testing.expectError(error.UnknownAttachment, materializeBatch(
        std.testing.allocator,
        team_mod.fixture(),
        "coder",
        "session",
        1,
        &escalated,
        &.{},
        &.{},
    ));
}
