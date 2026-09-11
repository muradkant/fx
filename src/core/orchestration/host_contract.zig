const std = @import("std");
const editor_contract = @import("editor_contract.zig");

pub const api_version: u16 = 13;
pub const AgentRunFailureKind = enum {
    interrupted,
    authentication,
    forbidden,
    invalid_request,
    request_too_large,
    rate_limited,
    provider_unavailable,
    provider_error,
    runtime,
};

pub const ExtensionDescriptor = struct {
    api_version: u16 = api_version,
    id: []const u8,
    display_name: []const u8,
    slash_command: []const u8,
    summary: []const u8,
    usage: []const u8,
    definition_kind: []const u8,
    definition_collection: []const u8,
};

pub const DefinitionMetadata = struct {
    id: []u8,
    revision: u32,
    digest: [64]u8,
    name: []u8,
    /// Optional extension-owned identity for the active footer. The host does
    /// not interpret these values; it only substitutes them for its dormant
    /// native permission/model identity while orchestration is active.
    entry_role_label: ?[]u8 = null,
    entry_model_label: ?[]u8 = null,

    pub fn deinit(self: *DefinitionMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.entry_role_label) |label| allocator.free(label);
        if (self.entry_model_label) |label| allocator.free(label);
        self.* = undefined;
    }
};

pub const CreateOptions = struct {
    definition_source: []const u8,
};

pub const DefinitionEditorRow = editor_contract.Row;
pub const DefinitionEditorProjection = editor_contract.Projection;
pub const DefinitionEditorOutcome = editor_contract.Outcome;

pub const CatalogScope = enum { provider_native, unified };

pub const ProviderDescriptor = struct {
    id: []const u8,
    display_name: []const u8,
    catalog_scope: CatalogScope,
};

pub const Activation = struct {
    conversation_id: []const u8,
    workspace_path: []const u8,
    providers: []const ProviderDescriptor,
};

pub const ConversationTurnStatus = enum {
    completed,
    cancelled,
    failed,
    background,
    compacted,
};

/// Secret-free durable conversation evidence projected by fx. Storage,
/// recovery, and ownership remain host concerns; the extension decides which
/// records enter each model's bounded working view.
pub const ConversationTurn = struct {
    ordinal: u64,
    status: ConversationTurnStatus,
    task: []const u8 = "",
    answer: []const u8 = "",
    summary: []const u8 = "",
    omitted_turn_count: usize = 0,
    compaction_count: usize = 0,
};

pub const UserTurn = struct {
    session_id: []const u8,
    /// Stable fx-owned handle for the fully canonicalized turn. An agent run
    /// that cites this ID receives the original images, skill bindings, and
    /// authority-bearing input rather than a Fixer reconstruction of them.
    source_turn_id: u64,
    text: []const u8,
    /// Stable fx-owned references drawn only from this canonical turn. Fixer may
    /// pass a selected subset to projected specialist input; the host resolves
    /// and re-authorizes the bytes at run admission.
    attachment_references: []const []const u8 = &.{},
    /// Full fx-owned durable conversation history, translated into neutral
    /// semantic records. It is borrowed only for dispatch; Fixer must copy or
    /// project anything it retains.
    conversation_history: []const ConversationTurn = &.{},
};

pub const UserInstruction = struct {
    source_turn_id: u64,
    text: []const u8,
    attachment_references: []const []const u8 = &.{},
};

pub const AgentRunScope = union(enum) {
    leader: struct { agent_id: []const u8 },
    peer: struct {
        agent_id: []const u8,
        collaboration_id: []const u8,
        round: u32,
    },
    specialist: struct {
        specialist_id: []const u8,
        delegation_id: []const u8,
        attempt: u32,
    },
};

