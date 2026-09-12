const std = @import("std");
const host = @import("fx_orchestration_host");
const team_document = @import("domain/team_document.zig");

const Allocator = std.mem.Allocator;
const ObjectMap = std.json.ObjectMap;

const RoleKind = enum { peer, specialist };
const RoleRef = union(enum) {
    primary,
    peer: usize,
    specialist: usize,
};
const TextField = enum { team_name, definition };
const Screen = union(enum) {
    overview,
    provider,
    members: RoleKind,
    role: RoleRef,
    specialist_access,
    specialist_targets: RoleRef,
    text: struct { field: TextField, role: ?RoleRef, previous: PreviousScreen },
    delete_role: RoleRef,
};
const PreviousScreen = union(enum) { overview, role: RoleRef };

pub const Editor = struct {
    // JSON's managed arrays retain allocator pointers across Editor moves.
    arena: *std.heap.ArenaAllocator,
    root: std.json.Value,
    screen: Screen = .overview,
    selected: usize = 0,
    rows: [128]host.DefinitionEditorRow = undefined,
    row_count: usize = 0,
    label_buffers: [128][64]u8 = undefined,
    detail_buffers: [128][256]u8 = undefined,
    title_buffer: [256]u8 = undefined,
    error_buffer: [256]u8 = undefined,
    error_len: usize = 0,
    identity_seed: [32]u8,
    next_identity_ordinal: u64 = 0,

    pub fn init(
        alloc: Allocator,
        source: []const u8,
        identity_seed: [32]u8,
        regenerate_identities: bool,
    ) !Editor {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        errdefer alloc.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const value = try std.json.parseFromSliceLeaky(
            std.json.Value,
            arena.allocator(),
            source,
            .{},
        );
        if (value != .object) return error.InvalidTeamDocument;
        var editor = Editor{
            .arena = arena,
            .root = value,
            .identity_seed = identity_seed,
        };
        editor.removeLegacyPeerFields();
        if (regenerate_identities) try editor.regenerateAllIdentities();
        return editor;
    }

    pub fn deinit(self: *Editor) void {
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
        self.* = undefined;
    }

    pub fn projection(self: *Editor) host.DefinitionEditorProjection {
        self.row_count = 0;
        const title = switch (self.screen) {
            .overview => "Team",
            .provider => "Model provider",
            .members => |kind| if (kind == .peer) "Peers" else "Specialists",
            .role => |role| self.roleTitle(role),
            .specialist_access => "Specialist access",
            .specialist_targets => |role| self.specialistAccessTitle(role),
            .text => |field| textFieldTitle(field.field),
            .delete_role => "Remove role?",
        };
        const accepts_text = self.screen == .text;
        switch (self.screen) {
            .overview => self.projectOverview(),
            .provider => self.projectProvider(),
            .members => |kind| self.projectMembers(kind),
            .role => |role| self.projectRole(role),
            .specialist_access => self.projectSpecialistAccess(),
            .specialist_targets => |role| self.projectSpecialistTargets(role),
            .text => |field| self.projectText(field.field),
            .delete_role => |role| self.projectDelete(role),
        }
        self.clampSelection();
        for (self.rows[0..self.row_count], 0..) |*row, index| row.selected = index == self.selected;
        return .{
            .active = true,
            .title = title,
            .subtitle = self.subtitle(),
            .rows = self.rows[0..self.row_count],
            .error_message = self.error_buffer[0..self.error_len],
            .accepts_text = accepts_text,
            .hint = if (accepts_text)
                "Enter Apply  ·  Esc Cancel"
            else if (self.screen == .specialist_targets)
                "↑↓ Navigate  ·  Enter Toggle  ·  Esc Done"
            else
                "↑↓ Navigate  ·  Enter Select  ·  Esc Back",
        };
    }

    pub fn move(self: *Editor, delta: i32) bool {
        if (self.screen == .text) return false;
        _ = self.projection();
        if (self.row_count == 0) return false;
        var next: i32 = @as(i32, @intCast(self.selected)) + delta;
        if (next < 0) next = @as(i32, @intCast(self.row_count)) - 1;
        if (next >= @as(i32, @intCast(self.row_count))) next = 0;
        self.selected = @intCast(next);
        return true;
    }

    pub fn submit(self: *Editor, alloc: Allocator, input: []const u8) !host.DefinitionEditorOutcome {
        self.clearError();
        return switch (self.screen) {
            .overview => self.submitOverview(alloc),
            .provider => self.submitProvider(),
            .members => |kind| self.submitMembers(kind),
            .role => |role| self.submitRole(role),
            .specialist_access => self.submitSpecialistAccess(),
            .specialist_targets => |role| self.submitSpecialistTarget(role),
            .text => |field| self.submitText(field, input),
            .delete_role => |role| self.submitDeleteRole(role),
        };
    }

    pub fn back(self: *Editor) host.DefinitionEditorOutcome {
        self.clearError();
        switch (self.screen) {
            .overview => return .exit,
            .provider, .members, .specialist_access => self.screen = .overview,
            .role => |role| self.screen = switch (role) {
                .primary => .overview,
                .peer => .{ .members = .peer },
                .specialist => .{ .members = .specialist },
            },
            .specialist_targets => self.screen = .specialist_access,
            .text => |field| self.screen = previousScreen(field.previous),
            .delete_role => |role| self.screen = .{ .role = role },
        }
        self.selected = 0;
        return .{ .replace_input = "" };
    }

    fn submitOverview(self: *Editor, alloc: Allocator) !host.DefinitionEditorOutcome {
        switch (self.selected) {
            0 => return self.beginText(.team_name, null, .overview, self.teamString("name")),
            1 => self.screen = .provider,
            2 => self.screen = .{ .role = .primary },
            3 => self.screen = .{ .members = .peer },
            4 => self.screen = .{ .members = .specialist },
            5 => self.screen = .specialist_access,
            6 => {
                if (self.missingModelRole()) |role| {
                    const message = std.fmt.bufPrint(&self.error_buffer, "Choose a model for {s}.", .{self.roleTitle(role)}) catch unreachable;
                    self.error_len = message.len;
                    return .redraw;
                }
                const source = self.serialize(alloc) catch |err| {
                    self.setErrorName("Team could not be saved", err);
                    return .redraw;
                };
                errdefer alloc.free(source);
                var parsed = team_document.Document.parse(alloc, source) catch |err| {
                    alloc.free(source);
                    self.setError(teamValidationMessage(err));
                    return .redraw;
                };
                parsed.deinit();
                return .{ .save = source };
            },
            else => return .redraw,
        }
        self.selected = 0;
        return .{ .replace_input = "" };
    }

    fn submitProvider(self: *Editor) !host.DefinitionEditorOutcome {
        const provider = switch (self.selected) {
            0 => "opencode",
            1 => "cline",
            else => "vercel",
        };
        try self.setTeamString("provider_id", provider);
        self.screen = .overview;
        self.selected = 1;
        return .{ .replace_input = "" };
    }

    fn submitMembers(self: *Editor, kind: RoleKind) !host.DefinitionEditorOutcome {
        const count = self.roleArray(kind).items.len;
        if (self.selected < count) {
            self.screen = .{ .role = if (kind == .peer)
                .{ .peer = self.selected }
            else
                .{ .specialist = self.selected } };
            self.selected = 0;
            return .{ .replace_input = "" };
        }
        if (self.selected == count) {
            const role = try self.addRole(kind);
            self.screen = .{ .role = role };
            self.selected = 0;
            return .{ .replace_input = "" };
        }
        self.screen = .overview;
        self.selected = if (kind == .peer) 3 else 4;
        return .{ .replace_input = "" };
    }

    fn submitRole(self: *Editor, role: RoleRef) !host.DefinitionEditorOutcome {
        if (role == .specialist) {
            switch (self.selected) {
                0 => return .{ .choose_model = self.teamString("provider_id") },
                1 => return self.beginText(.definition, role, .{ .role = role }, self.roleString(role, "definition")),
                2 => {
                    self.screen = .{ .delete_role = role };
                    self.selected = 1;
                },
                else => {},
            }
            return .{ .replace_input = "" };
        }
        switch (self.selected) {
            0 => return .{ .choose_model = self.teamString("provider_id") },
            1 => return self.beginText(.definition, role, .{ .role = role }, self.roleString(role, "definition")),
            2 => {
                self.screen = .{ .specialist_targets = role };
                self.selected = 0;
            },
            3 => {
                if (role == .primary) {
                    self.screen = .overview;
                    self.selected = 2;
                } else {
                    self.screen = .{ .delete_role = role };
                    self.selected = 1;
                }
            },
            else => {},
        }
        return .{ .replace_input = "" };
    }

    fn submitSpecialistAccess(self: *Editor) host.DefinitionEditorOutcome {
        const agent_count = 1 + self.roleArray(.peer).items.len;
        if (self.selected < agent_count) {
            self.screen = .{ .specialist_targets = if (self.selected == 0)
                .primary
            else
                .{ .peer = self.selected - 1 } };
            self.selected = 0;
        } else {
            self.screen = .overview;
            self.selected = 5;
        }
        return .{ .replace_input = "" };
    }

    fn submitSpecialistTarget(self: *Editor, role: RoleRef) !host.DefinitionEditorOutcome {
        const specialists = self.roleArray(.specialist).items;
        for (specialists, 0..) |_, specialist_index| {
            if (specialist_index == self.selected) {
                try self.toggleSpecialist(role, specialist_index);
                return .redraw;
            }
        }
        self.screen = .specialist_access;
        self.selected = 0;
        return .{ .replace_input = "" };
    }

    fn submitText(
        self: *Editor,
        field: @FieldType(Screen, "text"),
        input_raw: []const u8,
    ) !host.DefinitionEditorOutcome {
        const input = std.mem.trim(u8, input_raw, " \t\r\n");
        if (input.len == 0) {
            self.setError("This field cannot be empty.");
            return .redraw;
        }
        switch (field.field) {
            .team_name => try self.setTeamString("name", input),
            .definition => try self.setRoleString(field.role.?, "definition", input),
        }
        self.screen = previousScreen(field.previous);
        self.selected = switch (field.field) {
            .team_name => 0,
            .definition => 1,
        };
        return .{ .replace_input = "" };
    }

    fn submitDeleteRole(self: *Editor, role: RoleRef) !host.DefinitionEditorOutcome {
        if (self.selected == 0) {
            const kind: RoleKind = switch (role) {
                .peer => .peer,
                .specialist => .specialist,
                .primary => return .redraw,
            };
            try self.removeRole(role);
            self.screen = .{ .members = kind };
            self.selected = 0;
        } else {
            self.screen = .{ .role = role };
            self.selected = if (role == .specialist) 2 else 3;
        }
        return .{ .replace_input = "" };
    }

    fn projectOverview(self: *Editor) void {
        self.addRow("Name", self.teamString("name"), false, false);
        self.addRow("Provider", providerLabel(self.teamString("provider_id")), false, false);
        self.addRow("Primary", self.modelDisplay(.primary), false, false);
        self.addCountRow("Peers", self.roleArray(.peer).items.len);
        self.addCountRow("Specialists", self.roleArray(.specialist).items.len);
        self.addRow("Specialist access", "assign specialists to primary and peers", false, false);
        self.addRow("Save & start", "new Fixer conversation", false, false);
    }

    fn projectProvider(self: *Editor) void {
        const current = self.teamString("provider_id");
        self.addRow("OpenCode", "Zen and Go", std.mem.eql(u8, current, "opencode"), false);
        self.addRow("Cline", "free and ClinePass", std.mem.eql(u8, current, "cline"), false);
        self.addRow("Vercel AI Gateway", "unified model catalog", std.mem.eql(u8, current, "vercel"), false);
    }

    fn projectMembers(self: *Editor, kind: RoleKind) void {
        for (self.roleArray(kind).items, 0..) |_, index| {
            const role: RoleRef = if (kind == .peer) .{ .peer = index } else .{ .specialist = index };
            self.addRow(self.roleLabel(role), self.modelDisplay(role), false, false);
        }
        self.addRow(if (kind == .peer) "+ Add peer" else "+ Add specialist", "", false, false);
        self.addRow("Back", "", false, false);
    }

    fn projectRole(self: *Editor, role: RoleRef) void {
        self.addRow("Model", self.modelDisplay(role), false, false);
        self.addRow("Instructions", self.roleString(role, "definition"), false, false);
        if (role == .specialist) {
            self.addRow("Remove role", "", false, true);
        } else {
            self.addRow("Specialists", "assign callable specialists", false, false);
            self.addRow(if (role == .primary) "Back" else "Remove role", "", false, role != .primary);
        }
    }

    fn projectSpecialistAccess(self: *Editor) void {
        self.addRow("Primary", self.modelDisplay(.primary), false, false);
        for (self.roleArray(.peer).items, 0..) |_, index| {
            const role: RoleRef = .{ .peer = index };
            self.addRow(self.roleLabel(role), self.modelDisplay(role), false, false);
        }
        self.addRow("Done", "", false, false);
    }

    fn projectSpecialistTargets(self: *Editor, role: RoleRef) void {
        for (self.roleArray(.specialist).items, 0..) |_, index| {
            const target: RoleRef = .{ .specialist = index };
            self.addRow(
                self.roleLabel(target),
                self.modelDisplay(target),
                self.hasSpecialist(role, index),
                false,
            );
        }
        self.addRow("Done", "", false, false);
    }

    fn projectText(self: *Editor, field: TextField) void {
        const detail = switch (field) {
            .definition => "Describe this role's expertise, judgment, and responsibilities.",
            .team_name => "A concise display name for this Team.",
        };
        self.addRow(detail, "", false, false);
    }

    fn projectDelete(self: *Editor, role: RoleRef) void {
        self.addRow("Remove", self.roleLabel(role), false, true);
        self.addRow("Cancel", "", false, false);
    }

    fn subtitle(self: *Editor) []const u8 {
        return switch (self.screen) {
            .overview => "Configure a primary plus at least one peer or specialist.",
            .provider => "Fixer accepts only unified multi-model providers.",
            .members => "Every role must use a distinct catalog model.",
            .role => "Model and instructions are pinned in this Team revision.",
            .specialist_access => "Every peer can consult every other peer; specialist access is assigned here.",
            .specialist_targets => "Checked specialists are callable by this primary or peer.",
            .text => "",
            .delete_role => "References and the role's model are removed together.",
        };
    }

    fn beginText(
        self: *Editor,
        field: TextField,
        role: ?RoleRef,
        previous: PreviousScreen,
        current: []const u8,
    ) host.DefinitionEditorOutcome {
        self.screen = .{ .text = .{ .field = field, .role = role, .previous = previous } };
        self.selected = 0;
        return .{ .replace_input = current };
    }

    fn rootObject(self: *Editor) *ObjectMap {
        return &self.root.object;
    }

    fn teamString(self: *Editor, key: []const u8) []const u8 {
        const value = self.rootObject().get(key) orelse return "";
        return if (value == .string) value.string else "";
    }

    fn setTeamString(self: *Editor, key: []const u8, value: []const u8) !void {
        try self.rootObject().put(
            self.arena.allocator(),
            try self.arena.allocator().dupe(u8, key),
            .{ .string = try self.arena.allocator().dupe(u8, value) },
        );
    }

    fn roleArray(self: *Editor, kind: RoleKind) *std.json.Array {
        const key = if (kind == .peer) "peers" else "specialists";
        return &self.rootObject().getPtr(key).?.array;
    }

    fn roleObject(self: *Editor, role: RoleRef) *ObjectMap {
        return switch (role) {
            .primary => &self.rootObject().getPtr("primary").?.object,
            .peer => |index| &self.roleArray(.peer).items[index].object,
            .specialist => |index| &self.roleArray(.specialist).items[index].object,
        };
    }

    fn roleString(self: *Editor, role: RoleRef, key: []const u8) []const u8 {
        const value = self.roleObject(role).get(key) orelse return "";
        return if (value == .string) value.string else "";
    }

    fn setRoleString(self: *Editor, role: RoleRef, key: []const u8, value: []const u8) !void {
        try self.roleObject(role).put(
            self.arena.allocator(),
            try self.arena.allocator().dupe(u8, key),
            .{ .string = try self.arena.allocator().dupe(u8, value) },
        );
    }

    fn models(self: *Editor) *std.json.Array {
        return &self.rootObject().getPtr("models").?.array;
    }

    fn modelObject(self: *Editor, role: RoleRef) ?*ObjectMap {
        const model_id = self.roleString(role, "model_id");
        for (self.models().items) |*value| {
            const id = value.object.get("id") orelse continue;
            if (id == .string and std.mem.eql(u8, id.string, model_id)) return &value.object;
        }
        return null;
    }

    fn modelDisplay(self: *Editor, role: RoleRef) []const u8 {
        const model = self.modelObject(role) orelse return "Choose model";
        const route_value = model.get("route") orelse return "Choose model";
        const name_value = model.get("name") orelse return "Choose model";
        if (route_value != .string or name_value != .string) return "Choose model";
        if (route_value.string.len == 0 or name_value.string.len == 0) return "Choose model";
        const slot = self.row_count % self.detail_buffers.len;
        const identity = host.ModelIdentity{
            .route = route_value.string,
            .name = name_value.string,
        };
        return identity.display(
            self.teamString("provider_id"),
            &self.detail_buffers[slot],
        ) orelse "Choose model";
    }

    fn roleHasModel(self: *Editor, role: RoleRef) bool {
        const model = self.modelObject(role) orelse return false;
        for ([_][]const u8{ "id", "route", "name" }) |key| {
            const value = model.get(key) orelse return false;
            if (value != .string or std.mem.trim(u8, value.string, " \t\r\n").len == 0) return false;
        }
        return true;
    }

    fn missingModelRole(self: *Editor) ?RoleRef {
        if (!self.roleHasModel(.primary)) return .primary;
        for (self.roleArray(.peer).items, 0..) |_, index| {
            const role: RoleRef = .{ .peer = index };
            if (!self.roleHasModel(role)) return role;
        }
        for (self.roleArray(.specialist).items, 0..) |_, index| {
            const role: RoleRef = .{ .specialist = index };
            if (!self.roleHasModel(role)) return role;
        }
        return null;
    }

    fn setRoleModel(self: *Editor, role: RoleRef, input: []const u8) !void {
        const provider = self.teamString("provider_id");
        const identity = host.ModelIdentity.parse(provider, input) catch
            return error.InvalidModelId;
        const route = identity.route;
        const name = identity.name;
        if (route.len == 0 or name.len == 0) return error.InvalidModelId;
        const current = self.modelObject(role) orelse return error.UnknownModel;
        for (self.models().items) |*value| {
            if (&value.object == current) continue;
            const other_route = value.object.get("route") orelse continue;
            const other_name = value.object.get("name") orelse continue;
            if (other_route == .string and other_name == .string and
                std.ascii.eqlIgnoreCase(other_route.string, route) and
                std.mem.eql(u8, other_name.string, name))
            {
                return error.DuplicateCatalogModel;
            }
        }
        try current.put(self.arena.allocator(), "route", .{ .string = try self.arena.allocator().dupe(u8, route) });
        try current.put(self.arena.allocator(), "name", .{ .string = try self.arena.allocator().dupe(u8, name) });
    }

    pub fn applySelectedModel(self: *Editor, input: []const u8) void {
        const role = switch (self.screen) {
            .role => |value| value,
            else => return,
        };
        self.clearError();
        self.setRoleModel(role, input) catch |err| {
            self.setError(switch (err) {
                error.DuplicateCatalogModel => "Every Team role must use a distinct model.",
                else => "That catalog model could not be applied.",
            });
        };
        self.selected = 0;
    }

    pub fn expectsModelSelection(self: *const Editor) bool {
        return switch (self.screen) {
            .role => self.selected == 0,
            else => false,
        };
    }

    fn replaceRoleIdentity(self: *Editor, role: RoleRef, new_id: []const u8) !void {
        const old_id = self.roleString(role, "id");
        const owned = try self.arena.allocator().dupe(u8, new_id);
        if (self.rootObject().getPtr("primary").?.object.getPtr("specialists")) |value| {
            replaceArrayString(&value.array, old_id, owned);
        }
        for (self.roleArray(.peer).items) |*peer| {
            if (peer.object.getPtr("specialists")) |value| {
                replaceArrayString(&value.array, old_id, owned);
            }
        }
        try self.roleObject(role).put(self.arena.allocator(), "id", .{ .string = owned });
    }

    fn newOpaqueIdentity(self: *Editor, prefix: []const u8) ![]const u8 {
        var material: [40]u8 = undefined;
        @memcpy(material[0..32], &self.identity_seed);
        std.mem.writeInt(u64, material[32..40], self.next_identity_ordinal, .big);
        self.next_identity_ordinal += 1;

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&material, &digest, .{});
        const suffix_bytes: [12]u8 = digest[0..12].*;
        const suffix = std.fmt.bytesToHex(suffix_bytes, .lower);
        return std.fmt.allocPrint(self.arena.allocator(), "{s}-{s}", .{ prefix, suffix });
    }

    fn regenerateRoleIdentity(self: *Editor, role: RoleRef) !void {
        const model = self.modelObject(role) orelse return error.UnknownModel;
        const role_id = try self.newOpaqueIdentity("role");
        const model_id = try self.newOpaqueIdentity("model");
        try self.replaceRoleIdentity(role, role_id);
        try model.put(self.arena.allocator(), "id", .{
            .string = try self.arena.allocator().dupe(u8, model_id),
        });
        try self.setRoleString(role, "model_id", model_id);
    }

    fn regenerateAllIdentities(self: *Editor) !void {
        try self.regenerateRoleIdentity(.primary);
        for (self.roleArray(.peer).items, 0..) |_, index| {
            try self.regenerateRoleIdentity(.{ .peer = index });
        }
        for (self.roleArray(.specialist).items, 0..) |_, index| {
            try self.regenerateRoleIdentity(.{ .specialist = index });
        }
    }

    fn addRole(self: *Editor, kind: RoleKind) !RoleRef {
        const index = self.roleArray(kind).items.len;
        const id = try self.newOpaqueIdentity("role");
        const model_id = try self.newOpaqueIdentity("model");
        var model: ObjectMap = .empty;
        try model.put(self.arena.allocator(), "id", .{ .string = model_id });
        try model.put(self.arena.allocator(), "route", .{ .string = try self.arena.allocator().dupe(u8, "") });
        try model.put(self.arena.allocator(), "name", .{ .string = try self.arena.allocator().dupe(u8, "") });
        try self.models().append(.{ .object = model });

        var object: ObjectMap = .empty;
        try object.put(self.arena.allocator(), "id", .{ .string = id });
        try object.put(self.arena.allocator(), "model_id", .{ .string = model_id });
        try object.put(self.arena.allocator(), "definition", .{ .string = try self.arena.allocator().dupe(u8, "Describe this role.") });
        if (kind == .peer) {
            try object.put(self.arena.allocator(), "specialists", .{ .array = std.json.Array.init(self.arena.allocator()) });
        }
        try self.roleArray(kind).append(.{ .object = object });
        const role: RoleRef = if (kind == .peer) .{ .peer = index } else .{ .specialist = index };
        if (kind == .specialist) try self.setSpecialist(.primary, index, true);
        return role;
    }

    fn removeRole(self: *Editor, role: RoleRef) !void {
        const id = self.roleString(role, "id");
        const model_id = self.roleString(role, "model_id");
        self.removeReferences(id);
        var model_index: usize = 0;
        while (model_index < self.models().items.len) : (model_index += 1) {
            const value = self.models().items[model_index].object.get("id") orelse continue;
            if (value == .string and std.mem.eql(u8, value.string, model_id)) {
                _ = self.models().orderedRemove(model_index);
                break;
            }
        }
        switch (role) {
            .peer => |index| _ = self.roleArray(.peer).orderedRemove(index),
            .specialist => |index| _ = self.roleArray(.specialist).orderedRemove(index),
            .primary => return error.CannotRemovePrimary,
        }
    }

    fn removeReferences(self: *Editor, id: []const u8) void {
        if (self.rootObject().getPtr("primary").?.object.getPtr("specialists")) |value| {
            removeArrayString(&value.array, id);
        }
        for (self.roleArray(.peer).items) |*peer| {
            if (peer.object.getPtr("specialists")) |value| removeArrayString(&value.array, id);
        }
    }

    fn hasSpecialist(self: *Editor, role: RoleRef, index: usize) bool {
        return arrayContains(self.specialistArray(role), self.roleString(.{ .specialist = index }, "id"));
    }

    fn toggleSpecialist(self: *Editor, role: RoleRef, index: usize) !void {
        try self.setSpecialist(role, index, !self.hasSpecialist(role, index));
    }

    fn setSpecialist(self: *Editor, role: RoleRef, index: usize, enabled: bool) !void {
        const id = self.roleString(.{ .specialist = index }, "id");
        const values = self.specialistArray(role);
        removeArrayString(values, id);
        if (enabled) try values.append(.{
            .string = try self.arena.allocator().dupe(u8, id),
        });
    }

    fn specialistArray(self: *Editor, role: RoleRef) *std.json.Array {
        const object = self.roleObject(role);
        if (object.getPtr("specialists")) |value| return &value.array;
        object.put(self.arena.allocator(), "specialists", .{
            .array = std.json.Array.init(self.arena.allocator()),
        }) catch unreachable;
        return &object.getPtr("specialists").?.array;
    }

    fn removeLegacyPeerFields(self: *Editor) void {
        _ = self.rootObject().getPtr("primary").?.object.orderedRemove("peers");
        for (self.roleArray(.peer).items) |*peer| {
            _ = peer.object.orderedRemove("peers");
        }
    }

    fn serialize(self: *Editor, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try std.json.Stringify.value(self.root, .{ .whitespace = .indent_2 }, &out.writer);
        return out.toOwnedSlice();
    }

    fn addRow(self: *Editor, label: []const u8, detail: []const u8, marked: bool, destructive: bool) void {
        if (self.row_count >= self.rows.len) return;
        self.rows[self.row_count] = .{
            .label = label,
            .detail = detail,
            .marked = marked,
            .destructive = destructive,
        };
        self.row_count += 1;
    }

    fn addCountRow(self: *Editor, label: []const u8, count: usize) void {
        const slot = self.row_count % self.detail_buffers.len;
        const detail = std.fmt.bufPrint(&self.detail_buffers[slot], "{d}", .{count}) catch "";
        self.addRow(label, detail, false, false);
    }

    fn clampSelection(self: *Editor) void {
        if (self.row_count == 0) self.selected = 0 else self.selected %= self.row_count;
    }

    fn roleTitle(self: *Editor, role: RoleRef) []const u8 {
        return switch (role) {
            .primary => "Primary",
            .peer => |index| std.fmt.bufPrint(&self.title_buffer, "Peer {d}", .{index + 1}) catch "Peer",
            .specialist => |index| std.fmt.bufPrint(&self.title_buffer, "Specialist {d}", .{index + 1}) catch "Specialist",
        };
    }

    fn roleLabel(self: *Editor, role: RoleRef) []const u8 {
        const slot = self.row_count % self.label_buffers.len;
        return switch (role) {
            .primary => "Primary",
            .peer => |index| std.fmt.bufPrint(&self.label_buffers[slot], "Peer {d}", .{index + 1}) catch "Peer",
            .specialist => |index| std.fmt.bufPrint(&self.label_buffers[slot], "Specialist {d}", .{index + 1}) catch "Specialist",
        };
    }

    fn specialistAccessTitle(self: *Editor, role: RoleRef) []const u8 {
        return switch (role) {
            .primary => "Specialists · Primary",
            .peer => |index| std.fmt.bufPrint(
                &self.title_buffer,
                "Specialists · Peer {d}",
                .{index + 1},
            ) catch "Specialists",
            .specialist => "Specialists",
        };
    }

    fn setError(self: *Editor, message: []const u8) void {
        const len = @min(message.len, self.error_buffer.len);
        @memcpy(self.error_buffer[0..len], message[0..len]);
        self.error_len = len;
    }

    fn setErrorName(self: *Editor, prefix: []const u8, err: anyerror) void {
        const message = std.fmt.bufPrint(
            &self.error_buffer,
            "{s}: {s}",
            .{ prefix, @errorName(err) },
        ) catch prefix;
        self.error_len = message.len;
    }

    fn clearError(self: *Editor) void {
        self.error_len = 0;
    }
};

