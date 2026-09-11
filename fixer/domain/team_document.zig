const std = @import("std");
const team_mod = @import("team.zig");

const WireAgent = struct {
    id: []const u8,
    model_id: []const u8,
    definition: []const u8,
    // Accepted only so sessions pinned to early Fixer revisions remain readable.
    // Peer access is now inherent and this value never enters the domain Team.
    peers: []const []const u8 = &.{},
    specialists: []const []const u8 = &.{},
};

const WireTeam = struct {
    schema: u16,
    id: []const u8,
    revision: u32,
    name: []const u8,
    provider_id: []const u8,
    models: []const team_mod.Model,
    primary: WireAgent,
    peers: []const WireAgent = &.{},
    specialists: []const team_mod.Specialist = &.{},
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(WireTeam),
    domain_peers: []team_mod.Agent,
    value: team_mod.Team,

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Document {
        var parsed = try std.json.parseFromSlice(
            WireTeam,
            allocator,
            source,
            .{ .ignore_unknown_fields = false },
        );
        errdefer parsed.deinit();

        const domain_peers = try allocator.alloc(team_mod.Agent, parsed.value.peers.len);
        errdefer allocator.free(domain_peers);
        for (parsed.value.peers, 0..) |peer, index| {
            domain_peers[index] = domainAgent(peer);
        }

        var digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source, &digest_bytes, .{});
        const digest = std.fmt.bytesToHex(digest_bytes, .lower);
        const wire = parsed.value;
        const value = team_mod.Team{
            .schema = wire.schema,
            .id = wire.id,
            .revision = wire.revision,
            .digest = digest,
            .name = wire.name,
            .provider_id = wire.provider_id,
            .models = wire.models,
            .primary = domainAgent(wire.primary),
            .peers = domain_peers,
            .specialists = wire.specialists,
        };
        try value.validate();
        return .{
            .allocator = allocator,
            .parsed = parsed,
            .domain_peers = domain_peers,
            .value = value,
        };
    }

    pub fn deinit(self: *Document) void {
        self.allocator.free(self.domain_peers);
        self.parsed.deinit();
        self.* = undefined;
    }
};

fn domainAgent(wire: WireAgent) team_mod.Agent {
    return .{
        .id = wire.id,
        .model_id = wire.model_id,
        .definition = wire.definition,
        .specialists = wire.specialists,
    };
}

test "Team parser rejects unknown configuration fields" {
    try std.testing.expectError(
        error.UnknownField,
        Document.parse(
            std.testing.allocator,
            "{\"schema\":2,\"id\":\"x\",\"revision\":1,\"name\":\"X\",\"provider_id\":\"opencode\",\"models\":[],\"primary\":{\"id\":\"x\",\"model_id\":\"x\",\"definition\":\"x\"},\"surprise\":true}",
        ),
    );
}

test "legacy peer edge fields are accepted but discarded" {
    const source =
        "{\"schema\":2,\"id\":\"legacy-team\",\"revision\":1,\"name\":\"Legacy\",\"provider_id\":\"opencode\",\"models\":[" ++
        "{\"id\":\"primary-model\",\"route\":\"zen\",\"name\":\"primary\"},{\"id\":\"peer-model\",\"route\":\"go\",\"name\":\"peer\"}]," ++
        "\"primary\":{\"id\":\"primary\",\"model_id\":\"primary-model\",\"definition\":\"Own.\",\"peers\":[]}," ++
        "\"peers\":[{\"id\":\"peer\",\"model_id\":\"peer-model\",\"definition\":\"Help.\",\"peers\":[]}],\"specialists\":[]}";
    var document = try Document.parse(std.testing.allocator, source);
    defer document.deinit();
    try std.testing.expect(document.value.arePeers("primary", "peer"));
}
