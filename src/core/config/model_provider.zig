const std = @import("std");
const types = @import("../shared/types.zig");

pub const ProviderId = enum {
    gateway,
    codex,
    grok,
    opencode,
    cline,
};

pub const ProviderSelection = struct {
    provider: ProviderId,
    model: []const u8,
};

pub fn parse(value: []const u8) ?ProviderId {
    if (std.ascii.eqlIgnoreCase(value, "gateway")) return .gateway;
    if (std.ascii.eqlIgnoreCase(value, "codex")) return .codex;
    if (std.ascii.eqlIgnoreCase(value, "grok")) return .grok;
    if (std.ascii.eqlIgnoreCase(value, "opencode")) return .opencode;
    if (std.ascii.eqlIgnoreCase(value, "cline")) return .cline;
    return null;
}

pub fn requiredCredentialSource(provider: ProviderId) ?types.CredentialSource {
    return switch (provider) {
        .gateway => null,
        .codex => .chatgpt_subscription,
        .grok => .grok_subscription,
        .opencode => .opencode_anonymous,
        .cline => .cline_account,
    };
}

pub fn authorizesCredential(provider: ProviderId, source: ?types.CredentialSource) bool {
    const selected = source orelse return false;
    if (selected == .host_managed) return true;
    return switch (provider) {
        .gateway => selected != .chatgpt_subscription and selected != .grok_subscription and selected != .opencode_anonymous and selected != .opencode_api_key and selected != .cline_account and selected != .cline_api_key,
        .codex => selected == .chatgpt_subscription,
        .grok => selected == .grok_subscription,
        .opencode => selected == .opencode_anonymous or selected == .opencode_api_key,
        .cline => selected == .cline_account or selected == .cline_api_key,
    };
}

test "explicit providers authorize only their own credential origins" {
    try std.testing.expect(authorizesCredential(.gateway, .ai_gateway_api_key));
    try std.testing.expect(authorizesCredential(.gateway, .fx_login));
    try std.testing.expect(!authorizesCredential(.gateway, .chatgpt_subscription));
    try std.testing.expect(authorizesCredential(.codex, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.codex, .ai_gateway_api_key));
    try std.testing.expect(!authorizesCredential(.codex, null));
    try std.testing.expect(authorizesCredential(.grok, .grok_subscription));
    try std.testing.expect(!authorizesCredential(.grok, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.gateway, .grok_subscription));
    try std.testing.expect(authorizesCredential(.opencode, .opencode_api_key));
    try std.testing.expect(authorizesCredential(.opencode, .opencode_anonymous));
    try std.testing.expect(!authorizesCredential(.gateway, .opencode_api_key));
    try std.testing.expect(authorizesCredential(.cline, .cline_api_key));
    try std.testing.expect(authorizesCredential(.cline, .cline_account));
    try std.testing.expect(!authorizesCredential(.gateway, .cline_api_key));
    try std.testing.expectEqual(types.CredentialSource.opencode_anonymous, requiredCredentialSource(.opencode).?);
    try std.testing.expect(requiredCredentialSource(.gateway) == null);
}

test "provider parsing exposes every provider" {
    try std.testing.expectEqual(ProviderId.gateway, parse("gateway").?);
    try std.testing.expectEqual(ProviderId.codex, parse("CODEX").?);
    try std.testing.expectEqual(ProviderId.grok, parse("GROK").?);
    try std.testing.expectEqual(ProviderId.opencode, parse("OpenCode").?);
    try std.testing.expectEqual(ProviderId.cline, parse("Cline").?);
    try std.testing.expect(parse("openai-codex") == null);
    try std.testing.expect(parse("") == null);
}