fn textFieldTitle(field: TextField) []const u8 {
    return switch (field) {
        .team_name => "Team name",
        .definition => "Role instructions",
    };
}

fn previousScreen(previous: PreviousScreen) Screen {
    return switch (previous) {
        .overview => .overview,
        .role => |role| .{ .role = role },
    };
}

fn providerLabel(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "opencode")) return "OpenCode";
    if (std.mem.eql(u8, provider, "cline")) return "Cline";
    if (std.mem.eql(u8, provider, "vercel")) return "Vercel AI Gateway";
    return provider;
}

fn teamValidationMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCollaborator => "Add at least one peer or specialist before starting Fixer.",
        error.UnreachableSpecialist => "Give at least one primary or peer access to every specialist.",
        error.DuplicateCatalogModel, error.DuplicateModelOwner => "Every Team role must use a distinct model.",
        error.EmptyModel => "Choose a model for every Team role.",
        error.InvalidIdentifier, error.DuplicateAssignment => "This Team contains an invalid internal identity.",
        error.UnsupportedProvider => "Choose OpenCode, Cline, or Vercel AI Gateway.",
        else => "This Team is incomplete. Review every role, model, and specialist assignment.",
    };
}

fn arrayContains(values: *const std.json.Array, expected: []const u8) bool {
    for (values.items) |value| {
        if (value == .string and std.mem.eql(u8, value.string, expected)) return true;
    }
    return false;
}

