const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;
const max_document_bytes: usize = 1024 * 1024;
const max_manifest_bytes: usize = 16 * 1024;
const mutation_lock_deadline_ms: u64 = 2_000;
const lock_file = "library.lock";
const manifest_file = "manifest.json";

pub const Ref = struct {
    id: []const u8,
    revision: u32,
    digest: [64]u8,
};

pub const Definition = struct {
    ref: Ref,
    name: []const u8,
    source: []const u8,
};

pub const Loaded = struct {
    id: []u8,
    revision: u32,
    digest: [64]u8,
    source: []u8,

    pub fn deinit(self: *Loaded, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.source);
        self.* = undefined;
    }
};

pub const Summary = struct {
    id: []u8,
    name: []u8,
    latest_revision: u32,
    latest_digest: [64]u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    deleted: bool,

    pub fn deinit(self: *Summary, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        self.* = undefined;
    }
};

pub const Library = struct {
    items: std.ArrayList(Summary) = .empty,

    pub fn deinit(self: *Library, alloc: Allocator) void {
        for (self.items.items) |*item| item.deinit(alloc);
        self.items.deinit(alloc);
        self.* = undefined;
    }
};

const WireManifest = struct {
    schema: u16,
    id: []const u8,
    name: []const u8,
    latest_revision: u32,
    latest_digest: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    deleted: bool,
};

const OwnedManifest = struct {
    id: []u8,
    name: []u8,
    latest_revision: u32,
    latest_digest: [64]u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    deleted: bool,

    fn deinit(self: *OwnedManifest, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        self.* = undefined;
    }

    fn toSummary(self: OwnedManifest) Summary {
        return .{
            .id = self.id,
            .name = self.name,
            .latest_revision = self.latest_revision,
            .latest_digest = self.latest_digest,
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = self.updated_at_ms,
            .deleted = self.deleted,
        };
    }
};