/// Capability provenance is never model input. The host uses this handle to
/// resolve canonical rich input and to authorize explicitly projected
/// attachment references, but only VisibleInput decides what the model sees.
pub const AgentRunAuthority = struct {
    source_turn_id: u64,
    /// Additional canonical inputs accepted as in-session user instructions.
    /// The root source remains the exact current task; these IDs authorize
    /// instruction attachments and are independently checked by fx.
    instruction_source_turn_ids: []const u64 = &.{},
};

/// Exact identity inside one authenticated unified provider catalog. Route and
/// name are opaque provider-owned values; neither may be reconstructed from an
/// Fixer-local alias.
pub const ModelSelection = struct {
    provider_id: []const u8,
    route: []const u8,
    name: []const u8,
    reasoning_effort: ?[]const u8 = null,
};

pub const ProjectedInput = struct {
    content: []const u8,
    attachment_references: []const []const u8 = &.{},
};

pub const VisibleInput = union(enum) {
    /// Resolve the full canonical fx turn named by AgentRunAuthority, including
    /// images and skill bindings, then append only this Fixer-owned context.
    canonical_turn: struct { supplemental_context: []const u8 = "" },
    /// Do not inject canonical user text, images, skills, or history. Only this
    /// content and these explicitly selected, authority-checked attachments are
    /// visible. This is the required input form for stateless specialists.
    projected: ProjectedInput,
};

/// A complete fx-owned agent run. fx owns model streaming, the tool loop,
/// permissions, process and filesystem access, and transcript presentation.
pub const AgentRunRequest = struct {
    run_id: []const u8,
    /// Opaque extension identity for a context-bearing agent surface. fx owns
    /// the exact model/tool history behind this key and reuses it only inside
    /// the current host conversation. Stateless runs must leave this null.
    context_key: ?[]const u8 = null,
    authority: AgentRunAuthority,
    model: ModelSelection,
    scope: AgentRunScope,
    system_prompt: []const u8,
    visible_input: VisibleInput,
    response_schema_json: ?[]const u8 = null,
};

pub const AgentRunStarted = struct {
    run_id: []const u8,
};

pub const AgentRunCompleted = struct {
    run_id: []const u8,
    output: []const u8,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
};

pub const AgentRunFailed = struct {
    run_id: []const u8,
    message: []const u8,
    interrupted: bool = false,
    kind: AgentRunFailureKind = .runtime,
    http_status: ?u16 = null,
};

pub const HostEvent = union(enum) {
    enter: Activation,
    leave,
    user_turn: UserTurn,
    user_instruction: UserInstruction,
    agent_run_started: AgentRunStarted,
    agent_run_completed: AgentRunCompleted,
    agent_run_failed: AgentRunFailed,
    cancel_requested,
};

pub const NoticeTone = enum { info, warning, failure };

/// A semantic breadcrumb chosen by the extension and written by the host.
/// Identifiers are deliberately separate so a failed scenario can reconstruct
/// causality without logging prompts, model output, credentials, or tool data.
pub const TraceRecord = struct {
    event: []const u8,
    session_id: []const u8 = "",
    run_id: []const u8 = "",
    caused_by_run_id: []const u8 = "",
    agent_id: []const u8 = "",
    detail: []const u8 = "",
};

pub const Intent = union(enum) {
    mode_entered: struct { notice: []const u8 },
    mode_left: struct { notice: []const u8 },
    start_agent_run: AgentRunRequest,
    cancel_agent_run: struct { run_id: []const u8 },
    publish_answer: struct { agent_id: []const u8, text: []const u8 },
    /// Close the canonical fx turn as failed without fabricating an assistant
    /// answer. User-facing detail remains a separate semantic notice.
    turn_failed,
    notice: struct { tone: NoticeTone, text: []const u8 },
    trace: TraceRecord,
};

pub const IntentSink = struct {
    context: *anyopaque,
    emit_fn: *const fn (context: *anyopaque, intent: Intent) anyerror!void,

    /// All intent slices are borrowed until emit returns. The host must copy
    /// anything retained for asynchronous execution.
    pub fn emit(self: IntentSink, intent: Intent) !void {
        try self.emit_fn(self.context, intent);
    }
};