fn removeArrayString(values: *std.json.Array, expected: []const u8) void {
    var index: usize = 0;
    while (index < values.items.len) {
        const value = values.items[index];
        if (value == .string and std.mem.eql(u8, value.string, expected)) {
            _ = values.orderedRemove(index);
        } else {
            index += 1;
        }
    }
}

fn replaceArrayString(values: *std.json.Array, expected: []const u8, replacement: []const u8) void {
    for (values.items) |*value| {
        if (value.* == .string and std.mem.eql(u8, value.string, expected)) {
            value.* = .{ .string = replacement };
        }
    }
}

const test_identity_seed = [_]u8{0x5a} ** 32;

const empty_test_team =
    "{\"schema\":2,\"id\":\"test-team\",\"revision\":1,\"name\":\"Test\",\"provider_id\":\"opencode\",\"models\":[" ++
    "{\"id\":\"primary-model\",\"route\":\"\",\"name\":\"\"},{\"id\":\"peer-model\",\"route\":\"\",\"name\":\"\"}]," ++
    "\"primary\":{\"id\":\"primary\",\"model_id\":\"primary-model\",\"definition\":\"Own.\"}," ++
    "\"peers\":[{\"id\":\"peer\",\"model_id\":\"peer-model\",\"definition\":\"Help.\"}],\"specialists\":[]}";