/// fx-owned durable storage for immutable extension documents. The host knows
/// only identity, revision, digest, and display name; the extension owns the
/// bytes and their schema.
pub const Store = struct {
    root: io_mod.VerifiedDir,

    pub fn initFromHome(
        home_path: []const u8,
        extension_id: []const u8,
        collection_id: []const u8,
    ) !Store {
        try validateIdentifier(extension_id);
        try validateIdentifier(collection_id);

        const zio = io_mod.getIo();
        var home = try std.Io.Dir.openDirAbsolute(zio, home_path, .{ .iterate = true });
        defer home.close(zio);
        var home_verified = io_mod.VerifiedDir{ .dir = home };
        var profile = try io_mod.openOrCreateVerifiedPrivateDir(
            &home_verified,
            profile_paths.root_dir_name,
        );
        defer profile.close();
        var extensions = try io_mod.openOrCreateVerifiedPrivateDir(&profile, "extensions");
        defer extensions.close();
        var extension = try io_mod.openOrCreateVerifiedPrivateDir(&extensions, extension_id);
        defer extension.close();
        return .{ .root = try io_mod.openOrCreateVerifiedPrivateDir(&extension, collection_id) };
    }

    pub fn deinit(self: *Store) void {
        self.root.close();
        self.* = undefined;
    }

    pub fn put(self: *Store, alloc: Allocator, definition: Definition) !void {
        try validateDefinition(definition);
        var lock = try io_mod.acquireTimedAdvisoryLock(
            &self.root,
            lock_file,
            mutation_lock_deadline_ms,
        );
        defer lock.release();

        var identity = try io_mod.openOrCreateVerifiedPrivateDir(
            &self.root,
            definition.ref.id,
        );
        defer identity.close();

        var prior = try readManifestOptional(alloc, &identity);
        defer if (prior) |*manifest| manifest.deinit(alloc);
        const now = io_mod.milliTimestamp();
        const created_at = if (prior) |manifest| manifest.created_at_ms else now;
        if (prior) |manifest| {
            if (manifest.deleted) return error.DefinitionDeleted;
            if (definition.ref.revision == manifest.latest_revision and
                std.mem.eql(u8, &definition.ref.digest, &manifest.latest_digest) and
                std.mem.eql(u8, definition.name, manifest.name))
            {
                const revision_name = try revisionFilename(alloc, definition.ref);
                defer alloc.free(revision_name);
                try installImmutableRevision(alloc, &identity, revision_name, definition.source);
                return;
            }
            if (definition.ref.revision != manifest.latest_revision + 1) {
                return error.NonConsecutiveRevision;
            }
        } else if (definition.ref.revision != 1) {
            return error.NonConsecutiveRevision;
        }

        const revision_name = try revisionFilename(alloc, definition.ref);
        defer alloc.free(revision_name);
        try installImmutableRevision(alloc, &identity, revision_name, definition.source);

        const manifest = OwnedManifest{
            .id = @constCast(definition.ref.id),
            .name = @constCast(definition.name),
            .latest_revision = definition.ref.revision,
            .latest_digest = definition.ref.digest,
            .created_at_ms = created_at,
            .updated_at_ms = now,
            .deleted = false,
        };
        const encoded = try encodeManifest(alloc, manifest);
        defer alloc.free(encoded);
        try io_mod.durableReplaceVerified(alloc, &identity, manifest_file, encoded);
    }

    pub fn delete(self: *Store, alloc: Allocator, id: []const u8) !void {
        try validateIdentifier(id);
        var lock = try io_mod.acquireTimedAdvisoryLock(
            &self.root,
            lock_file,
            mutation_lock_deadline_ms,
        );
        defer lock.release();

        var identity = self.root.dir.openDir(io_mod.getIo(), id, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.DefinitionNotFound,
            error.NotDir, error.SymLinkLoop => return error.DurablePathUnsafe,
            else => return err,
        };
        defer identity.close(io_mod.getIo());
        var verified = io_mod.VerifiedDir{ .dir = identity };
        var manifest = (try readManifestOptional(alloc, &verified)) orelse
            return error.DefinitionNotFound;
        defer manifest.deinit(alloc);
        if (manifest.deleted) return;
        manifest.deleted = true;
        manifest.updated_at_ms = io_mod.milliTimestamp();
        const encoded = try encodeManifest(alloc, manifest);
        defer alloc.free(encoded);
        try io_mod.durableReplaceVerified(alloc, &verified, manifest_file, encoded);
    }

    /// Exact immutable revisions remain loadable after their library identity
    /// is deleted so an fx session can resume with the document it pinned.
    pub fn load(self: *Store, alloc: Allocator, ref: Ref) !Loaded {
        try validateRef(ref);
        var identity = self.root.dir.openDir(io_mod.getIo(), ref.id, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.DefinitionNotFound,
            error.NotDir, error.SymLinkLoop => return error.DurablePathUnsafe,
            else => return err,
        };
        defer identity.close(io_mod.getIo());
        const revision_name = try revisionFilename(alloc, ref);
        defer alloc.free(revision_name);
        const source = try readRegularFile(alloc, identity, revision_name, max_document_bytes);
        errdefer alloc.free(source);
        if (!digestMatches(source, ref.digest)) return error.DocumentDigestMismatch;
        return .{
            .id = try alloc.dupe(u8, ref.id),
            .revision = ref.revision,
            .digest = ref.digest,
            .source = source,
        };
    }

    pub fn list(self: *Store, alloc: Allocator, include_deleted: bool) !Library {
        var library = Library{};
        errdefer library.deinit(alloc);
        var iterator = self.root.dir.iterate();
        while (try iterator.next(io_mod.getIo())) |entry| {
            if (entry.kind != .directory) continue;
            validateIdentifier(entry.name) catch continue;
            var identity = self.root.dir.openDir(io_mod.getIo(), entry.name, .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch continue;
            defer identity.close(io_mod.getIo());
            var verified = io_mod.VerifiedDir{ .dir = identity };
            var manifest = (try readManifestOptional(alloc, &verified)) orelse continue;
            if (manifest.deleted and !include_deleted) {
                manifest.deinit(alloc);
                continue;
            }
            try library.items.append(alloc, manifest.toSummary());
        }
        std.mem.sort(Summary, library.items.items, {}, newerSummaryFirst);
        return library;
    }
};

fn validateDefinition(definition: Definition) !void {
    try validateRef(definition.ref);
    if (definition.name.len == 0 or !std.unicode.utf8ValidateSlice(definition.name)) {
        return error.InvalidDefinitionName;
    }
    if (definition.source.len == 0 or definition.source.len > max_document_bytes) {
        return error.InvalidDocumentSize;
    }
    if (!digestMatches(definition.source, definition.ref.digest)) {
        return error.DocumentDigestMismatch;
    }
}

fn validateRef(ref: Ref) !void {
    try validateIdentifier(ref.id);
    if (ref.revision == 0) return error.InvalidRevision;
    try validateDigest(ref.digest);
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
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) {
            return error.InvalidDigest;
        }
    }
}

fn digestMatches(source: []const u8, expected: [64]u8) bool {
    var bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &bytes, .{});
    return std.mem.eql(u8, &std.fmt.bytesToHex(bytes, .lower), &expected);
}

fn revisionFilename(alloc: Allocator, ref: Ref) ![]u8 {
    return std.fmt.allocPrint(alloc, "{d}-{s}.json", .{ ref.revision, ref.digest });
}

