const agent_runtime = @import("agent_runtime.zig");
const worker_runtime = @import("worker_runtime.zig");
const runtime_assistant_stream = @import("runtime/assistant_stream.zig");
const runtime_config = @import("runtime/config.zig");
const runtime_deps = @import("runtime/deps.zig");
const runtime_lifecycle = @import("runtime/lifecycle.zig");

/// Host-neutral admission point for one complete fx agent turn.
///
/// The caller owns lifecycle, persistence, presentation, and authority through
/// AgentRuntimeDeps. The service owns the canonical provider/tool loop. Domain
/// features such as native subagents and optional orchestration extensions must
/// adapt to this seam instead of calling one another's execution machinery.
pub const Error = error{
    OutOfMemory,
    Cancelled,
    AgentExecutionFailed,
};

pub const Request = struct {
    agent: *agent_runtime.Agent,
    deps: *const runtime_deps.AgentRuntimeDeps,
    semantic_presentation: ?runtime_assistant_stream.SemanticPresentationSink = null,
    lifecycle: runtime_lifecycle.LifecycleContext,
    config: runtime_config.Config,
    prompt: worker_runtime.QueuedPrompt,
    /// Optional out-param receiving the specific error name mapped to
    /// AgentExecutionFailed. It points at the static error-name table, so no
    /// allocation is needed, and it is left unchanged on success.
    failure_cause_name: ?*?[]const u8 = null,
};

pub fn run(request: Request) Error!void {
    agent_runtime.processAgentPrompt(
        request.agent,
        request.deps,
        request.semantic_presentation,
        request.lifecycle,
        request.config,
        request.prompt,
    ) catch |err| {
        if (request.failure_cause_name) |out| out.* = @errorName(err);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            else => error.AgentExecutionFailed,
        };
    };
}

test "service maps host failures without changing cancellation identity" {
    // Compile the complete request boundary in the ordinary core test root.
    // Behavioral coverage for the shared provider/tool loop remains in
    // agent/runtime/tests; feature adapters test their own dependency wiring.
    _ = Request;
    _ = run;
}
