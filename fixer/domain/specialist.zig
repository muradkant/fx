const std = @import("std");
const team_mod = @import("team.zig");

const Allocator = std.mem.Allocator;

pub const max_batch_calls: usize = 16;
pub const max_dependency_depth: u8 = 8;

pub const Proposal = struct {
    key: []const u8,
    specialist_id: []const u8,
    objective: []const u8,
    context: []const u8 = "",
    attachments: []const []const u8 = &.{},
    depends_on: []const []const u8 = &.{},
};

pub const Status = enum { pending, requested, running, completed, failed, cancelled };

pub const Result = struct {
    text: []u8,
    findings: [][]u8,
    risks: [][]u8,
    confidence: f64,

    pub fn deinit(self: *Result, allocator: Allocator) void {
        allocator.free(self.text);
        freeStrings(allocator, self.findings);
        freeStrings(allocator, self.risks);
        self.* = undefined;
    }
};

pub const Call = struct {
    id: []u8,
    key: []u8,
    specialist_id: []u8,
    caller_id: []u8,
    objective: []u8,
    context: []u8,
    attachments: [][]u8,
    dependency_ids: [][]u8,
    depth: u8,
    status: Status = .pending,
    attempt: u32 = 0,
    run_id: ?[]u8 = null,
    result: ?Result = null,
    failure: ?[]u8 = null,

    pub fn deinit(self: *Call, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.key);
        allocator.free(self.specialist_id);
        allocator.free(self.caller_id);
        allocator.free(self.objective);
        allocator.free(self.context);
        freeStrings(allocator, self.attachments);
        freeStrings(allocator, self.dependency_ids);
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
    UnauthorizedSpecialist,
    UnknownAttachment,
    UnknownOrLaterDependency,
    DuplicateDependency,
    DependencyDepthExceeded,
};

/// Materializes one leader-authored batch. Dependencies may name only earlier
/// keys in the same batch, which makes cycles structurally impossible and
/// keeps replay deterministic.
pub fn materializeBatch(
    allocator: Allocator,
    team: team_mod.Team,
    caller_id: []const u8,
    session_id: []const u8,
    starting_ordinal: u32,
    proposals: []const Proposal,
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
        const objective = std.mem.trim(u8, proposal.objective, " \t\r\n");
        const context = std.mem.trim(u8, proposal.context, " \t\r\n");
        if (key.len == 0) return error.EmptyKey;
        if (findByKey(calls.items, key) != null) return error.DuplicateKey;
        if (objective.len == 0) return error.EmptyObjective;
        if (!team.canUseSpecialist(caller_id, proposal.specialist_id)) {
            return error.UnauthorizedSpecialist;
        }
        for (proposal.attachments) |reference| {
            if (!contains(allowed_attachments, reference)) return error.UnknownAttachment;
        }

        var dependency_ids: std.ArrayList([]u8) = .empty;
        errdefer {
            for (dependency_ids.items) |id| allocator.free(id);
            dependency_ids.deinit(allocator);
        }
        var depth: u8 = 1;
        for (proposal.depends_on) |dependency_key| {
            const dependency = findByKey(calls.items, dependency_key) orelse
                return error.UnknownOrLaterDependency;
            if (containsOwned(dependency_ids.items, dependency.id)) {
                return error.DuplicateDependency;
            }
            try dependency_ids.append(allocator, try allocator.dupe(u8, dependency.id));
            depth = @max(depth, dependency.depth + 1);
            if (depth > max_dependency_depth) return error.DependencyDepthExceeded;
        }

        const id = try std.fmt.allocPrint(
            allocator,
            "{s}:delegation:{d}",
            .{ session_id, starting_ordinal + @as(u32, @intCast(index)) },
        );
        errdefer allocator.free(id);
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const specialist_id = try allocator.dupe(u8, proposal.specialist_id);
        errdefer allocator.free(specialist_id);
        const owned_caller_id = try allocator.dupe(u8, caller_id);
        errdefer allocator.free(owned_caller_id);
        const owned_objective = try allocator.dupe(u8, objective);
        errdefer allocator.free(owned_objective);
        const owned_context = try allocator.dupe(u8, context);
        errdefer allocator.free(owned_context);
        const attachments = try cloneStrings(allocator, proposal.attachments);
        errdefer freeStrings(allocator, attachments);
        const owned_dependency_ids = try dependency_ids.toOwnedSlice(allocator);
        errdefer freeStrings(allocator, owned_dependency_ids);
        try calls.append(allocator, .{
            .id = id,
            .key = owned_key,
            .specialist_id = specialist_id,
            .caller_id = owned_caller_id,
            .objective = owned_objective,
            .context = owned_context,
            .attachments = attachments,
            .dependency_ids = owned_dependency_ids,
            .depth = depth,
        });
    }
    return calls.toOwnedSlice(allocator);
}

pub fn deinitCalls(allocator: Allocator, calls: []Call) void {
    for (calls) |*call| call.deinit(allocator);
    allocator.free(calls);
}

