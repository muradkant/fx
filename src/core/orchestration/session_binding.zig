const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
pub const sidecar_file = "orchestration.json";
pub const max_sidecar_bytes: usize = 16 * 1024;

pub const Binding = struct {
    extension_id: []const u8,
    extension_name: []const u8,
    definition_kind: []const u8,
    definition_id: []const u8,
    definition_revision: u32,
    definition_digest: [64]u8,
    display_name: []const u8,
};

pub const OwnedBinding = struct {
    extension_id: []u8,
    extension_name: []u8,
    definition_kind: []u8,
    definition_id: []u8,
    definition_revision: u32,
    definition_digest: [64]u8,
    display_name: []u8,

    pub fn view(self: OwnedBinding) Binding {
        return .{
            .extension_id = self.extension_id,
            .extension_name = self.extension_name,
            .definition_kind = self.definition_kind,
            .definition_id = self.definition_id,
            .definition_revision = self.definition_revision,
            .definition_digest = self.definition_digest,
            .display_name = self.display_name,
        };
    }

    pub fn deinit(self: *OwnedBinding, alloc: Allocator) void {
        alloc.free(self.extension_id);
        alloc.free(self.extension_name);
        alloc.free(self.definition_kind);
        alloc.free(self.definition_id);
        alloc.free(self.display_name);
        self.* = undefined;
    }

    pub fn dupe(self: OwnedBinding, alloc: Allocator) !OwnedBinding {
        const extension_id = try alloc.dupe(u8, self.extension_id);
        errdefer alloc.free(extension_id);
        const extension_name = try alloc.dupe(u8, self.extension_name);
        errdefer alloc.free(extension_name);
        const definition_kind = try alloc.dupe(u8, self.definition_kind);
        errdefer alloc.free(definition_kind);
        const definition_id = try alloc.dupe(u8, self.definition_id);
        errdefer alloc.free(definition_id);
        return .{
            .extension_id = extension_id,
            .extension_name = extension_name,
            .definition_kind = definition_kind,
            .definition_id = definition_id,
            .definition_revision = self.definition_revision,
            .definition_digest = self.definition_digest,
            .display_name = try alloc.dupe(u8, self.display_name),
        };
    }
};

const WireBinding = struct {
    schema: u16,
    extension_id: []const u8,
    extension_name: []const u8,
    definition_kind: []const u8,
    definition_id: []const u8,
    definition_revision: u32,
    definition_digest: []const u8,
    display_name: []const u8,
};

pub fn validate(binding: Binding) !void {
    try validateIdentifier(binding.extension_id);
    try validateIdentifier(binding.definition_kind);
    try validateIdentifier(binding.definition_id);
    if (binding.definition_revision == 0) return error.InvalidRevision;
    try validateDigest(binding.definition_digest);
    if (binding.extension_name.len == 0 or
        !std.unicode.utf8ValidateSlice(binding.extension_name) or
        binding.display_name.len == 0 or
        !std.unicode.utf8ValidateSlice(binding.display_name))
    {
        return error.InvalidDisplayName;
    }
}

pub fn encode(alloc: Allocator, binding: Binding) ![]u8 {
    try validate(binding);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":1,\"extension_id\":");
    try std.json.Stringify.value(binding.extension_id, .{}, &out.writer);
    try out.writer.writeAll(",\"extension_name\":");
    try std.json.Stringify.value(binding.extension_name, .{}, &out.writer);
    try out.writer.writeAll(",\"definition_kind\":");
    try std.json.Stringify.value(binding.definition_kind, .{}, &out.writer);
    try out.writer.writeAll(",\"definition_id\":");
    try std.json.Stringify.value(binding.definition_id, .{}, &out.writer);
    try out.writer.print(",\"definition_revision\":{d},\"definition_digest\":", .{
        binding.definition_revision,
    });
    try std.json.Stringify.value(&binding.definition_digest, .{}, &out.writer);
    try out.writer.writeAll(",\"display_name\":");
    try std.json.Stringify.value(binding.display_name, .{}, &out.writer);
    try out.writer.writeByte('}');
    const encoded = try out.toOwnedSlice();
    if (encoded.len > max_sidecar_bytes) {
        alloc.free(encoded);
        return error.BindingTooLarge;
    }
    return encoded;
}