pub const Engine = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Dispatch is serialized on the host event-loop thread and must not
        /// block on model, tool, process, filesystem, or network work. All
        /// HostEvent slices are borrowed until dispatch returns. The extension
        /// retains state by copying what it needs with its allocator.
        ///
        /// Expected user-facing refusals are intents, not errors. Errors are
        /// reserved for invariant violations and resource failures.
        dispatch: *const fn (context: *anyopaque, event: HostEvent, sink: IntentSink) anyerror!void,
        deinit: *const fn (context: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn dispatch(self: Engine, event: HostEvent, sink: IntentSink) !void {
        try self.vtable.dispatch(self.context, event, sink);
    }

    pub fn deinit(self: Engine, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.context, allocator);
    }
};

pub const CreateFn = *const fn (
    allocator: std.mem.Allocator,
    options: CreateOptions,
) anyerror!Engine;

pub const InspectDefinitionFn = *const fn (
    allocator: std.mem.Allocator,
    definition_source: []const u8,
) anyerror!DefinitionMetadata;

pub fn validateExtension(comptime Extension: type) void {
    if (!@hasDecl(Extension, "descriptor")) {
        @compileError("orchestration extension must declare descriptor()");
    }
    if (!@hasDecl(Extension, "create")) {
        @compileError("orchestration extension must declare create()");
    }
    if (!@hasDecl(Extension, "inspectDefinition")) {
        @compileError("orchestration extension must declare inspectDefinition()");
    }

    const descriptor: ExtensionDescriptor = Extension.descriptor();
    if (descriptor.api_version != api_version) {
        @compileError("orchestration extension host API version mismatch");
    }
    if (descriptor.id.len == 0 or descriptor.display_name.len == 0 or
        descriptor.definition_kind.len == 0 or descriptor.definition_collection.len == 0)
    {
        @compileError("orchestration extension identity cannot be empty");
    }
    if (descriptor.slash_command.len < 2 or descriptor.slash_command[0] != '/') {
        @compileError("orchestration extension command must begin with '/'");
    }
    for (descriptor.slash_command) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            @compileError("orchestration extension command must be one slash-command token");
        }
    }
    if (descriptor.summary.len == 0 or descriptor.usage.len == 0) {
        @compileError("orchestration extension copy cannot be empty");
    }

    const create_fn: CreateFn = Extension.create;
    const inspect_fn: InspectDefinitionFn = Extension.inspectDefinition;
    _ = create_fn;
    _ = inspect_fn;
}

test "engine forwards host events and borrowed intents through erased boundaries" {
    const State = struct {
        dispatches: usize = 0,

        fn dispatch(context: *anyopaque, event: HostEvent, sink: IntentSink) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.dispatches += 1;
            switch (event) {
                .cancel_requested => try sink.emit(.{ .notice = .{
                    .tone = .warning,
                    .text = "cancelled",
                } }),
                else => return error.UnexpectedEvent,
            }
        }

        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    };
    const Capture = struct {
        seen: bool = false,

        fn emit(context: *anyopaque, intent: Intent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (intent) {
                .notice => |notice| {
                    try std.testing.expectEqual(NoticeTone.warning, notice.tone);
                    try std.testing.expectEqualStrings("cancelled", notice.text);
                    self.seen = true;
                },
                else => return error.UnexpectedIntent,
            }
        }
    };

    var state = State{};
    var capture = Capture{};
    const vtable = Engine.VTable{ .dispatch = State.dispatch, .deinit = State.deinit };
    const engine = Engine{ .context = &state, .vtable = &vtable };
    try engine.dispatch(.cancel_requested, .{ .context = &capture, .emit_fn = Capture.emit });

    try std.testing.expectEqual(@as(usize, 1), state.dispatches);
    try std.testing.expect(capture.seen);
}
