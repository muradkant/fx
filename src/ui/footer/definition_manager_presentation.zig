const std = @import("std");
const definition_manager = @import("../../core/orchestration/definition_manager.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const Projection = render_input.DefinitionManagerProjection;

pub fn menuRowCount(projection: Projection, max_rows: u16) u16 {
    if (!projection.active or max_rows == 0) return 0;
    const desired: usize = switch (projection.stage) {
        .library => 2 + projection.navigationItemCount(),
        .actions => 7,
        .delete_confirmation => 6,
        .editor => 3 + projection.editor.rows.len + @intFromBool(projection.editor.error_message.len > 0),
    };
    return @intCast(@min(desired, max_rows));
}

pub fn visibleNavigationItemsForBudget(projection: Projection, row_budget: u16) u16 {
    if (projection.stage == .editor) return 0;
    return @intCast(@max(@min(projection.navigationItemCount(), row_budget -| 2), 1));
}

pub fn composeRow(
    alloc: Allocator,
    projection: Projection,
    row_index: u16,
    width: u16,
    row_budget: u16,
) !std.ArrayList(u8) {
    if (!projection.active or width == 0 or row_index >= row_budget) return .empty;
    const manager = projection.state orelse return .empty;
    return switch (projection.stage) {
        .library => composeLibraryRow(alloc, projection, manager, row_index, width, row_budget),
        .actions => composeActionRow(alloc, projection, manager, row_index, width),
        .delete_confirmation => composeDeleteRow(alloc, manager, row_index, width),
        .editor => composeEditorRow(alloc, projection, row_index, width, row_budget),
    };
}

fn composeLibraryRow(
    alloc: Allocator,
    projection: Projection,
    manager: *const definition_manager.State,
    row_index: u16,
    width: u16,
    row_budget: u16,
) !std.ArrayList(u8) {
    if (row_index == 0) {
        var buffer: [96]u8 = undefined;
        const title = std.fmt.bufPrint(
            &buffer,
            "{s} {s}s {d}",
            .{ projection.extension_name, projection.definition_kind, manager.filteredDefinitionCount() },
        ) catch projection.extension_name;
        return styledLine(alloc, title, ui_render.selected_completion_style, width);
    }
    if (row_index == 1) return .empty;

    const navigation_count = manager.navigationItemCount();
    const visible = @max(@min(navigation_count, row_budget -| 2), 1);
    var start = @min(manager.window_start, navigation_count -| visible);
    if (manager.selected < start) start = manager.selected;
    if (manager.selected >= start + visible) start = manager.selected - visible + 1;
    const navigation_index = start + row_index - 2;
    if (navigation_index >= navigation_count) return .empty;
    if (navigation_index == 0) {
        return selectableLine(alloc, "+ New Team", manager.selected == 0, width);
    }
    const item = manager.definitionAt(navigation_index - 1) orelse return .empty;
    var buffer: [512]u8 = undefined;
    const label = std.fmt.bufPrint(
        &buffer,
        "{s}  r{d}  {s}",
        .{ item.name, item.latest_revision, item.id },
    ) catch item.name;
    return selectableLine(alloc, label, manager.selected == navigation_index, width);
}

fn composeActionRow(
    alloc: Allocator,
    projection: Projection,
    manager: *const definition_manager.State,
    row_index: u16,
    width: u16,
) !std.ArrayList(u8) {
    const definition = manager.activeDefinition() orelse return .empty;
    if (row_index == 0) {
        var buffer: [256]u8 = undefined;
        const title = std.fmt.bufPrint(
            &buffer,
            "{s} · {s} r{d}",
            .{ projection.extension_name, definition.name, definition.latest_revision },
        ) catch definition.name;
        return styledLine(alloc, title, ui_render.selected_completion_style, width);
    }
    if (row_index == 1) return styledLine(alloc, definition.id, ui_render.dim_style, width);
    if (row_index == 2) return .empty;
    const labels = [_][]const u8{
        "Start a new conversation",
        "Edit as a new revision",
        "Delete from Team library",
        "Back",
    };
    const action_index = row_index - 3;
    if (action_index >= labels.len) return .empty;
    return selectableLine(alloc, labels[action_index], manager.selected == action_index, width);
}

fn composeDeleteRow(
    alloc: Allocator,
    manager: *const definition_manager.State,
    row_index: u16,
    width: u16,
) !std.ArrayList(u8) {
    const definition = manager.activeDefinition() orelse return .empty;
    if (row_index == 0) return styledLine(alloc, "Delete Team?", ui_render.selected_completion_style, width);
    if (row_index == 1) {
        var buffer: [384]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "{s} will leave the library; existing sessions keep their exact revision.",
            .{definition.name},
        ) catch definition.name;
        return styledLine(alloc, message, ui_render.dim_style, width);
    }
    if (row_index == 2) return .empty;
    const labels = [_][]const u8{ "Delete", "Cancel" };
    const choice_index = row_index - 3;
    if (choice_index >= labels.len) return .empty;
    return selectableLine(alloc, labels[choice_index], manager.selected == choice_index, width);
}