test "Team editor array allocators survive initialization and relocation" {
    const alloc = std.testing.allocator;
    var original = try Editor.init(alloc, empty_test_team, test_identity_seed, true);
    const moved = try alloc.create(Editor);
    defer alloc.destroy(moved);
    moved.* = original;
    original = undefined;
    defer moved.deinit();
    // Managed JSON arrays retain their allocator context. It must belong to
    // the live editor, never an initializer's stack frame or its former copy.
    try std.testing.expectEqual(moved.arena.allocator().ptr, moved.models().allocator.ptr);
    try std.testing.expectEqual(moved.arena.allocator().ptr, moved.roleArray(.peer).allocator.ptr);
    try std.testing.expectEqual(moved.arena.allocator().ptr, moved.roleArray(.specialist).allocator.ptr);
}

test "Team editor preserves selected models when adding and removing roles" {
    const alloc = std.testing.allocator;
    var editor = try Editor.init(alloc, empty_test_team, test_identity_seed, true);
    defer editor.deinit();
    try editor.setRoleModel(.primary, "deepseek-v4-flash-vision-exp");
    try editor.setRoleModel(.{ .peer = 0 }, "go/deepseek-v4-pro");
    const peer = try editor.addRole(.peer);
    try editor.setRoleModel(peer, "kimi-k3");
    const specialist = try editor.addRole(.specialist);
    try editor.setRoleModel(specialist, "glm-5");
    for (0..2) |iteration| {
        editor.screen = .overview;
        editor.selected = 6;
        const outcome = try editor.submit(alloc, "");
        switch (outcome) {
            .save => |source| {
                defer alloc.free(source);
                var document = try team_document.Document.parse(alloc, source);
                defer document.deinit();
                try std.testing.expectEqual(@as(usize, 2), document.value.peers.len);
                try std.testing.expectEqual(@as(usize, 1 - iteration), document.value.specialists.len);
                try std.testing.expectEqualStrings("kimi-k3", document.value.model(document.value.peers[1].model_id).?.name);
            },
            else => return error.ExpectedSavedTeam,
        }
        if (iteration == 0) try editor.removeRole(specialist);
    }
}

