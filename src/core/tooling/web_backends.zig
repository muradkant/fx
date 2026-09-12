const std = @import("std");
const session_usage = @import("../session/session_usage.zig");
const types = @import("../shared/types.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const web_fetch_provider_runtime = @import("web_fetch_provider_runtime.zig");
const web_search_contract = @import("web_search_contract.zig");
const web_search_policy = @import("web_search_policy.zig");
const web_search_provider = @import("web_search_provider.zig");
const web_search_runtime = @import("web_search_runtime.zig");

const Allocator = std.mem.Allocator;

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

/// Run-owned web runtimes with stable input storage. `configure` is only
/// safe for callers that never overlap: it overwrites borrowed input slices
/// on shared runtimes, so a concurrent run would steal another run's
/// credentials and a reaped run would leave dangling borrows behind.
/// `configureOwned` gives each concurrent run private runtimes plus owned
/// copies of its inputs; `backends` stays valid until `deinit`.
pub const Owned = struct {
    search_runtime: web_search_runtime.Runtime,
    parallel_search_runtime: web_search_runtime.Runtime,
    parallel_fetch_runtime: web_fetch_provider_runtime.Runtime,
    backends: Backends = .{},
    api_key: []u8 = &.{},
    gateway_team: ?[]u8 = null,
    worker_model: []u8 = &.{},
    gateway_chat_url: []u8 = &.{},
    parallel_api_key: ?[]u8 = null,

    pub fn deinit(self: *Owned, alloc: Allocator) void {
        alloc.free(self.api_key);
        if (self.gateway_team) |team| alloc.free(team);
        alloc.free(self.worker_model);
        alloc.free(self.gateway_chat_url);
        if (self.parallel_api_key) |key| alloc.free(key);
        self.* = undefined;
    }
};

fn searchFromTemplate(template: ?*web_search_runtime.Runtime) web_search_runtime.Runtime {
    const runtime = template orelse return web_search_runtime.Runtime.init(.{});
    return web_search_runtime.Runtime.init(.{
        .provider = runtime.provider,
        .clock = runtime.clock,
        .policy = runtime.policy,
    });
}

fn fetchFromTemplate(template: ?*web_fetch_provider_runtime.Runtime) web_fetch_provider_runtime.Runtime {
    const runtime = template orelse return web_fetch_provider_runtime.Runtime.init(.{});
    return web_fetch_provider_runtime.Runtime.init(.{
        .provider = runtime.provider,
    });
}

/// Which backends the wiring activates for one config. Computed once so
/// `configure` and `configureOwned` cannot disagree on selection.
const Selection = struct {
    fx_search: bool = false,
    parallel_fetch: bool = false,
    parallel_search: bool = false,
};

fn selectBackends(config: Config, runtimes: Runtimes) Selection {
    if (config.fx_search) {
        return .{ .fx_search = runtimes.web_search != null };
    }
    if (config.parallel_api_key == null) return .{};
    return .{
        .parallel_fetch = runtimes.parallel_web_fetch != null,
        .parallel_search = runtimes.parallel_web_search != null,
    };
}

fn wireBackends(config: Config, runtimes: Runtimes, selection: Selection) Backends {
    var backends: Backends = .{};
    if (selection.fx_search) {
        const runtime = runtimes.web_search.?;
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
    }
    if (selection.parallel_fetch) {
        const runtime = runtimes.parallel_web_fetch.?;
        const parallel_api_key = config.parallel_api_key.?;
        runtime.configure(.{
            .api_key = parallel_api_key,
            .worker_model = config.worker_model,
            .usage = config.usage,
            .usage_allocator = config.usage_allocator,
        });
        backends.web_fetch = runtime.dispatchBackend();
    }
    if (selection.parallel_search) {
        const runtime = runtimes.parallel_web_search.?;
        const parallel_api_key = config.parallel_api_key.?;
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

/// Selects and configures the exact backend for one run, returning
/// run-owned runtimes. Provider-native search wins when the run's provider
/// owns it; otherwise a Parallel connection supplies local search and
/// fetch. The template runtimes are only read for their provider, clock,
/// and policy; they are never configured, so concurrent runs cannot
/// disturb each other or the host.
pub fn configureOwned(
    alloc: Allocator,
    config: Config,
    templates: Runtimes,
) !*Owned {
    const owned = try alloc.create(Owned);
    errdefer alloc.destroy(owned);
    owned.* = .{
        .search_runtime = searchFromTemplate(templates.web_search),
        .parallel_search_runtime = searchFromTemplate(templates.parallel_web_search),
        .parallel_fetch_runtime = fetchFromTemplate(templates.parallel_web_fetch),
    };
    errdefer owned.deinit(alloc);
    // Own every input the wiring may borrow, so the selected backends
    // never alias the caller's storage. Selection still follows the host
    // templates: runtimes without a template behind them stay inactive.
    owned.api_key = try alloc.dupe(u8, config.api_key);
    if (config.gateway_team) |team| {
        owned.gateway_team = try alloc.dupe(u8, team);
    }
    owned.worker_model = try alloc.dupe(u8, config.worker_model);
    owned.gateway_chat_url = try alloc.dupe(u8, config.gateway_chat_url);
    if (config.parallel_api_key) |key| {
        owned.parallel_api_key = try alloc.dupe(u8, key);
    }
    var owned_config = config;
    owned_config.api_key = owned.api_key;
    owned_config.gateway_team = owned.gateway_team;
    owned_config.worker_model = owned.worker_model;
    owned_config.gateway_chat_url = owned.gateway_chat_url;
    owned_config.parallel_api_key = owned.parallel_api_key;
    const owned_runtimes: Runtimes = .{
        .web_search = &owned.search_runtime,
        .parallel_web_search = &owned.parallel_search_runtime,
        .parallel_web_fetch = &owned.parallel_fetch_runtime,
    };
    owned.backends = wireBackends(
        owned_config,
        owned_runtimes,
        selectBackends(config, templates),
    );
    return owned;
}

/// Selects and configures the exact backend for one run. Provider-native
/// search wins when the run's provider owns it; otherwise a Parallel
/// connection supplies local search and fetch.
///
/// The runtimes are configured in place with borrowed inputs. Only callers
/// that never overlap may share runtimes through this function; concurrent
/// runs must use `configureOwned` so each run keeps stable backend inputs.
pub fn configure(config: Config, runtimes: Runtimes) Backends {
    return wireBackends(config, runtimes, selectBackends(config, runtimes));
}

test "owned web backends keep concurrent run inputs isolated" {
    const alloc = std.testing.allocator;
    var search_template = web_search_runtime.Runtime.init(.{});
    var parallel_search_template = web_search_runtime.Runtime.init(.{});
    var parallel_fetch_template = web_fetch_provider_runtime.Runtime.init(.{});
    const templates: Runtimes = .{
        .web_search = &search_template,
        .parallel_web_search = &parallel_search_template,
        .parallel_web_fetch = &parallel_fetch_template,
    };
    const first = try configureOwned(alloc, .{
        .fx_search = true,
        .api_key = "key-a",
        .gateway_team = "team-a",
        .worker_model = "model-a",
        .gateway_retry_count = 1,
        .gateway_chat_url = "https://a.invalid/chat",
        .usage_allocator = alloc,
    }, templates);
    defer {
        first.deinit(alloc);
        alloc.destroy(first);
    }
    const second = try configureOwned(alloc, .{
        .fx_search = true,
        .api_key = "key-b",
        .worker_model = "model-b",
        .gateway_retry_count = 2,
        .gateway_chat_url = "https://b.invalid/chat",
        .usage_allocator = alloc,
    }, templates);
    defer {
        second.deinit(alloc);
        alloc.destroy(second);
    }
    // Admitting the second run must not disturb the first run's inputs.
    try std.testing.expectEqualStrings("key-a", first.search_runtime.api_key);
    try std.testing.expectEqualStrings("team-a", first.search_runtime.gateway_team.?);
    try std.testing.expectEqualStrings("model-a", first.search_runtime.worker_model);
    try std.testing.expectEqualStrings("key-b", second.search_runtime.api_key);
    try std.testing.expect(second.backends.web_search != null);
    try std.testing.expect(first.backends.web_search.?.ctx != second.backends.web_search.?.ctx);
    try std.testing.expect(!first.backends.web_search_runtime_ready);
    // Owned admission never configures the shared host runtimes.
    try std.testing.expectEqualStrings("", search_template.api_key);
    try std.testing.expectEqualStrings("", search_template.worker_model);
}

test "surviving run executes with owned inputs after temps are released" {
    const RecordingProvider = struct {
        expected_api_key: []const u8 = "",
        matched: bool = false,
        calls: usize = 0,

        const backend_id = web_search_contract.SearchBackendId{ .value = "test.recording" };
        const backend_order = [_]web_search_contract.SearchBackendId{backend_id};
        const backend_policies = [_]web_search_policy.BackendPolicy{.{
            .id = backend_id,
            .features = .{
                .max_uses = .best_effort,
                .allowed_domains = .pass_through,
                .blocked_domains = .pass_through,
                .ordered_sources = true,
                .usage = true,
                .terminal_incomplete = true,
                .timeout = true,
                .cancellation = true,
                .result_bounds = .post_filter,
            },
        }};

        fn provider(self: *@This()) web_search_provider.Provider {
            return .{
                .context = @ptrCast(self),
                .policy = .{
                    .preferred_backends = &backend_order,
                    .backend_policies = &backend_policies,
                },
                .preferred_backends_fn = preferredBackends,
                .execute_fn = executeProvider,
            };
        }

        fn preferredBackends(_: ?*anyopaque) !?[]const web_search_contract.SearchBackendId {
            return &backend_order;
        }

        fn executeProvider(
            raw_ctx: ?*anyopaque,
            _: Allocator,
            inputs: web_search_provider.Inputs,
            _: web_search_contract.ProviderRequest,
            _: ?web_search_contract.ProgressFn,
            _: ?*anyopaque,
        ) !web_search_contract.ProviderResponse {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            self.calls += 1;
            self.matched = std.mem.eql(u8, inputs.api_key, self.expected_api_key);
            return .{};
        }
    };

    const alloc = std.testing.allocator;
    // Temporary caller-owned inputs, released before the surviving run
    // executes. A backend that borrows instead of owning would read freed
    // memory or a sibling run's inputs here.
    const temp_key = try alloc.dupe(u8, "survivor-key");
    const temp_key_ptr = temp_key.ptr;
    const temp_model = try alloc.dupe(u8, "survivor-model");
    const temp_url = try alloc.dupe(u8, "https://survivor.invalid/chat");
    var recorder = RecordingProvider{ .expected_api_key = "survivor-key" };
    var search_template = web_search_runtime.Runtime.init(.{ .provider = recorder.provider() });
    var parallel_search_template = web_search_runtime.Runtime.init(.{});
    var parallel_fetch_template = web_fetch_provider_runtime.Runtime.init(.{});
    const templates: Runtimes = .{
        .web_search = &search_template,
        .parallel_web_search = &parallel_search_template,
        .parallel_web_fetch = &parallel_fetch_template,
    };
    const survivor = try configureOwned(alloc, .{
        .fx_search = true,
        .api_key = temp_key,
        .worker_model = temp_model,
        .gateway_retry_count = 1,
        .gateway_chat_url = temp_url,
        .usage_allocator = alloc,
    }, templates);
    defer {
        survivor.deinit(alloc);
        alloc.destroy(survivor);
    }
    const other = try configureOwned(alloc, .{
        .fx_search = true,
        .api_key = "other-key",
        .worker_model = "other-model",
        .gateway_retry_count = 1,
        .gateway_chat_url = "https://other.invalid/chat",
        .usage_allocator = alloc,
    }, templates);
    alloc.free(temp_key);
    alloc.free(temp_model);
    alloc.free(temp_url);
    other.deinit(alloc);
    alloc.destroy(other);
    try std.testing.expect(survivor.search_runtime.api_key.ptr != temp_key_ptr);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var output = try survivor.search_runtime.execute(alloc, .{ .query = "lifetime probe" }, &cancel_flag);
    defer output.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expect(recorder.matched);
}

test "owned web backends isolate the parallel branch" {
    const alloc = std.testing.allocator;
    var search_template = web_search_runtime.Runtime.init(.{});
    var parallel_search_template = web_search_runtime.Runtime.init(.{});
    var parallel_fetch_template = web_fetch_provider_runtime.Runtime.init(.{});
    const templates: Runtimes = .{
        .web_search = &search_template,
        .parallel_web_search = &parallel_search_template,
        .parallel_web_fetch = &parallel_fetch_template,
    };
    const first = try configureOwned(alloc, .{
        .fx_search = false,
        .api_key = "unused",
        .worker_model = "model-a",
        .gateway_retry_count = 0,
        .gateway_chat_url = "",
        .usage_allocator = alloc,
        .parallel_api_key = "parallel-a",
    }, templates);
    defer {
        first.deinit(alloc);
        alloc.destroy(first);
    }
    const second = try configureOwned(alloc, .{
        .fx_search = false,
        .api_key = "unused",
        .worker_model = "model-b",
        .gateway_retry_count = 0,
        .gateway_chat_url = "",
        .usage_allocator = alloc,
        .parallel_api_key = "parallel-b",
    }, templates);
    defer {
        second.deinit(alloc);
        alloc.destroy(second);
    }
    try std.testing.expectEqualStrings("parallel-a", first.parallel_search_runtime.api_key);
    try std.testing.expectEqualStrings("parallel-a", first.parallel_fetch_runtime.api_key);
    try std.testing.expectEqualStrings("parallel-b", second.parallel_search_runtime.api_key);
    try std.testing.expect(first.backends.web_search_runtime_ready);
    try std.testing.expect(first.backends.web_search.?.ctx != second.backends.web_search.?.ctx);
    try std.testing.expect(first.backends.web_fetch.?.ctx != second.backends.web_fetch.?.ctx);
    try std.testing.expectEqualStrings("", parallel_search_template.api_key);
    try std.testing.expectEqualStrings("", parallel_fetch_template.api_key);
}
