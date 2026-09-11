pub const team = @import("domain/team.zig");
pub const team_document = @import("domain/team_document.zig");
pub const projection = @import("domain/projection.zig");
pub const decision = @import("domain/decision.zig");
pub const context = @import("domain/context.zig");
pub const specialist = @import("domain/specialist.zig");
pub const peer = @import("domain/peer.zig");

test {
    _ = team;
    _ = team_document;
    _ = projection;
    _ = decision;
    _ = context;
    _ = specialist;
    _ = peer;
}
