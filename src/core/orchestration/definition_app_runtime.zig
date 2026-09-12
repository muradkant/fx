const std = @import("std");
const io_mod = @import("../shared/io.zig");
const paste_blocks = @import("../input/pasted_blocks.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const credentials = @import("../auth/credentials.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_runtime = @import("../app/provider_runtime.zig");
const app_session_runtime = @import("../app/app_session_runtime.zig");
const orchestration_app_runtime = @import("app_runtime.zig");
const revision_store = @import("revision_store.zig");

fn generateDefinitionId(
    allocator: std.mem.Allocator,
    definition_kind: []const u8,
) ![]u8 {
    var random_bytes: [12]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
    return std.fmt.allocPrint(
        allocator,
        "{s}-{s}",
        .{ definition_kind, random_hex },
    );
}

fn generateDefinitionEditorIdentitySeed() [32]u8 {
    var seed: [32]u8 = undefined;
    io_mod.getIo().random(&seed);
    return seed;
}

/// Owns the interactive definition-library and session-binding workflow. The
/// composition root exposes narrow callbacks while this runtime keeps Team
/// management out of `main.zig` and independent of Fixer's document schema.
pub fn Runtime(
    comptime Host: type,
    comptime Extension: type,
    comptime Editor: type,
    comptime App: type,
) type {
    return struct {
        const SessionRuntime = app_session_runtime.Runtime(App);

        pub fn handleCommand(app: *App, payload: []const u8) !void {
            const trimmed = std.mem.trim(u8, payload, " \t\r\n");
            if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "on")) {
                try resumeLatestSession(app);
                return;
            }
            if (std.ascii.eqlIgnoreCase(trimmed, "off")) {
                try leaveForNativeSession(app);
                return;
            }
            if (std.ascii.eqlIgnoreCase(trimmed, "teams") or
                std.ascii.eqlIgnoreCase(trimmed, "team") or
                std.ascii.eqlIgnoreCase(trimmed, "manage"))
            {
                try openManager(app);
                return;
            }
            if (std.ascii.eqlIgnoreCase(trimmed, "new")) {
                try openManager(app);
                try beginNewDefinition(app);
                return;
            }
            try app.writeDomainNotice(.{
                .topic = Extension.descriptor().id,
                .tone = .@"error",
                .body = Extension.descriptor().usage,
            }, true);
        }

        pub fn moveManager(app: *App, delta: i32) bool {
            if (!app.orchestration_definition_manager.active) return false;
            if (app.orchestration_definition_manager.stage == .editor) {
                if (app.orchestration_definition_editor) |*editor| {
                    const moved = editor.move(delta);
                    if (moved) app.shell.render_requests.request(.footer);
                    return moved;
                }
                return false;
            }
            const moved = app.orchestration_definition_manager.move(delta, 8);
            if (moved) app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn syncManagerQuery(app: *App) void {
            if (!app.orchestration_definition_manager.active or
                app.orchestration_definition_manager.stage != .library) return;
            app.orchestration_definition_manager.setQuery(
                app.input_runtime.edit_state.input.items,
            );
        }

        pub fn cancelManager(app: *App) bool {
            if (!app.orchestration_definition_manager.active) return false;
            if (app.orchestration_definition_manager.stage == .editor) {
                if (app.orchestration_definition_editor) |*editor| {
                    switch (editor.back()) {
                        .exit => {
                            editor.deinit();
                            app.orchestration_definition_editor = null;
                            _ = app.orchestration_definition_manager.back();
                        },
                        .replace_input => |text| app.input_runtime.textReplacementState().replace(
                            app.alloc,
                            text,
                        ) catch {},
                        .choose_model => {},
                        .redraw => {},
                        .save => |source| app.alloc.free(source),
                    }
                    app.shell.render_requests.request(.footer);
                    return true;
                }
            }
            if (app.orchestration_definition_manager.back()) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
            } else {
                app.orchestration_definition_manager.close(app.alloc);
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
            }
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn submitManager(app: *App) !bool {
            var manager = &app.orchestration_definition_manager;
            if (!manager.active) return false;
            switch (manager.stage) {
                .library => {
                    const choice = manager.selectLibrary() orelse return true;
                    switch (choice) {
                        .create => try beginNewDefinition(app),
                        .definition => {},
                    }
                },
                .actions => switch (manager.selectedAction() orelse return true) {
                    .start => try startSelectedDefinition(app),
                    .edit => try beginEditingDefinition(app),
                    .delete => manager.enterDeleteConfirmation(),
                    .back => {
                        _ = manager.back();
                        app.input_runtime.inputResetState().clearCurrent(app.alloc);
                    },
                },
                .delete_confirmation => {
                    if (manager.confirmDeleteSelected()) {
                        try deleteSelectedDefinition(app);
                    } else {
                        _ = manager.back();
                    }
                },
                .editor => try submitEditor(app),
            }
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn restoreForSession(app: *App, session_id: []const u8) !void {
            orchestration_app_runtime.deinit(Host, app.alloc, &app.orchestration);
            const session_store = app.session_persistence.store orelse
                return error.SessionStoreUnavailable;
            var binding = (try session_store.readOrchestrationBinding(
                app.alloc,
                session_id,
            )) orelse return;
            defer binding.deinit(app.alloc);

            const descriptor = Extension.descriptor();
            if (!std.mem.eql(u8, binding.extension_id, descriptor.id) or
                !std.mem.eql(u8, binding.definition_kind, descriptor.definition_kind))
            {
                return error.OrchestrationExtensionUnavailable;
            }
            const home = io_mod.getenv("HOME") orelse return error.HomeUnavailable;
            var definitions = try revision_store.Store.initFromHome(
                home,
                descriptor.id,
                descriptor.definition_collection,
            );
            defer definitions.deinit();
            var definition = try definitions.load(app.alloc, .{
                .id = binding.definition_id,
                .revision = binding.definition_revision,
                .digest = binding.definition_digest,
            });
            defer definition.deinit(app.alloc);
            var metadata = try Extension.inspectDefinition(app.alloc, definition.source);
            defer metadata.deinit(app.alloc);
            if (!std.mem.eql(u8, metadata.id, binding.definition_id) or
                metadata.revision != binding.definition_revision or
                !std.mem.eql(u8, &metadata.digest, &binding.definition_digest) or
                !std.mem.eql(u8, metadata.name, binding.display_name))
            {
                return error.OrchestrationBindingMismatch;
            }
            try orchestration_app_runtime.installDefinition(
                Host,
                Extension,
                app.alloc,
                &app.orchestration,
                definition.source,
            );
            try orchestration_app_runtime.handlePayload(Host, Extension, app, "on");
        }

        pub fn startNewSession(
            app: *App,
            definition_source: []const u8,
            persist_revision: bool,
        ) !void {
            if (app.stream.active or app.worker.isProcessing()) {
                return error.SessionTransitionBusy;
            }
            const descriptor = Extension.descriptor();
            var metadata = try Extension.inspectDefinition(app.alloc, definition_source);
            defer metadata.deinit(app.alloc);
            const home = io_mod.getenv("HOME") orelse return error.HomeUnavailable;
            var definitions = try revision_store.Store.initFromHome(
                home,
                descriptor.id,
                descriptor.definition_collection,
            );
            defer definitions.deinit();
            if (persist_revision) {
                try definitions.put(app.alloc, .{
                    .ref = .{
                        .id = metadata.id,
                        .revision = metadata.revision,
                        .digest = metadata.digest,
                    },
                    .name = metadata.name,
                    .source = definition_source,
                });
            } else {
                var pinned = try definitions.load(app.alloc, .{
                    .id = metadata.id,
                    .revision = metadata.revision,
                    .digest = metadata.digest,
                });
                defer pinned.deinit(app.alloc);
                if (!std.mem.eql(u8, pinned.source, definition_source)) {
                    return error.OrchestrationBindingMismatch;
                }
            }

            orchestration_app_runtime.deinit(Host, app.alloc, &app.orchestration);
            try app.newSession();
            const session_id = SessionRuntime.activeSessionId(app) orelse
                return error.SessionStoreUnavailable;
            const session_store = app.session_persistence.store orelse
                return error.SessionStoreUnavailable;
            try session_store.writeOrchestrationBinding(app.alloc, session_id, .{
                .extension_id = descriptor.id,
                .extension_name = descriptor.display_name,
                .definition_kind = descriptor.definition_kind,
                .definition_id = metadata.id,
                .definition_revision = metadata.revision,
                .definition_digest = metadata.digest,
                .display_name = metadata.name,
            });
            try orchestration_app_runtime.installDefinition(
                Host,
                Extension,
                app.alloc,
                &app.orchestration,
                definition_source,
            );
            try orchestration_app_runtime.handlePayload(Host, Extension, app, "on");
        }

        fn openManager(app: *App) !void {
            if (app.stream.active or app.worker.isProcessing()) {
                return error.SessionTransitionBusy;
            }
            const descriptor = Extension.descriptor();
            const home = io_mod.getenv("HOME") orelse return error.HomeUnavailable;
            var store = try revision_store.Store.initFromHome(
                home,
                descriptor.id,
                descriptor.definition_collection,
            );
            defer store.deinit();
            const library = try store.list(app.alloc, false);
            if (app.orchestration_definition_editor) |*editor| editor.deinit();
            app.orchestration_definition_editor = null;
            app.orchestration_definition_manager.open(app.alloc, library);
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.shell.render_requests.request(.footer);
        }

        fn beginNewDefinition(app: *App) !void {
            const descriptor = Extension.descriptor();
            const definition_id = try generateDefinitionId(app.alloc, descriptor.definition_kind);
            defer app.alloc.free(definition_id);
            const template = try Extension.newDefinitionTemplate(app.alloc, definition_id);
            defer app.alloc.free(template);
            app.orchestration_definition_manager.enterCreateEditor(app.alloc);
            if (app.orchestration_definition_editor) |*editor| editor.deinit();
            app.orchestration_definition_editor = try Editor.init(
                app.alloc,
                template,
                generateDefinitionEditorIdentitySeed(),
                true,
            );
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
        }

        fn beginEditingDefinition(app: *App) !void {
            const summary = app.orchestration_definition_manager.activeDefinition() orelse
                return error.DefinitionNotSelected;
            const descriptor = Extension.descriptor();
            const home = io_mod.getenv("HOME") orelse return error.HomeUnavailable;
            var store = try revision_store.Store.initFromHome(
                home,
                descriptor.id,
                descriptor.definition_collection,
            );
            defer store.deinit();
            var loaded = try store.load(app.alloc, .{
                .id = summary.id,
                .revision = summary.latest_revision,
                .digest = summary.latest_digest,
            });
            defer loaded.deinit(app.alloc);
            const revised = try Extension.nextDefinitionRevision(app.alloc, loaded.source);
            defer app.alloc.free(revised);
            try app.orchestration_definition_manager.enterReviseEditor(app.alloc);
            if (app.orchestration_definition_editor) |*editor| editor.deinit();
            app.orchestration_definition_editor = try Editor.init(
                app.alloc,
                revised,
                generateDefinitionEditorIdentitySeed(),
                false,
            );
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
        }

        fn startSelectedDefinition(app: *App) !void {
            const summary = app.orchestration_definition_manager.activeDefinition() orelse
                return error.DefinitionNotSelected;
            const descriptor = Extension.descriptor();
            const home = io_mod.getenv("HOME") orelse return error.HomeUnavailable;
            var store = try revision_store.Store.initFromHome(
                home,
                descriptor.id,
                descriptor.definition_collection,
            );
            defer store.deinit();
            var loaded = try store.load(app.alloc, .{
                .id = summary.id,
                .revision = summary.latest_revision,
                .digest = summary.latest_digest,
            });
            defer loaded.deinit(app.alloc);
            try startNewSession(app, loaded.source, false);
            app.orchestration_definition_manager.close(app.alloc);
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
        }

        fn submitEditor(app: *App) !void {
            const editor = if (app.orchestration_definition_editor) |*value|
                value
            else
                return error.DefinitionEditorUnavailable;
            const outcome = try editor.submit(
                app.alloc,
                app.input_runtime.edit_state.input.items,
            );
            switch (outcome) {
                .redraw => {},
                .replace_input => |text| try app.input_runtime.textReplacementState().replace(
                    app.alloc,
                    text,
                ),
                .choose_model => |provider_id| {
                    _ = try openDefinitionModelPicker(app, provider_id);
                },
                .exit => {
                    editor.deinit();
                    app.orchestration_definition_editor = null;
                    _ = app.orchestration_definition_manager.back();
                    app.input_runtime.inputResetState().clearCurrent(app.alloc);
                },
                .save => |source| {
                    defer app.alloc.free(source);
                    var metadata = try Extension.inspectDefinition(app.alloc, source);
                    defer metadata.deinit(app.alloc);
                    switch (app.orchestration_definition_manager.editor_mode) {
                        .create => if (metadata.revision != 1) {
                            return error.InvalidInitialDefinitionRevision;
                        },
                        .revise => |edit| if (!std.mem.eql(u8, metadata.id, edit.id) or
                            metadata.revision != edit.previous_revision + 1)
                        {
                            return error.InvalidDefinitionRevision;
                        },
                    }
                    try startNewSession(app, source, true);
                    editor.deinit();
                    app.orchestration_definition_editor = null;
                    app.orchestration_definition_manager.close(app.alloc);
                    app.input_runtime.inputResetState().clearCurrent(app.alloc);
                },
            }
        }

        fn openDefinitionModelPicker(app: *App, provider_id: []const u8) !bool {
            const provider = provider_catalog.parse(provider_id) orelse
                return error.UnknownOrchestrationProvider;
            if (provider_catalog.find(provider).catalog_scope != .unified) {
                return error.OrchestrationProviderNotUnified;
            }
            if (provider_runtime.provider(app) == provider) {
                app.ensureModelCache();
            } else {
                try app.flushBeforeBlockingExternalWork();
                const resolution = credentials.resolveForProvider(
                    app.alloc,
                    app.auth.oauthTransport(),
                    app.auth.secretStore(),
                    .refresh_if_needed,
                    provider,
                    null,
                ) catch {
                    try app.writeDomainNotice(.{
                        .topic = "model",
                        .tone = .@"error",
                        .body = "Could not load credentials for that Team provider.",
                    }, true);
                    return false;
                };
                var credential = resolution.credential orelse {
                    app.auth.openPickerForProvider(app.alloc, provider);
                    app.shell.render_requests.request(.footer);
                    return false;
                };
                defer credential.deinit(app.alloc);
                const access = credentials.catalogAccessForCredentialAndAccount(
                    credential.source,
                    credential.token,
                    credential.gatewayTeam(),
                    credential.accountId(),
                );
                const fetched = app.fetchProviderCatalog(provider, access) catch {
                    try app.writeDomainNotice(.{
                        .topic = "model",
                        .tone = .@"error",
                        .body = "Could not load that Team provider's model catalog.",
                    }, true);
                    return false;
                };
                var catalog = switch (fetched) {
                    .catalog => |value| value,
                    .failure => {
                        try app.writeDomainNotice(.{
                            .topic = "model",
                            .tone = .@"error",
                            .body = "That Team provider's model catalog could not be validated.",
                        }, true);
                        return false;
                    },
                };
                defer model_catalog.freeModelCatalog(app.alloc, &catalog);
                app.model_cache.adoptOwnedCatalog(access, &catalog);
            }
            try app.model_cache.openMenu();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn deleteSelectedDefinition(app: *App) !void {
            const summary = app.orchestration_definition_manager.activeDefinition() orelse
                return error.DefinitionNotSelected;
            const descriptor = Extension.descriptor();
            const home = io_mod.getenv("HOME") orelse return error.HomeUnavailable;
            var store = try revision_store.Store.initFromHome(
                home,
                descriptor.id,
                descriptor.definition_collection,
            );
            defer store.deinit();
            const name = try app.alloc.dupe(u8, summary.name);
            defer app.alloc.free(name);
            try store.delete(app.alloc, summary.id);
            const library = try store.list(app.alloc, false);
            app.orchestration_definition_manager.open(app.alloc, library);
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            const notice = try std.fmt.allocPrint(
                app.alloc,
                "{s} was removed from the Team library. Existing sessions remain resumable.",
                .{name},
            );
            defer app.alloc.free(notice);
            try app.writeDomainNotice(.{
                .topic = descriptor.id,
                .tone = .neutral,
                .body = notice,
            }, true);
        }

        fn resumeLatestSession(app: *App) !void {
            const store = app.session_persistence.store orelse
                return error.SessionStoreUnavailable;
            const descriptor = Extension.descriptor();
            var latest = (try store.latestOrchestrationSession(
                app.alloc,
                descriptor.id,
            )) orelse {
                try openManager(app);
                return;
            };
            defer latest.deinit(app.alloc);
            if (SessionRuntime.activeSessionId(app)) |id| {
                if (std.mem.eql(u8, id, latest.id) and app.orchestration.active) {
                    try orchestration_app_runtime.handlePayload(Host, Extension, app, "on");
                    return;
                }
            }
            try SessionRuntime.resumeSessionById(app, latest.id);
        }

        fn leaveForNativeSession(app: *App) !void {
            const descriptor = Extension.descriptor();
            if (!app.orchestration.active) {
                try app.writeDomainNotice(.{
                    .topic = descriptor.id,
                    .tone = .neutral,
                    .body = "Fixer mode is already disabled.",
                }, true);
                return;
            }
            try orchestration_app_runtime.handlePayload(Host, Extension, app, "off");
            const store = app.session_persistence.store orelse
                return error.SessionStoreUnavailable;
            const active_id = SessionRuntime.activeSessionId(app);
            const native_id = try store.latestNativeSession(app.alloc, active_id);
            defer if (native_id) |id| app.alloc.free(id);
            if (native_id) |id| {
                try SessionRuntime.resumeSessionById(app, id);
                try app.writeDomainNotice(.{
                    .topic = descriptor.id,
                    .tone = .neutral,
                    .body = "Fixer mode disabled.",
                }, true);
                return;
            }
            orchestration_app_runtime.deinit(Host, app.alloc, &app.orchestration);
            try app.newSession();
            try app.writeDomainNotice(.{
                .topic = descriptor.id,
                .tone = .neutral,
                .body = "Returned to a new native fx session.",
            }, true);
        }
    };
}

test "definition identities are opaque random host values" {
    const alloc = std.testing.allocator;
    const first = try generateDefinitionId(alloc, "team");
    defer alloc.free(first);
    const second = try generateDefinitionId(alloc, "team");
    defer alloc.free(second);
    try std.testing.expect(std.mem.startsWith(u8, first, "team-"));
    try std.testing.expectEqual(@as(usize, "team-".len + 24), first.len);
    try std.testing.expect(!std.mem.eql(u8, first, second));

    const first_seed = generateDefinitionEditorIdentitySeed();
    const second_seed = generateDefinitionEditorIdentitySeed();
    try std.testing.expect(!std.mem.eql(u8, &first_seed, &second_seed));
}
