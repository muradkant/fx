const std = @import("std");
const session_usage = @import("../session/session_usage.zig");
const types = @import("../shared/types.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const web_fetch_provider_runtime = @import("web_fetch_provider_runtime.zig");
const web_search_runtime = @import("web_search_runtime.zig");

/// One agent run's credential and routing inputs for web search and fetch.
pub const Config = struct {
    fx_search: bool,
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    gateway_team: ?[]const u8 = null,
    worker_model: []const u8,
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    usage: ?*session_usage.Usage = null,
    usage_allocator: std.mem.Allocator,
    /// Present only when the run may use Parallel as its local backend.
    parallel_api_key: ?[]const u8 = null,
};

/// The runtimes a host owns. A host supplies only the ones it exposes.
pub const Runtimes = struct {
    web_search: ?*web_search_runtime.Runtime = null,
    parallel_web_search: ?*web_search_runtime.Runtime = null,
    web_fetch: ?*web_fetch_provider_runtime.Runtime = null,
    parallel_web_fetch: ?*web_fetch_provider_runtime.Runtime = null,
};

pub const Backends = struct {
    web_search: ?tool_dispatch.WebSearchBackend = null,
    web_fetch: ?tool_dispatch.WebFetchBackend = null,
    web_search_runtime_ready: bool = false,
};

/// Selects and configures the exact backend for one run. Provider-native
/// search wins when the run's provider owns it; otherwise a Parallel
/// connection supplies local search and fetch.
pub fn configure(config: Config, runtimes: Runtimes) Backends {
    var backends: Backends = .{};
    if (config.fx_search) {
        const runtime = runtimes.web_search orelse return backends;
        runtime.configure(.{
            .api_key = config.api_key,
            .credential_source = config.credential_source,
            .gateway_team = config.gateway_team,
            .worker_model = config.worker_model,
            .gateway_retry_count = config.gateway_retry_count,
            .gateway_chat_url = config.gateway_chat_url,
            .usage = config.usage,
            .usage_allocator = config.usage_allocator,
        });
        backends.web_search = runtime.dispatchBackend();
        return backends;
    }
    const parallel_api_key = config.parallel_api_key orelse return backends;
    if (runtimes.parallel_web_fetch) |runtime| {
        runtime.configure(.{
            .api_key = parallel_api_key,
            .worker_model = config.worker_model,
            .usage = config.usage,
            .usage_allocator = config.usage_allocator,
        });
        backends.web_fetch = runtime.dispatchBackend();
    }
    if (runtimes.parallel_web_search) |runtime| {
        runtime.configure(.{
            .api_key = parallel_api_key,
            .worker_model = config.worker_model,
            .gateway_retry_count = 0,
            .gateway_chat_url = "",
            .usage = config.usage,
            .usage_allocator = config.usage_allocator,
        });
        backends.web_search = runtime.dispatchBackend();
        backends.web_search_runtime_ready = true;
    }
    return backends;
}