pub fn decode(alloc: Allocator, bytes: []const u8) !OwnedBinding {
    if (bytes.len == 0 or bytes.len > max_sidecar_bytes) return error.InvalidBinding;
    var parsed = std.json.parseFromSlice(WireBinding, alloc, bytes, .{
        .ignore_unknown_fields = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidBinding,
    };
    defer parsed.deinit();
    const wire = parsed.value;
    if (wire.schema != 1 or wire.definition_digest.len != 64) {
        return error.InvalidBinding;
    }
    var digest: [64]u8 = undefined;
    @memcpy(&digest, wire.definition_digest);
    const borrowed = Binding{
        .extension_id = wire.extension_id,
        .extension_name = wire.extension_name,
        .definition_kind = wire.definition_kind,
        .definition_id = wire.definition_id,
        .definition_revision = wire.definition_revision,
        .definition_digest = digest,
        .display_name = wire.display_name,
    };
    validate(borrowed) catch return error.InvalidBinding;

    const extension_id = try alloc.dupe(u8, wire.extension_id);
    errdefer alloc.free(extension_id);
    const extension_name = try alloc.dupe(u8, wire.extension_name);
    errdefer alloc.free(extension_name);
    const definition_kind = try alloc.dupe(u8, wire.definition_kind);
    errdefer alloc.free(definition_kind);
    const definition_id = try alloc.dupe(u8, wire.definition_id);
    errdefer alloc.free(definition_id);
    const display_name = try alloc.dupe(u8, wire.display_name);
    return .{
        .extension_id = extension_id,
        .extension_name = extension_name,
        .definition_kind = definition_kind,
        .definition_id = definition_id,
        .definition_revision = wire.definition_revision,
        .definition_digest = digest,
        .display_name = display_name,
    };
}

pub fn write(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    binding: Binding,
) !void {
    const bytes = try encode(alloc, binding);
    defer alloc.free(bytes);
    try io_mod.durableReplaceVerified(alloc, session_dir, sidecar_file, bytes);
}

pub fn read(alloc: Allocator, session_dir: *io_mod.VerifiedDir) !?OwnedBinding {
    var file = io_mod.openExistingRegularFile(
        session_dir.dir,
        sidecar_file,
        .read_only,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_sidecar_bytes);
    defer alloc.free(bytes);
    return try decode(alloc, bytes);
}

fn validateIdentifier(value: []const u8) !void {
    if (value.len == 0 or value.len > 96 or value[0] < 'a' or value[0] > 'z') {
        return error.InvalidIdentifier;
    }
    var previous_hyphen = false;
    for (value) |byte| {
        const alphanumeric = std.ascii.isLower(byte) or std.ascii.isDigit(byte);
        if (alphanumeric) {
            previous_hyphen = false;
        } else if (byte == '-' and !previous_hyphen) {
            previous_hyphen = true;
        } else {
            return error.InvalidIdentifier;
        }
    }
    if (previous_hyphen) return error.InvalidIdentifier;
}

fn validateDigest(digest: [64]u8) !void {
    for (digest) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidDigest;
    }
}

test "orchestration session binding round trips exact immutable identity" {
    const alloc = std.testing.allocator;
    const binding = Binding{
        .extension_id = "fixer",
        .extension_name = "Fixer",
        .definition_kind = "team",
        .definition_id = "engineering",
        .definition_revision = 7,
        .definition_digest = [_]u8{'a'} ** 64,
        .display_name = "Engineering",
    };
    const encoded = try encode(alloc, binding);
    defer alloc.free(encoded);
    var decoded = try decode(alloc, encoded);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualStrings("fixer", decoded.extension_id);
    try std.testing.expectEqualStrings("Fixer", decoded.extension_name);
    try std.testing.expectEqualStrings("team", decoded.definition_kind);
    try std.testing.expectEqualStrings("engineering", decoded.definition_id);
    try std.testing.expectEqual(@as(u32, 7), decoded.definition_revision);
    try std.testing.expectEqualSlices(u8, &binding.definition_digest, &decoded.definition_digest);
    try std.testing.expectEqualStrings("Engineering", decoded.display_name);
}

test "orchestration session binding rejects unknown fields" {
    try std.testing.expectError(
        error.InvalidBinding,
        decode(
            std.testing.allocator,
            "{\"schema\":1,\"extension_id\":\"alt\",\"extension_name\":\"Fixer\",\"definition_kind\":\"team\",\"definition_id\":\"one\",\"definition_revision\":1,\"definition_digest\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"display_name\":\"One\",\"surprise\":true}",
        ),
    );
}

test "orchestration session binding persists beside the real session" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var session_dir = io_mod.VerifiedDir{ .dir = try tmp.dir.openDir(
        std.testing.io,
        ".",
        .{ .iterate = true, .follow_symlinks = false },
    ) };
    defer session_dir.close();
    const binding = Binding{
        .extension_id = "fixer",
        .extension_name = "Fixer",
        .definition_kind = "team",
        .definition_id = "engineering",
        .definition_revision = 3,
        .definition_digest = [_]u8{'b'} ** 64,
        .display_name = "Engineering",
    };
    try write(alloc, &session_dir, binding);
    var restored = (try read(alloc, &session_dir)) orelse
        return error.TestExpectedBinding;
    defer restored.deinit(alloc);
    try std.testing.expectEqualStrings("engineering", restored.definition_id);
    try std.testing.expectEqual(@as(u32, 3), restored.definition_revision);
}
