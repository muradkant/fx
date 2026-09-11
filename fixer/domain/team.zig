const std = @import("std");

pub const Model = struct {
    id: []const u8,
    route: []const u8,
    name: []const u8,
    reasoning_effort: ?[]const u8 = null,
};

pub const Agent = struct {
    id: []const u8,
    model_id: []const u8,
    definition: []const u8,
    specialists: []const []const u8 = &.{},
};

pub const Specialist = struct {
    id: []const u8,
    model_id: []const u8,
    definition: []const u8,
};

pub const Team = struct {
    schema: u16 = 2,
    id: []const u8,
    revision: u32,
    digest: [64]u8,
    name: []const u8,
    provider_id: []const u8,
    models: []const Model,
    primary: Agent,
    peers: []const Agent = &.{},
    specialists: []const Specialist = &.{},

    pub fn validate(self: Team) ValidationError!void {
        if (self.schema != 2) return error.UnsupportedSchema;
        if (empty(self.id) or empty(self.name) or empty(self.provider_id)) return error.EmptyIdentity;
        if (!equal(self.provider_id, "opencode") and
            !equal(self.provider_id, "vercel") and
            !equal(self.provider_id, "cline"))
        {
            return error.UnsupportedProvider;
        }
        for (self.digest) |byte| {
            if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) {
                return error.InvalidDigest;
            }
        }
        if (!validIdentifier(self.id)) return error.InvalidIdentifier;
        if (self.revision == 0) return error.InvalidRevision;
        if (self.models.len == 0) return error.EmptyModels;
        if (empty(self.primary.id) or empty(self.primary.definition)) return error.EmptyAssignment;

        for (self.models, 0..) |model_entry, index| {
            if (empty(model_entry.id) or empty(model_entry.route) or empty(model_entry.name)) return error.EmptyModel;
            if (!validIdentifier(model_entry.id)) return error.InvalidIdentifier;
            for (self.models[0..index]) |prior| {
                if (equal(model_entry.id, prior.id)) return error.DuplicateModel;
                if (equal(model_entry.route, prior.route) and equal(model_entry.name, prior.name)) {
                    return error.DuplicateCatalogModel;
                }
            }
        }

        try self.validateAgent(self.primary);
        for (self.peers, 0..) |peer, index| {
            if (empty(peer.id) or empty(peer.definition)) return error.EmptyAssignment;
            if (equal(peer.id, self.primary.id)) return error.DuplicateAssignment;
            for (self.peers[0..index]) |prior| {
                if (equal(peer.id, prior.id)) return error.DuplicateAssignment;
            }
            try self.validateAgent(peer);
        }
        for (self.specialists, 0..) |specialist_entry, index| {
            if (empty(specialist_entry.id) or empty(specialist_entry.definition)) return error.EmptyAssignment;
            if (!validIdentifier(specialist_entry.id)) return error.InvalidIdentifier;
            if (self.agent(specialist_entry.id) != null) return error.DuplicateAssignment;
            for (self.specialists[0..index]) |prior| {
                if (equal(specialist_entry.id, prior.id)) return error.DuplicateAssignment;
            }
            if (self.model(specialist_entry.model_id) == null) return error.UnknownModel;
        }
        try self.validateExclusiveModelOwnership();
        try self.validateReachableCollaboration();
    }

    /// Fixer is deliberately not a single-model mode. Peers form one complete
    /// collaboration graph. Every specialist must be assigned to at least one
    /// context-bearing agent, and at least one collaborator must exist.
    fn validateReachableCollaboration(self: Team) ValidationError!void {
        if (self.peers.len == 0 and self.specialists.len == 0) {
            return error.MissingCollaborator;
        }

        for (self.specialists) |candidate| {
            var callable = contains(self.primary.specialists, candidate.id);
            if (!callable) {
                for (self.peers) |peer| {
                    if (contains(peer.specialists, candidate.id)) {
                        callable = true;
                        break;
                    }
                }
            }
            if (!callable) return error.UnreachableSpecialist;
        }
    }

    fn validateExclusiveModelOwnership(self: Team) ValidationError!void {
        const primary_model = self.model(self.primary.model_id) orelse
            return error.UnknownModel;
        for (self.peers) |peer| {
            const peer_model = self.model(peer.model_id) orelse
                return error.UnknownModel;
            if (sameCatalogModel(primary_model, peer_model)) {
                return error.DuplicateModelOwner;
            }
        }
        for (self.specialists) |specialist_entry| {
            const specialist_model = self.model(specialist_entry.model_id) orelse
                return error.UnknownModel;
            if (sameCatalogModel(primary_model, specialist_model)) {
                return error.DuplicateModelOwner;
            }
            for (self.peers) |peer| {
                const peer_model = self.model(peer.model_id) orelse
                    return error.UnknownModel;
                if (sameCatalogModel(peer_model, specialist_model)) {
                    return error.DuplicateModelOwner;
                }
            }
        }
        for (self.peers, 0..) |peer, index| {
            const peer_model = self.model(peer.model_id) orelse
                return error.UnknownModel;
            for (self.peers[0..index]) |prior| {
                const prior_model = self.model(prior.model_id) orelse
                    return error.UnknownModel;
                if (sameCatalogModel(peer_model, prior_model)) {
                    return error.DuplicateModelOwner;
                }
            }
        }
        for (self.specialists, 0..) |specialist_entry, index| {
            const specialist_model = self.model(specialist_entry.model_id) orelse
                return error.UnknownModel;
            for (self.specialists[0..index]) |prior| {
                const prior_model = self.model(prior.model_id) orelse
                    return error.UnknownModel;
                if (sameCatalogModel(specialist_model, prior_model)) {
                    return error.DuplicateModelOwner;
                }
            }
        }
    }

    fn validateAgent(self: Team, assignment: Agent) ValidationError!void {
        if (!validIdentifier(assignment.id)) return error.InvalidIdentifier;
        if (self.model(assignment.model_id) == null) return error.UnknownModel;
        for (assignment.specialists, 0..) |specialist_id, index| {
            if (self.specialist(specialist_id) == null) return error.UnknownSpecialist;
            if (contains(assignment.specialists[0..index], specialist_id)) return error.DuplicateSpecialist;
        }
    }

    pub fn model(self: Team, id: []const u8) ?Model {
        for (self.models) |candidate| {
            if (equal(candidate.id, id)) return candidate;
        }
        return null;
    }

    pub fn agent(self: Team, id: []const u8) ?Agent {
        if (equal(self.primary.id, id)) return self.primary;
        for (self.peers) |candidate| {
            if (equal(candidate.id, id)) return candidate;
        }
        return null;
    }

    pub fn specialist(self: Team, id: []const u8) ?Specialist {
        for (self.specialists) |candidate| {
            if (equal(candidate.id, id)) return candidate;
        }
        return null;
    }

    pub fn arePeers(self: Team, left_id: []const u8, right_id: []const u8) bool {
        if (equal(left_id, right_id)) return false;
        return self.agent(left_id) != null and self.agent(right_id) != null;
    }

    pub fn canUseSpecialist(self: Team, caller_id: []const u8, specialist_id: []const u8) bool {
        const caller = self.agent(caller_id) orelse return false;
        return self.specialist(specialist_id) != null and contains(caller.specialists, specialist_id);
    }
};