test "Team save identifies missing roles after rejected duplicate selection" {
    const alloc = std.testing.allocator;
    var editor = try Editor.init(alloc, empty_test_team, test_identity_seed, true);
    defer editor.deinit();
    editor.selected = 6;
    _ = try editor.submit(alloc, "");
    try std.testing.expectEqualStrings("Choose a model for Primary.", editor.projection().error_message);
    try editor.setRoleModel(.primary, "deepseek-v4-flash");

    // Choosing an already assigned model must neither fill the empty peer nor
    // erase the primary's selection. Back navigation must not hide which role
    // needs repair the next time Save is attempted.
    editor.screen = .{ .role = .{ .peer = 0 } };
    editor.applySelectedModel("deepseek-v4-flash");
    try std.testing.expectEqualStrings("Every Team role must use a distinct model.", editor.projection().error_message);
    _ = editor.back();
    _ = editor.back();
    editor.selected = 6;
    _ = try editor.submit(alloc, "");
    try std.testing.expectEqualStrings("Choose a model for Peer 1.", editor.projection().error_message);
    try std.testing.expectEqualStrings("deepseek-v4-flash", editor.modelDisplay(.primary));
    try editor.setRoleModel(.{ .peer = 0 }, "go/deepseek-v4-pro");

    const peer = try editor.addRole(.peer);
    editor.selected = 6;
    _ = try editor.submit(alloc, "");
    try std.testing.expectEqualStrings("Choose a model for Peer 2.", editor.projection().error_message);
    try editor.setRoleModel(peer, "kimi-k3");
    const specialist = try editor.addRole(.specialist);
    editor.selected = 6;
    _ = try editor.submit(alloc, "");
    try std.testing.expectEqualStrings("Choose a model for Specialist 1.", editor.projection().error_message);
    try editor.removeRole(specialist);
    editor.selected = 6;
    const outcome = try editor.submit(alloc, "");
    switch (outcome) {
        .save => |source| alloc.free(source),
        else => return error.ExpectedSavedTeam,
    }
}

