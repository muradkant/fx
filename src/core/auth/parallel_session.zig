const std = @import("std");
const api_key_session = @import("api_key_session.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const spec = api_key_session.StoreSpec{
    .auth_file_name = profile_paths.parallel_auth_file_name,
    .mutation_lock_file_name = "parallel-auth.lock",
    .provider_name = "Parallel",
};

pub const Session = api_key_session.Session;
pub const DeleteOutcome = api_key_session.DeleteOutcome;
pub const validApiKey = api_key_session.validApiKey;

/// Loads the environment connection first, then the private profile file.
/// Environment-provided secrets are borrowed only long enough to duplicate
/// them and are never persisted implicitly.
pub fn loadConfigured(alloc: std.mem.Allocator) !?Session {
    if (io_mod.getenv("PARALLEL_API_KEY")) |api_key| {
        if (!validApiKey(api_key)) return error.InvalidParallelApiKey;
        return .{ .api_key = try alloc.dupe(u8, api_key) };
    }
    return load(alloc);
}

pub fn load(alloc: std.mem.Allocator) !?Session {
    return api_key_session.load(alloc, spec);
}

pub fn saveNewSession(alloc: std.mem.Allocator, session: Session) !void {
    return api_key_session.saveNewSession(alloc, session, spec);
}

pub fn logout() !DeleteOutcome {
    return api_key_session.logout(spec);
}