fn composeEditorRow(
    alloc: Allocator,
    projection: Projection,
    row_index: u16,
    width: u16,
    row_budget: u16,
) !std.ArrayList(u8) {
    if (row_index == 0) {
        return styledLine(alloc, projection.editor.title, ui_render.selected_completion_style, width);
    }
    if (row_index == 1) return styledLine(alloc, projection.editor.subtitle, ui_render.dim_style, width);
    const error_rows: u16 = @intFromBool(projection.editor.error_message.len > 0);
    if (error_rows == 1 and row_index == 2) {
        return styledLine(alloc, projection.editor.error_message, ui_render.red_style, width);
    }
    const body_start: u16 = 2 + error_rows;
    if (row_index < body_start) return .empty;
    const body_budget = row_budget -| body_start;
    if (body_budget == 0 or projection.editor.rows.len == 0) return .empty;
    var selected: usize = 0;
    for (projection.editor.rows, 0..) |row, index| if (row.selected) {
        selected = index;
        break;
    };
    const visible = @min(projection.editor.rows.len, body_budget);
    var start: usize = 0;
    if (selected >= visible) start = selected - visible + 1;
    const item_index = start + row_index - body_start;
    if (item_index >= projection.editor.rows.len) return .empty;
    const item = projection.editor.rows[item_index];
    return editorRow(alloc, item, width);
}

pub fn composeHintRow(
    alloc: Allocator,
    projection: Projection,
    width: u16,
) !std.ArrayList(u8) {
    const hint = if (projection.stage == .editor)
        projection.editor.hint
    else
        "↑↓ Navigate  ·  Enter Select  ·  Esc Back";
    return styledLine(alloc, hint, ui_render.dim_style, width);
}

fn editorRow(
    alloc: Allocator,
    item: render_input.DefinitionEditorRow,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const style = if (item.destructive)
        ui_render.red_style
    else if (item.selected)
        ui_render.selected_completion_style
    else
        ui_render.dim_style;
    try row.appendSlice(alloc, style);
    try row.appendSlice(alloc, if (item.selected) "› " else "  ");
    if (item.marked) try row.appendSlice(alloc, "✓ ");
    const prefix_width: u16 = if (item.marked) 4 else 2;
    var label_buffer: [768]u8 = undefined;
    const label = if (item.detail.len == 0)
        item.label
    else
        std.fmt.bufPrint(&label_buffer, "{s}  {s}", .{ item.label, item.detail }) catch item.label;
    try row_text.appendSingleLineEllipsized(alloc, &row, label, width -| prefix_width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn selectableLine(alloc: Allocator, label: []const u8, selected: bool, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row.appendSlice(alloc, if (selected) "› " else "  ");
    try row_text.appendSingleLineEllipsized(alloc, &row, label, width -| 2);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn styledLine(
    alloc: Allocator,
    label: []const u8,
    style: []const u8,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, style);
    try row_text.appendSingleLineEllipsized(alloc, &row, label, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

test "Team library never offers a primary-only preset" {
    const alloc = std.testing.allocator;
    var manager = definition_manager.State{ .active = true };
    defer manager.deinit(alloc);
    const projection = Projection{
        .active = true,
        .state = &manager,
        .definition_kind = "Team",
        .extension_name = "Fixer",
    };
    var row = try composeRow(alloc, projection, 2, 80, 8);
    defer row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, row.items, "+ New Team") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "Minimal") == null);
}