test "guided Team editor revises without exposing JSON" {
    const alloc = std.testing.allocator;
    const source =
        "{\"schema\":2,\"id\":\"my-team\",\"revision\":1,\"name\":\"My Team\",\"provider_id\":\"opencode\",\"models\":[" ++
        "{\"id\":\"primary-model\",\"route\":\"zen\",\"name\":\"kimi-k3\"}," ++
        "{\"id\":\"peer-model\",\"route\":\"go\",\"name\":\"kimi-k3\"}]," ++
        "\"primary\":{\"id\":\"primary\",\"model_id\":\"primary-model\",\"definition\":\"Own the result.\",\"peers\":[\"peer\"]}," ++
        "\"peers\":[{\"id\":\"peer\",\"model_id\":\"peer-model\",\"definition\":\"Contribute.\"}],\"specialists\":[]}";
    var editor = try Editor.init(alloc, source, test_identity_seed, false);
    defer editor.deinit();
    const projection = editor.projection();
    try std.testing.expectEqualStrings("Team", projection.title);
    try std.testing.expectEqualStrings("Name", projection.rows[0].label);
    for (projection.rows) |row| {
        try std.testing.expect(!std.mem.eql(u8, row.label, "ID"));
        try std.testing.expect(!std.mem.eql(u8, row.label, "Relationships"));
    }
    try std.testing.expect(std.mem.find(u8, projection.rows[0].label, "{") == null);
    editor.selected = 6;
    const outcome = try editor.submit(alloc, "");
    switch (outcome) {
        .save => |saved| {
            defer alloc.free(saved);
            var parsed = try team_document.Document.parse(alloc, saved);
            defer parsed.deinit();
            try std.testing.expect(parsed.value.peers.len + parsed.value.specialists.len > 0);
            const saved_value = try std.json.parseFromSlice(std.json.Value, alloc, saved, .{});
            defer saved_value.deinit();
            try std.testing.expect(saved_value.value.object.get("primary").?.object.get("peers") == null);
            try std.testing.expect(saved_value.value.object.get("peers").?.array.items[0].object.get("peers") == null);
        },
        else => return error.ExpectedSavedTeam,
    }
}