pub const ValidationError = error{
    UnsupportedSchema,
    InvalidDigest,
    EmptyIdentity,
    InvalidIdentifier,
    InvalidRevision,
    UnsupportedProvider,
    EmptyModels,
    EmptyModel,
    DuplicateModel,
    DuplicateCatalogModel,
    DuplicateModelOwner,
    EmptyAssignment,
    DuplicateAssignment,
    UnknownModel,
    UnknownSpecialist,
    DuplicateSpecialist,
    MissingCollaborator,
    UnreachableSpecialist,
};

fn empty(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len == 0;
}

fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| {
        if (equal(value, expected)) return true;
    }
    return false;
}

fn sameCatalogModel(left: Model, right: Model) bool {
    return std.ascii.eqlIgnoreCase(
        std.mem.trim(u8, left.route, " \t\r\n"),
        std.mem.trim(u8, right.route, " \t\r\n"),
    ) and equal(
        std.mem.trim(u8, left.name, " \t\r\n"),
        std.mem.trim(u8, right.name, " \t\r\n"),
    );
}

fn validIdentifier(value: []const u8) bool {
    if (value.len == 0 or value[0] < 'a' or value[0] > 'z') return false;
    var previous_hyphen = false;
    for (value) |byte| {
        const alphanumeric = (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9');
        if (alphanumeric) {
            previous_hyphen = false;
            continue;
        }
        if (byte != '-' or previous_hyphen) return false;
        previous_hyphen = true;
    }
    return !previous_hyphen;
}

const fixture_models = [_]Model{
    .{ .id = "coding", .route = "free", .name = "deepseek-code" },
    .{ .id = "research", .route = "free", .name = "research-model" },
    .{ .id = "vision", .route = "free", .name = "vision-model" },
};
const fixture_primary_specialists = [_][]const u8{"vision-reader"};
const fixture_peers = [_]Agent{.{
    .id = "researcher",
    .model_id = "research",
    .definition = "Own evidence audits.",
}};
const fixture_specialists = [_]Specialist{.{
    .id = "vision-reader",
    .model_id = "vision",
    .definition = "Read only explicitly attached images.",
}};

pub fn fixture() Team {
    return .{
        .schema = 2,
        .id = "coding-team",
        .revision = 1,
        .digest = [_]u8{'0'} ** 64,
        .name = "Coding team",
        .provider_id = "opencode",
        .models = &fixture_models,
        .primary = .{
            .id = "coder",
            .model_id = "coding",
            .definition = "Own implementation end to end.",
            .specialists = &fixture_primary_specialists,
        },
        .peers = &fixture_peers,
        .specialists = &fixture_specialists,
    };
}

test "all Team peers are mutually consultable and specialist authority is directed" {
    const value = fixture();
    try value.validate();
    try std.testing.expect(value.arePeers("coder", "researcher"));
    try std.testing.expect(value.arePeers("researcher", "coder"));
    try std.testing.expect(value.canUseSpecialist("coder", "vision-reader"));
    try std.testing.expect(!value.canUseSpecialist("researcher", "vision-reader"));
}

test "Cline is a valid unified Fixer Team provider" {
    var value = fixture();
    value.provider_id = "cline";
    try value.validate();
}

test "different model aliases cannot resolve to one catalog model" {
    const models = [_]Model{
        .{ .id = "one", .route = "free", .name = "same" },
        .{ .id = "two", .route = "free", .name = "same" },
    };
    var value = fixture();
    value.models = &models;
    value.primary.model_id = "one";
    try std.testing.expectError(error.DuplicateCatalogModel, value.validate());
}

test "Team identifiers are lowercase kebab-case" {
    var value = fixture();
    value.primary.id = "Primary Agent";
    try std.testing.expectError(error.InvalidIdentifier, value.validate());
}

test "Fixer refuses a primary-only Team" {
    var value = fixture();
    value.primary.specialists = &.{};
    value.peers = &.{};
    value.specialists = &.{};
    try std.testing.expectError(error.MissingCollaborator, value.validate());
}

test "declared peers require no configurable edges" {
    var value = fixture();
    value.primary.specialists = &.{};
    value.specialists = &.{};
    try value.validate();
    try std.testing.expect(value.arePeers("coder", "researcher"));
}

test "every specialist must be callable by a reachable agent" {
    var value = fixture();
    value.primary.specialists = &.{};
    try std.testing.expectError(error.UnreachableSpecialist, value.validate());
}

test "a specialist callable by a connected peer is usable Team work" {
    const peer_specialists = [_][]const u8{"vision-reader"};
    var peers = [_]Agent{fixture().peers[0]};
    peers[0].specialists = &peer_specialists;
    var value = fixture();
    value.primary.specialists = &.{};
    value.peers = &peers;
    try value.validate();
}
