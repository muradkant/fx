const std = @import("std");
const context_contract = @import("../workspace/context_contract.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");

pub const Capture = struct {
    source_turn_id: u64,
    attachment_references: []const []const u8,
};

const Entry = struct {
    source_turn_id: u64,
    prompt: worker_runtime.QueuedPrompt,
    attachment_references: [][]u8,

    fn deinit(self: *Entry, alloc: std.mem.Allocator) void {
        worker_runtime.freeQueuedPrompt(alloc, self.prompt);
        freeStrings(alloc, self.attachment_references);
        self.* = undefined;
    }
};

/// fx-owned custody for canonical user turns referenced by optional
/// orchestration engines. The extension sees opaque IDs, never secret-bearing
/// queued prompts or attachment paths.
pub const Store = struct {
    entries: std.ArrayList(Entry) = .empty,
    next_source_turn_id: u64 = 1,

    pub fn deinit(self: *Store, alloc: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(alloc);
        self.entries.deinit(alloc);
        self.* = .{};
    }

    /// Consumes `prompt` only after all fallible capture work succeeds.
    pub fn captureOwned(
        self: *Store,
        alloc: std.mem.Allocator,
        prompt: worker_runtime.QueuedPrompt,
    ) !Capture {
        const source_turn_id = self.next_source_turn_id;
        if (source_turn_id == 0 or source_turn_id == std.math.maxInt(u64)) {
            return error.SourceTurnIdExhausted;
        }
        const references = try attachmentReferences(alloc, prompt.images);
        errdefer freeStrings(alloc, references);
        try self.entries.append(alloc, .{
            .source_turn_id = source_turn_id,
            .prompt = prompt,
            .attachment_references = references,
        });
        self.next_source_turn_id = source_turn_id + 1;
        return .{
            .source_turn_id = source_turn_id,
            .attachment_references = references,
        };
    }

    pub fn remove(self: *Store, alloc: std.mem.Allocator, source_turn_id: u64) bool {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.source_turn_id != source_turn_id) continue;
            var removed = self.entries.swapRemove(index);
            removed.deinit(alloc);
            return true;
        }
        return false;
    }

    /// Captures one text-only instruction consumed from fx's native steering
    /// queue. It derives custody from the active root turn while stripping all
    /// model, history, skill, and attachment input that steering did not carry.
    pub fn captureTextInstruction(
        self: *Store,
        alloc: std.mem.Allocator,
        root_source_turn_id: u64,
        text: []const u8,
    ) !Capture {
        const root = self.find(root_source_turn_id) orelse
            return error.UnknownSourceTurn;
        var prompt = try worker_runtime.dupeQueuedPrompt(alloc, root.prompt);
        errdefer worker_runtime.freeQueuedPrompt(alloc, prompt);

        const instruction = try alloc.dupe(u8, text);
        var owns_instruction = true;
        errdefer if (owns_instruction) alloc.free(instruction);
        alloc.free(prompt.prompt);
        prompt.prompt = instruction;
        owns_instruction = false;
        types.freeImageAttachmentSlice(alloc, prompt.images);
        prompt.images = &.{};
        types.freeImageAttachmentSlice(alloc, prompt.authorized_image_catalog);
        prompt.authorized_image_catalog = &.{};
        stripHistoryAndRecovery(alloc, &prompt);
        worker_runtime.freeSkillBindings(alloc, prompt.skill_bindings);
        prompt.skill_bindings = &.{};
        worker_runtime.freeSkillDisplaySpans(alloc, prompt.skill_display_spans);
        prompt.skill_display_spans = &.{};
        prompt.context_snapshot.deinit(alloc);
        prompt.context_snapshot = context_contract.GatheredContextSnapshot{};
        prompt.delivery = .ordinary;
        prompt.executor = .native_agent;
        return self.captureOwned(alloc, prompt);
    }

    pub fn borrow(
        self: *const Store,
        source_turn_id: u64,
    ) ?*const worker_runtime.QueuedPrompt {
        const entry = self.find(source_turn_id) orelse return null;
        return &entry.prompt;
    }

    /// Materializes exactly the canonical current user turn. Conversation
    /// history is intentionally absent: Fixer owns its session projection.
    pub fn cloneCanonical(
        self: *const Store,
        alloc: std.mem.Allocator,
        source_turn_id: u64,
        instruction_source_turn_ids: []const u64,
    ) !worker_runtime.QueuedPrompt {
        const entry = self.find(source_turn_id) orelse return error.UnknownSourceTurn;
        var result = try worker_runtime.dupeQueuedPrompt(alloc, entry.prompt);
        errdefer worker_runtime.freeQueuedPrompt(alloc, result);
        const combined_text = try self.combinedPromptText(
            alloc,
            source_turn_id,
            instruction_source_turn_ids,
        );
        errdefer alloc.free(combined_text);
        const combined_images = try self.combinedImages(
            alloc,
            source_turn_id,
            instruction_source_turn_ids,
        );
        errdefer types.freeImageAttachmentSlice(alloc, combined_images);
        const combined_authorized = try types.dupeImageAttachmentSlice(
            alloc,
            combined_images,
        );
        errdefer types.freeImageAttachmentSlice(alloc, combined_authorized);
        alloc.free(result.prompt);
        result.prompt = combined_text;
        types.freeImageAttachmentSlice(alloc, result.images);
        result.images = combined_images;
        types.freeImageAttachmentSlice(alloc, result.authorized_image_catalog);
        result.authorized_image_catalog = combined_authorized;
        stripHistoryAndRecovery(alloc, &result);
        return result;
    }

    /// Materializes stateless specialist input. Only caller-authored content
    /// and an authority-checked subset of current-turn images survive.
    pub fn cloneProjected(
        self: *const Store,
        alloc: std.mem.Allocator,
        source_turn_id: u64,
        instruction_source_turn_ids: []const u64,
        content: []const u8,
        attachment_references: []const []const u8,
    ) !worker_runtime.QueuedPrompt {
        const entry = self.find(source_turn_id) orelse return error.UnknownSourceTurn;
        try self.validateInstructionSources(source_turn_id, instruction_source_turn_ids);
        try validateUniqueReferences(attachment_references);
        var result = try worker_runtime.dupeQueuedPrompt(alloc, entry.prompt);
        errdefer worker_runtime.freeQueuedPrompt(alloc, result);

        // Prepare the complete replacement before releasing any field owned by
        // the cloned canonical prompt. A projection error must leave `result`
        // valid for its aggregate errdefer rather than pointing at freed
        // prompt or attachment storage.
        const projected_prompt = try alloc.dupe(u8, content);
        errdefer alloc.free(projected_prompt);
        const projected_images = try self.selectAuthorizedAttachments(
            alloc,
            source_turn_id,
            instruction_source_turn_ids,
            attachment_references,
        );
        errdefer types.freeImageAttachmentSlice(alloc, projected_images);
        const projected_authorized = try types.dupeImageAttachmentSlice(
            alloc,
            projected_images,
        );
        errdefer types.freeImageAttachmentSlice(alloc, projected_authorized);

        alloc.free(result.prompt);
        result.prompt = projected_prompt;
        types.freeImageAttachmentSlice(alloc, result.images);
        result.images = projected_images;
        types.freeImageAttachmentSlice(alloc, result.authorized_image_catalog);
        result.authorized_image_catalog = projected_authorized;
        stripHistoryAndRecovery(alloc, &result);
        worker_runtime.freeSkillBindings(alloc, result.skill_bindings);
        result.skill_bindings = &.{};
        worker_runtime.freeSkillDisplaySpans(alloc, result.skill_display_spans);
        result.skill_display_spans = &.{};
        result.context_snapshot.deinit(alloc);
        result.context_snapshot = context_contract.GatheredContextSnapshot{};
        return result;
    }

    /// Builds the one durable fx user record for a Fixer session. Instructions
    /// remain separate canonical custody entries while the turn is active, but
    /// persistence records their ordered semantic combination after terminal
    /// completion, failure, or cancellation.
    pub fn cloneCombinedUserTurn(
        self: *const Store,
        alloc: std.mem.Allocator,
        source_turn_id: u64,
        instruction_source_turn_ids: []const u64,
    ) !types.UserTurn {
        const text = try self.combinedPromptText(
            alloc,
            source_turn_id,
            instruction_source_turn_ids,
        );
        errdefer alloc.free(text);
        const images = try self.combinedImages(
            alloc,
            source_turn_id,
            instruction_source_turn_ids,
        );
        return .{ .text = text, .images = images };
    }

    fn combinedPromptText(
        self: *const Store,
        alloc: std.mem.Allocator,
        source_turn_id: u64,
        instruction_source_turn_ids: []const u64,
    ) ![]u8 {
        const root = self.find(source_turn_id) orelse return error.UnknownSourceTurn;
        try self.validateInstructionSources(source_turn_id, instruction_source_turn_ids);
        if (instruction_source_turn_ids.len == 0) {
            return alloc.dupe(u8, root.prompt.prompt);
        }
        var output: std.Io.Writer.Allocating = .init(alloc);
        errdefer output.deinit();
        try output.writer.writeAll(root.prompt.prompt);
        for (instruction_source_turn_ids, 1..) |instruction_id, ordinal| {
            const instruction = self.find(instruction_id) orelse
                return error.UnknownInstructionSourceTurn;
            try output.writer.print(
                "\n\n<in-session-user-instruction ordinal=\"{d}\">\n{s}\n</in-session-user-instruction>",
                .{ ordinal, instruction.prompt.prompt },
            );
        }
        return output.toOwnedSlice();
    }

    fn combinedImages(
        self: *const Store,
        alloc: std.mem.Allocator,
        source_turn_id: u64,
        instruction_source_turn_ids: []const u64,
    ) ![]types.ImageAttachment {
        const root = self.find(source_turn_id) orelse return error.UnknownSourceTurn;
        try self.validateInstructionSources(source_turn_id, instruction_source_turn_ids);
        var images: std.ArrayList(types.ImageAttachment) = .empty;
        errdefer {
            for (images.items) |image| types.freeImageAttachment(alloc, image);
            images.deinit(alloc);
        }
        try appendUniqueImages(alloc, &images, root.prompt.images);
        for (instruction_source_turn_ids) |instruction_id| {
            const instruction = self.find(instruction_id) orelse
                return error.UnknownInstructionSourceTurn;
            try appendUniqueImages(alloc, &images, instruction.prompt.images);
        }
        return images.toOwnedSlice(alloc);
    }

    fn selectAuthorizedAttachments(
        self: *const Store,
        alloc: std.mem.Allocator,
        source_turn_id: u64,
        instruction_source_turn_ids: []const u64,
        references: []const []const u8,
    ) ![]types.ImageAttachment {
        if (references.len == 0) return &.{};
        const selected = try alloc.alloc(types.ImageAttachment, references.len);
        var count: usize = 0;
        errdefer {
            for (selected[0..count]) |image| types.freeImageAttachment(alloc, image);
            alloc.free(selected);
        }
        for (references) |reference| {
            const id = try parseAttachmentReference(reference);
            const image = self.findAuthorizedImage(
                source_turn_id,
                instruction_source_turn_ids,
                id,
            ) orelse return error.AttachmentNotAuthorized;
            const copy = try types.dupeImageAttachmentSlice(alloc, &.{image});
            selected[count] = copy[0];
            alloc.free(copy);
            count += 1;
        }
        return selected;
    }

    fn findAuthorizedImage(
        self: *const Store,
        source_turn_id: u64,
        instruction_source_turn_ids: []const u64,
        id: usize,
    ) ?types.ImageAttachment {
        const root = self.find(source_turn_id) orelse return null;
        if (findImage(root.prompt.images, id)) |image| return image;
        for (instruction_source_turn_ids) |instruction_id| {
            const instruction = self.find(instruction_id) orelse return null;
            if (findImage(instruction.prompt.images, id)) |image| return image;
        }
        return null;
    }

    fn validateInstructionSources(
        self: *const Store,
        source_turn_id: u64,
        instruction_source_turn_ids: []const u64,
    ) !void {
        for (instruction_source_turn_ids, 0..) |instruction_id, index| {
            if (instruction_id == 0 or instruction_id == source_turn_id) {
                return error.InvalidInstructionSourceTurn;
            }
            if (self.find(instruction_id) == null) return error.UnknownInstructionSourceTurn;
            for (instruction_source_turn_ids[0..index]) |prior| {
                if (prior == instruction_id) return error.DuplicateInstructionSourceTurn;
            }
        }
    }

    fn find(self: *const Store, source_turn_id: u64) ?*const Entry {
        for (self.entries.items) |*entry| {
            if (entry.source_turn_id == source_turn_id) return entry;
        }
        return null;
    }
};