test "role model selection delegates to the native catalog" {
    const alloc = std.testing.allocator;
    const source =
        "{\"schema\":2,\"id\":\"generated-team\",\"revision\":1,\"name\":\"Generated\",\"provider_id\":\"opencode\",\"models\":[" ++
        "{\"id\":\"primary-model\",\"route\":\"\",\"name\":\"\"},{\"id\":\"peer-model\",\"route\":\"\",\"name\":\"\"}]," ++
        "\"primary\":{\"id\":\"primary\",\"model_id\":\"primary-model\",\"definition\":\"Own.\"}," ++
        "\"peers\":[{\"id\":\"peer\",\"model_id\":\"peer-model\",\"definition\":\"Help.\"}],\"specialists\":[]}";
    var editor = try Editor.init(alloc, source, test_identity_seed, false);
    defer editor.deinit();
    editor.selected = 2;
    _ = try editor.submit(alloc, "");
    editor.selected = 0;
    const outcome = try editor.submit(alloc, "");
    switch (outcome) {
        .choose_model => |provider| try std.testing.expectEqualStrings("opencode", provider),
        else => return error.ExpectedNativeModelPicker,
    }
    editor.applySelectedModel("go/deepseek-v4-pro");
    try std.testing.expectEqualStrings("go/deepseek-v4-pro", editor.modelDisplay(.primary));
}