fn installImmutableRevision(
    alloc: Allocator,
    identity: *io_mod.VerifiedDir,
    name: []const u8,
    source: []const u8,
) !void {
    if (readRegularFile(alloc, identity.dir, name, max_document_bytes)) |existing| {
        defer alloc.free(existing);
        if (std.mem.eql(u8, existing, source)) return;
        return error.RevisionConflict;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try io_mod.durableReplaceVerified(alloc, identity, name, source);
}

fn readManifestOptional(alloc: Allocator, identity: *io_mod.VerifiedDir) !?OwnedManifest {
    const bytes = readRegularFile(alloc, identity.dir, manifest_file, max_manifest_bytes) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(WireManifest, alloc, bytes, .{
        .ignore_unknown_fields = false,
    }) catch return error.InvalidManifest;
    defer parsed.deinit();
    const wire = parsed.value;
    if (wire.schema != 1 or wire.latest_revision == 0 or wire.created_at_ms < 0 or
        wire.updated_at_ms < wire.created_at_ms or wire.latest_digest.len != 64)
    {
        return error.InvalidManifest;
    }
    validateIdentifier(wire.id) catch return error.InvalidManifest;
    if (wire.name.len == 0 or !std.unicode.utf8ValidateSlice(wire.name)) return error.InvalidManifest;
    var digest: [64]u8 = undefined;
    @memcpy(&digest, wire.latest_digest);
    validateDigest(digest) catch return error.InvalidManifest;
    return .{
        .id = try alloc.dupe(u8, wire.id),
        .name = try alloc.dupe(u8, wire.name),
        .latest_revision = wire.latest_revision,
        .latest_digest = digest,
        .created_at_ms = wire.created_at_ms,
        .updated_at_ms = wire.updated_at_ms,
        .deleted = wire.deleted,
    };
}

fn encodeManifest(alloc: Allocator, manifest: OwnedManifest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":1,\"id\":");
    try std.json.Stringify.value(manifest.id, .{}, &out.writer);
    try out.writer.writeAll(",\"name\":");
    try std.json.Stringify.value(manifest.name, .{}, &out.writer);
    try out.writer.print(",\"latest_revision\":{d},\"latest_digest\":", .{manifest.latest_revision});
    try std.json.Stringify.value(&manifest.latest_digest, .{}, &out.writer);
    try out.writer.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d},\"deleted\":{s}}}", .{
        manifest.created_at_ms,
        manifest.updated_at_ms,
        if (manifest.deleted) "true" else "false",
    });
    return try out.toOwnedSlice();
}

fn readRegularFile(
    alloc: Allocator,
    dir: std.Io.Dir,
    name: []const u8,
    max_bytes: usize,
) ![]u8 {
    var file = try io_mod.openExistingRegularFile(dir, name, .read_only);
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_bytes);
}

fn newerSummaryFirst(_: void, left: Summary, right: Summary) bool {
    if (left.updated_at_ms != right.updated_at_ms) return left.updated_at_ms > right.updated_at_ms;
    return std.mem.order(u8, left.id, right.id) == .lt;
}

fn digestFor(source: []const u8) [64]u8 {
    var bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &bytes, .{});
    return std.fmt.bytesToHex(bytes, .lower);
}

test "revision store preserves immutable history through edit and delete" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "home", .default_dir);
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);

    var store = try Store.initFromHome(home, "fixer", "teams");
    defer store.deinit();
    const first = "{\"revision\":1}";
    try store.put(alloc, .{
        .ref = .{ .id = "engineering", .revision = 1, .digest = digestFor(first) },
        .name = "Engineering",
        .source = first,
    });
    const second = "{\"revision\":2}";
    try store.put(alloc, .{
        .ref = .{ .id = "engineering", .revision = 2, .digest = digestFor(second) },
        .name = "Engineering revised",
        .source = second,
    });
    // Retrying after a caller lost the success acknowledgement is harmless.
    try store.put(alloc, .{
        .ref = .{ .id = "engineering", .revision = 2, .digest = digestFor(second) },
        .name = "Engineering revised",
        .source = second,
    });

    var library = try store.list(alloc, false);
    defer library.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), library.items.items.len);
    try std.testing.expectEqual(@as(u32, 2), library.items.items[0].latest_revision);
    try std.testing.expectEqualStrings("Engineering revised", library.items.items[0].name);

    const first_ref = Ref{ .id = "engineering", .revision = 1, .digest = digestFor(first) };
    var loaded = try store.load(alloc, first_ref);
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings(first, loaded.source);

    try store.delete(alloc, "engineering");
    var visible = try store.list(alloc, false);
    defer visible.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), visible.items.items.len);

    var retained = try store.load(alloc, first_ref);
    defer retained.deinit(alloc);
    try std.testing.expectEqualStrings(first, retained.source);
}

test "revision store rejects gaps replacement and digest mismatch" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "home", .default_dir);
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(home, "fixer", "teams");
    defer store.deinit();

    const source = "one";
    try std.testing.expectError(error.NonConsecutiveRevision, store.put(alloc, .{
        .ref = .{ .id = "team", .revision = 2, .digest = digestFor(source) },
        .name = "Team",
        .source = source,
    }));
    try std.testing.expectError(error.DocumentDigestMismatch, store.put(alloc, .{
        .ref = .{ .id = "team", .revision = 1, .digest = [_]u8{'0'} ** 64 },
        .name = "Team",
        .source = source,
    }));
}