pub fn ready(call: Call, calls: []const Call) bool {
    if (call.status != .pending) return false;
    for (call.dependency_ids) |dependency_id| {
        const dependency = findById(calls, dependency_id) orelse return false;
        if (dependency.status != .completed) return false;
    }
    return true;
}

pub fn allCompleted(calls: []const Call) bool {
    if (calls.len == 0) return false;
    for (calls) |call| if (call.status != .completed) return false;
    return true;
}

pub fn allSettled(calls: []const Call) bool {
    if (calls.len == 0) return false;
    for (calls) |call| switch (call.status) {
        .completed, .failed, .cancelled => {},
        .pending, .requested, .running => return false,
    };
    return true;
}

pub fn recordFailure(allocator: Allocator, call: *Call, message: []const u8) !void {
    const owned = try allocator.dupe(u8, std.mem.trim(u8, message, " \t\r\n"));
    if (call.failure) |prior| allocator.free(prior);
    call.failure = owned;
    call.status = .failed;
}

/// A dependency that cannot complete makes its pending descendants
/// deterministically unrunnable. Mark the entire blocked chain so the leader
/// receives a settled batch instead of waiting forever.
pub fn settleBlockedDependencies(allocator: Allocator, calls: []Call) !void {
    var changed = true;
    while (changed) {
        changed = false;
        for (calls) |*call| {
            if (call.status != .pending) continue;
            for (call.dependency_ids) |dependency_id| {
                const dependency = findById(calls, dependency_id) orelse continue;
                if (dependency.status != .failed and dependency.status != .cancelled) continue;
                const reason = try std.fmt.allocPrint(
                    allocator,
                    "blocked by unsettled dependency {s}",
                    .{dependency.id},
                );
                if (call.failure) |prior| allocator.free(prior);
                call.failure = reason;
                call.status = .cancelled;
                changed = true;
                break;
            }
        }
    }
}

pub fn projectedContent(allocator: Allocator, call: Call, calls: []const Call) ![]u8 {
    const DependencyView = struct {
        key: []const u8,
        result: []const u8,
        findings: []const []const u8,
        risks: []const []const u8,
        confidence: f64,
    };
    var dependencies: std.ArrayList(DependencyView) = .empty;
    defer dependencies.deinit(allocator);
    for (call.dependency_ids) |dependency_id| {
        const dependency = findById(calls, dependency_id) orelse return error.UnknownDependency;
        const result = dependency.result orelse return error.DependencyIncomplete;
        try dependencies.append(allocator, .{
            .key = dependency.key,
            .result = result.text,
            .findings = result.findings,
            .risks = result.risks,
            .confidence = result.confidence,
        });
    }

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(.{
        .objective = call.objective,
        .context = call.context,
        .completed_dependencies = dependencies.items,
    }, .{}, &output.writer);
    return output.toOwnedSlice();
}