test "role model selection splits explicit provider routes" {
    const alloc = std.testing.allocator;
    const source =
        "{\"schema\":2,\"id\":\"generated-team\",\"revision\":1,\"name\":\"Generated\",\"provider_id\":\"cline\",\"models\":[" ++
        "{\"id\":\"primary-model\",\"route\":\"\",\"name\":\"\"},{\"id\":\"peer-model\",\"route\":\"\",\"name\":\"\"}]," ++
        "\"primary\":{\"id\":\"primary\",\"model_id\":\"primary-model\",\"definition\":\"Own.\"}," ++
        "\"peers\":[{\"id\":\"peer\",\"model_id\":\"peer-model\",\"definition\":\"Help.\"}],\"specialists\":[]}";
    var editor = try Editor.init(alloc, source, test_identity_seed, false);
    defer editor.deinit();
    try std.testing.expectError(
        error.InvalidModelId,
        editor.setRoleModel(.primary, "bare-model-without-route"),
    );
    try editor.setRoleModel(.primary, "z-ai/glm-5.3-flash");
    try std.testing.expectEqualStrings("z-ai/glm-5.3-flash", editor.modelDisplay(.primary));
}

test "new Team roles receive opaque hidden identities" {
    const alloc = std.testing.allocator;
    const source =
        "{\"schema\":2,\"id\":\"generated-team\",\"revision\":1,\"name\":\"Generated\",\"provider_id\":\"opencode\",\"models\":[" ++
        "{\"id\":\"primary-model\",\"route\":\"\",\"name\":\"\"},{\"id\":\"peer-model\",\"route\":\"\",\"name\":\"\"}]," ++
        "\"primary\":{\"id\":\"primary\",\"model_id\":\"primary-model\",\"definition\":\"Own.\"}," ++
        "\"peers\":[{\"id\":\"peer\",\"model_id\":\"peer-model\",\"definition\":\"Help.\"}],\"specialists\":[]}";
    var editor = try Editor.init(alloc, source, test_identity_seed, true);
    defer editor.deinit();

    const primary_id = editor.roleString(.primary, "id");
    const peer_id = editor.roleString(.{ .peer = 0 }, "id");
    try std.testing.expect(std.mem.startsWith(u8, primary_id, "role-"));
    try std.testing.expectEqual(@as(usize, "role-".len + 24), primary_id.len);
    try std.testing.expect(!std.mem.eql(u8, primary_id, peer_id));
    try std.testing.expect(!std.mem.eql(u8, editor.roleString(.primary, "model_id"), "primary-model"));

    editor.screen = .{ .members = .specialist };
    editor.selected = 0;
    _ = try editor.submit(alloc, "");
    const specialist_id = editor.roleString(.{ .specialist = 0 }, "id");
    try std.testing.expect(std.mem.startsWith(u8, specialist_id, "role-"));
    try std.testing.expect(!std.mem.eql(u8, specialist_id, primary_id));

    editor.screen = .{ .role = .primary };
    const projection = editor.projection();
    try std.testing.expectEqualStrings("Primary", projection.title);
    try std.testing.expectEqual(@as(usize, 4), projection.rows.len);
    for (projection.rows) |row| {
        try std.testing.expect(!std.mem.eql(u8, row.label, "ID"));
        try std.testing.expect(std.mem.find(u8, row.label, "role-") == null);
        try std.testing.expect(std.mem.find(u8, row.detail, "role-") == null);
    }
}
