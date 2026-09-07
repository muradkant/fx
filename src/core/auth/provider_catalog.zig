const std = @import("std");
const model_provider = @import("../config/model_provider.zig");
const types = @import("../shared/types.zig");

pub const CatalogScope = enum {
    provider_native,
    unified,
};

pub const Entry = struct {
    id: model_provider.ProviderId,
    slug: []const u8,
    aliases: []const []const u8 = &.{},
    name: []const u8,
    route_name: []const u8,
    description: []const u8,
    subscription: bool,
    catalog_scope: CatalogScope,
    login_source: types.CredentialSource,
};

pub const entries = [_]Entry{
    .{
        .id = .gateway,
        .slug = "vercel",
        .aliases = &.{ "gateway", "ai-gateway" },
        .name = "Vercel AI Gateway",
        .route_name = "Vercel AI Gateway",
        .description = "Vercel account or AI Gateway billing",
        .subscription = false,
        .catalog_scope = .unified,
        .login_source = .fx_login,
    },
    .{
        .id = .codex,
        .slug = "codex",
        .name = "Codex",
        .route_name = "Codex subscription",
        .description = "ChatGPT Plus, Pro, Business, Enterprise, or Edu subscription",
        .subscription = true,
        .catalog_scope = .provider_native,
        .login_source = .chatgpt_subscription,
    },
    .{
        .id = .grok,
        .slug = "grok",
        .name = "Grok",
        .route_name = "Grok subscription",
        .description = "SuperGrok or X Premium subscription",
        .subscription = true,
        .catalog_scope = .provider_native,
        .login_source = .grok_subscription,
    },
    .{
        .id = .opencode,
        .slug = "opencode",
        .name = "OpenCode",
        .route_name = "OpenCode",
        .description = "Free Zen models; an API key adds paid Zen and Go models",
        .subscription = false,
        .catalog_scope = .unified,
        .login_source = .opencode_api_key,
    },
    .{
        .id = .cline,
        .slug = "cline",
        .name = "Cline",
        .route_name = "Cline",
        .description = "Cline account with free and eligible ClinePass models",
        .subscription = false,
        .catalog_scope = .unified,
        .login_source = .cline_account,
    },
};

pub fn parse(value: []const u8) ?model_provider.ProviderId {
    for (&entries) |*entry| {
        if (std.ascii.eqlIgnoreCase(value, entry.slug)) return entry.id;
        for (entry.aliases) |alias| if (std.ascii.eqlIgnoreCase(value, alias)) return entry.id;
    }
    return null;
}

pub fn find(id: model_provider.ProviderId) *const Entry {
    for (&entries) |*entry| if (entry.id == id) return entry;
    unreachable;
}

pub fn label(id: model_provider.ProviderId) []const u8 {
    return find(id).route_name;
}

test "auth provider catalog uses the model provider identity and explicit aliases" {
    try std.testing.expectEqual(model_provider.ProviderId.gateway, parse("vercel").?);
    try std.testing.expectEqual(model_provider.ProviderId.gateway, parse("gateway").?);
    try std.testing.expectEqual(model_provider.ProviderId.codex, parse("codex").?);
    try std.testing.expectEqual(model_provider.ProviderId.grok, parse("grok").?);
    try std.testing.expectEqual(model_provider.ProviderId.opencode, parse("opencode").?);
    try std.testing.expectEqual(model_provider.ProviderId.cline, parse("cline").?);
    try std.testing.expect(parse("zen") == null);
    try std.testing.expect(parse("openai-codex") == null);
    try std.testing.expect(parse("chatgpt") == null);
    try std.testing.expect(parse("unknown") == null);
    try std.testing.expect(find(.codex).subscription);
    try std.testing.expect(find(.grok).subscription);
    try std.testing.expect(!find(.opencode).subscription);
    try std.testing.expect(!find(.cline).subscription);
    try std.testing.expectEqual(CatalogScope.unified, find(.gateway).catalog_scope);
    try std.testing.expectEqual(CatalogScope.unified, find(.opencode).catalog_scope);
    try std.testing.expectEqual(CatalogScope.unified, find(.cline).catalog_scope);
    try std.testing.expectEqual(CatalogScope.provider_native, find(.codex).catalog_scope);
    try std.testing.expectEqual(CatalogScope.provider_native, find(.grok).catalog_scope);
}