pub fn resultsProjection(allocator: Allocator, calls: []const Call) ![]u8 {
    const View = struct {
        delegation_id: []const u8,
        key: []const u8,
        specialist_id: []const u8,
        result: []const u8,
        findings: []const []const u8,
        risks: []const []const u8,
        confidence: f64,
    };
    var views: std.ArrayList(View) = .empty;
    defer views.deinit(allocator);
    for (calls) |call| {
        const result = call.result orelse return error.SpecialistResultMissing;
        try views.append(allocator, .{
            .delegation_id = call.id,
            .key = call.key,
            .specialist_id = call.specialist_id,
            .result = result.text,
            .findings = result.findings,
            .risks = result.risks,
            .confidence = result.confidence,
        });
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(.{ .completed_specialists = views.items }, .{}, &output.writer);
    return output.toOwnedSlice();
}

pub fn settledProjection(allocator: Allocator, calls: []const Call) ![]u8 {
    const View = struct {
        delegation_id: []const u8,
        key: []const u8,
        specialist_id: []const u8,
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
        const result = call.result;
        try views.append(allocator, .{
            .delegation_id = call.id,
            .key = call.key,
            .specialist_id = call.specialist_id,
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
    try std.json.Stringify.value(.{ .specialist_outcomes = views.items }, .{}, &output.writer);
    return output.toOwnedSlice();
}

pub fn parseResult(allocator: Allocator, raw: []const u8) !Result {
    const Wire = struct {
        result: ?[]const u8 = null,
        findings: ?[]const []const u8 = null,
        risks: ?[]const []const u8 = null,
        confidence: ?f64 = null,
    };
    var parsed = std.json.parseFromSlice(Wire, allocator, raw, .{
        .ignore_unknown_fields = false,
    }) catch return error.InvalidSpecialistResult;
    defer parsed.deinit();
    const text = std.mem.trim(u8, parsed.value.result orelse return error.InvalidSpecialistResult, " \t\r\n");
    const findings = parsed.value.findings orelse return error.InvalidSpecialistResult;
    const risks = parsed.value.risks orelse return error.InvalidSpecialistResult;
    const confidence = parsed.value.confidence orelse return error.InvalidSpecialistResult;
    if (text.len == 0 or !std.math.isFinite(confidence) or confidence < 0 or confidence > 1) {
        return error.InvalidSpecialistResult;
    }
    const owned_text = try allocator.dupe(u8, text);
    errdefer allocator.free(owned_text);
    const owned_findings = try cloneStrings(allocator, findings);
    errdefer freeStrings(allocator, owned_findings);
    return .{
        .text = owned_text,
        .findings = owned_findings,
        .risks = try cloneStrings(allocator, risks),
        .confidence = confidence,
    };
}

fn findByKey(calls: []const Call, key: []const u8) ?*const Call {
    for (calls) |*call| if (std.mem.eql(u8, call.key, key)) return call;
    return null;
}

fn findById(calls: []const Call, id: []const u8) ?*const Call {
    for (calls) |*call| if (std.mem.eql(u8, call.id, id)) return call;
    return null;
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn containsOwned(values: []const []u8, expected: []const u8) bool {
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

test "failed dependency deterministically settles its blocked descendants" {
    const proposals = [_]Proposal{
        .{
            .key = "source",
            .specialist_id = "vision-reader",
            .objective = "Inspect the source evidence.",
        },
        .{
            .key = "dependent",
            .specialist_id = "vision-reader",
            .objective = "Use the source evidence.",
            .depends_on = &.{"source"},
        },
    };
    const calls = try materializeBatch(
        std.testing.allocator,
        team_mod.fixture(),
        "coder",
        "session",
        1,
        &proposals,
        &.{},
    );
    defer deinitCalls(std.testing.allocator, calls);
    try recordFailure(std.testing.allocator, &calls[0], "provider failure sentinel");
    try settleBlockedDependencies(std.testing.allocator, calls);
    try std.testing.expectEqual(Status.failed, calls[0].status);
    try std.testing.expectEqual(Status.cancelled, calls[1].status);
    try std.testing.expect(allSettled(calls));
    const projection = try settledProjection(std.testing.allocator, calls);
    defer std.testing.allocator.free(projection);
    try std.testing.expect(std.mem.find(u8, projection, "provider failure sentinel") != null);
    try std.testing.expect(std.mem.find(u8, projection, "blocked by unsettled dependency") != null);
}

test "batch starts independent specialists and gates later dependencies" {
    const proposals = [_]Proposal{
        .{ .key = "read-a", .specialist_id = "vision-reader", .objective = "Read image A.", .attachments = &.{"image-a"} },
        .{ .key = "read-b", .specialist_id = "vision-reader", .objective = "Read image B.", .attachments = &.{"image-b"} },
        .{ .key = "compare", .specialist_id = "vision-reader", .objective = "Compare the readings.", .depends_on = &.{ "read-a", "read-b" } },
    };
    var calls = try materializeBatch(
        std.testing.allocator,
        team_mod.fixture(),
        "coder",
        "session",
        1,
        &proposals,
        &.{ "image-a", "image-b" },
    );
    defer deinitCalls(std.testing.allocator, calls);
    try std.testing.expect(ready(calls[0], calls));
    try std.testing.expect(ready(calls[1], calls));
    try std.testing.expect(!ready(calls[2], calls));

    calls[0].status = .completed;
    calls[0].result = try parseResult(std.testing.allocator,
        \\{"result":"alpha","findings":[],"risks":[],"confidence":1}
    );
    calls[1].status = .completed;
    calls[1].result = try parseResult(std.testing.allocator,
        \\{"result":"beta","findings":[],"risks":[],"confidence":0.9}
    );
    try std.testing.expect(ready(calls[2], calls));
    const content = try projectedContent(std.testing.allocator, calls[2], calls);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.find(u8, content, "alpha") != null);
    try std.testing.expect(std.mem.find(u8, content, "beta") != null);
}

test "batch rejects authority and attachment escalation" {
    const unauthorized = [_]Proposal{.{
        .key = "inspect",
        .specialist_id = "vision-reader",
        .objective = "Inspect.",
    }};
    try std.testing.expectError(error.UnauthorizedSpecialist, materializeBatch(
        std.testing.allocator,
        team_mod.fixture(),
        "researcher",
        "session",
        1,
        &unauthorized,
        &.{},
    ));

    const unknown_attachment = [_]Proposal{.{
        .key = "inspect",
        .specialist_id = "vision-reader",
        .objective = "Inspect.",
        .attachments = &.{"not-in-the-turn"},
    }};
    try std.testing.expectError(error.UnknownAttachment, materializeBatch(
        std.testing.allocator,
        team_mod.fixture(),
        "coder",
        "session",
        1,
        &unknown_attachment,
        &.{"image-a"},
    ));
}

test "specialist result envelope is strict" {
    try std.testing.expectError(error.InvalidSpecialistResult, parseResult(std.testing.allocator,
        \\{"result":"fallback prose is forbidden","findings":[],"risks":[]}
    ));
    try std.testing.expectError(error.InvalidSpecialistResult, parseResult(std.testing.allocator,
        \\{"result":"x","findings":[],"risks":[],"confidence":2}
    ));
}