fn appendUniqueImages(
    alloc: std.mem.Allocator,
    destination: *std.ArrayList(types.ImageAttachment),
    source: []const types.ImageAttachment,
) !void {
    for (source) |image| {
        var duplicate = false;
        for (destination.items) |existing| {
            if (existing.id == image.id) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        const copy = try types.dupeImageAttachmentSlice(alloc, &.{image});
        errdefer {
            types.freeImageAttachment(alloc, copy[0]);
            alloc.free(copy);
        }
        try destination.append(alloc, copy[0]);
        alloc.free(copy);
    }
}

fn stripHistoryAndRecovery(
    alloc: std.mem.Allocator,
    prompt: *worker_runtime.QueuedPrompt,
) void {
    types.freeHistoryTurnSlice(alloc, prompt.history);
    prompt.history = &.{};
    if (prompt.recovery_checkpoint) |checkpoint| {
        var owned = checkpoint;
        owned.deinit(alloc);
        prompt.recovery_checkpoint = null;
    }
    prompt.recovery_source_already_presented = false;
    prompt.turn_id = 0;
}

fn attachmentReferences(
    alloc: std.mem.Allocator,
    images: []const types.ImageAttachment,
) ![][]u8 {
    const references = try alloc.alloc([]u8, images.len);
    var count: usize = 0;
    errdefer {
        for (references[0..count]) |reference| alloc.free(reference);
        alloc.free(references);
    }
    while (count < images.len) : (count += 1) {
        if (images[count].id == 0) return error.InvalidAttachmentIdentity;
        references[count] = try std.fmt.allocPrint(
            alloc,
            "image:{d}",
            .{images[count].id},
        );
    }
    return references;
}

fn selectAttachments(
    alloc: std.mem.Allocator,
    images: []const types.ImageAttachment,
    references: []const []const u8,
) ![]types.ImageAttachment {
    if (references.len == 0) return &.{};
    const selected = try alloc.alloc(types.ImageAttachment, references.len);
    var count: usize = 0;
    errdefer {
        for (selected[0..count]) |image| types.freeImageAttachment(alloc, image);
        alloc.free(selected);
    }
    for (references) |reference| {
        const id = try parseAttachmentReference(reference);
        const image = findImage(images, id) orelse return error.AttachmentNotAuthorized;
        const copy = try types.dupeImageAttachmentSlice(alloc, &.{image});
        selected[count] = copy[0];
        alloc.free(copy);
        count += 1;
    }
    return selected;
}

fn validateUniqueReferences(references: []const []const u8) !void {
    for (references, 0..) |reference, index| {
        _ = try parseAttachmentReference(reference);
        for (references[0..index]) |prior| {
            if (std.mem.eql(u8, prior, reference)) return error.DuplicateAttachmentReference;
        }
    }
}

fn parseAttachmentReference(reference: []const u8) !usize {
    const prefix = "image:";
    if (!std.mem.startsWith(u8, reference, prefix)) return error.InvalidAttachmentReference;
    const suffix = reference[prefix.len..];
    if (suffix.len == 0) return error.InvalidAttachmentReference;
    const id = std.fmt.parseUnsigned(usize, suffix, 10) catch
        return error.InvalidAttachmentReference;
    if (id == 0) return error.InvalidAttachmentReference;
    return id;
}

fn findImage(images: []const types.ImageAttachment, id: usize) ?types.ImageAttachment {
    for (images) |image| if (image.id == id) return image;
    return null;
}

fn freeStrings(alloc: std.mem.Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn fixturePrompt(alloc: std.mem.Allocator) !worker_runtime.QueuedPrompt {
    return fixturePromptWithImageBase(alloc, "ORIGINAL USER SENTINEL", 1);
}

fn fixturePromptWithImageBase(
    alloc: std.mem.Allocator,
    prompt_text: []const u8,
    image_base: usize,
) !worker_runtime.QueuedPrompt {
    const images = try alloc.alloc(types.ImageAttachment, 2);
    var image_count: usize = 0;
    errdefer {
        for (images[0..image_count]) |image| types.freeImageAttachment(alloc, image);
        alloc.free(images);
    }
    while (image_count < images.len) : (image_count += 1) {
        const path = try std.fmt.allocPrint(
            alloc,
            "/workspace/{d}.png",
            .{image_base + image_count},
        );
        errdefer alloc.free(path);
        const media_type = try alloc.dupe(u8, "image/png");
        images[image_count] = .{
            .id = image_base + image_count,
            .path = path,
            .media_type = media_type,
        };
    }
    const authorized = try types.dupeImageAttachmentSlice(alloc, images);
    errdefer types.freeImageAttachmentSlice(alloc, authorized);
    const bindings = try alloc.alloc(worker_runtime.SkillBinding, 1);
    errdefer alloc.free(bindings);
    const binding_name = try alloc.dupe(u8, "canonical-skill");
    errdefer alloc.free(binding_name);
    const binding_path = try alloc.dupe(u8, "/skills/canonical");
    errdefer alloc.free(binding_path);
    bindings[0] = .{
        .name = binding_name,
        .path = binding_path,
    };
    return .{
        .prompt = try alloc.dupe(u8, prompt_text),
        .images = images,
        .authorized_image_catalog = authorized,
        .model = try alloc.dupe(u8, "go/kimi-k3"),
        .provider = .opencode,
        .api_key = try alloc.dupe(u8, "secret"),
        .permission_mode = .auto,
        .history = try alloc.alloc(types.HistoryTurn, 0),
        .grants = try alloc.alloc(types.PermissionGrant, 0),
        .skill_bindings = bindings,
    };
}

test "canonical steering preserves ordered user input and authorizes instruction attachments" {
    const alloc = std.testing.allocator;
    var store = Store{};
    defer store.deinit(alloc);
    const root = try store.captureOwned(
        alloc,
        try fixturePromptWithImageBase(alloc, "ROOT TASK", 1),
    );
    const instruction = try store.captureOwned(
        alloc,
        try fixturePromptWithImageBase(alloc, "STEERING INSTRUCTION", 101),
    );

    const canonical = try store.cloneCanonical(
        alloc,
        root.source_turn_id,
        &.{instruction.source_turn_id},
    );
    defer worker_runtime.freeQueuedPrompt(alloc, canonical);
    try std.testing.expect(std.mem.indexOf(u8, canonical.prompt, "ROOT TASK") != null);
    try std.testing.expect(std.mem.indexOf(u8, canonical.prompt, "STEERING INSTRUCTION") != null);
    try std.testing.expectEqual(@as(usize, 4), canonical.images.len);

    const projected = try store.cloneProjected(
        alloc,
        root.source_turn_id,
        &.{instruction.source_turn_id},
        "inspect the new image",
        &.{"image:102"},
    );
    defer worker_runtime.freeQueuedPrompt(alloc, projected);
    try std.testing.expectEqual(@as(usize, 1), projected.images.len);
    try std.testing.expectEqual(@as(usize, 102), projected.images[0].id);
    try std.testing.expectError(
        error.AttachmentNotAuthorized,
        store.cloneProjected(
            alloc,
            root.source_turn_id,
            &.{instruction.source_turn_id},
            "fabricated authority",
            &.{"image:999"},
        ),
    );

    const durable = try store.cloneCombinedUserTurn(
        alloc,
        root.source_turn_id,
        &.{instruction.source_turn_id},
    );
    defer types.freeUserTurn(alloc, durable);
    try std.testing.expect(std.mem.indexOf(u8, durable.text, "ROOT TASK") != null);
    try std.testing.expect(std.mem.indexOf(u8, durable.text, "STEERING INSTRUCTION") != null);
    try std.testing.expectEqual(@as(usize, 4), durable.images.len);
}

test "canonical custody projects specialists without prompt skill or attachment escalation" {
    const alloc = std.testing.allocator;
    var store = Store{};
    defer store.deinit(alloc);
    const owned = try fixturePrompt(alloc);
    const captured = try store.captureOwned(alloc, owned);
    try std.testing.expectEqual(@as(u64, 1), captured.source_turn_id);
    try std.testing.expectEqualStrings("image:1", captured.attachment_references[0]);

    const canonical = try store.cloneCanonical(alloc, captured.source_turn_id, &.{});
    defer worker_runtime.freeQueuedPrompt(alloc, canonical);
    try std.testing.expectEqualStrings("ORIGINAL USER SENTINEL", canonical.prompt);
    try std.testing.expectEqual(@as(usize, 2), canonical.images.len);
    try std.testing.expectEqual(@as(usize, 1), canonical.skill_bindings.len);

    const projected = try store.cloneProjected(
        alloc,
        captured.source_turn_id,
        &.{},
        "inspect only the selected image",
        &.{"image:2"},
    );
    defer worker_runtime.freeQueuedPrompt(alloc, projected);
    try std.testing.expectEqualStrings("inspect only the selected image", projected.prompt);
    try std.testing.expect(std.mem.indexOf(u8, projected.prompt, "ORIGINAL USER SENTINEL") == null);
    try std.testing.expectEqual(@as(usize, 1), projected.images.len);
    try std.testing.expectEqual(@as(usize, 2), projected.images[0].id);
    try std.testing.expectEqual(@as(usize, 0), projected.skill_bindings.len);
    try std.testing.expectError(
        error.AttachmentNotAuthorized,
        store.cloneProjected(
            alloc,
            captured.source_turn_id,
            &.{},
            "escalate",
            &.{"image:999"},
        ),
    );
}
