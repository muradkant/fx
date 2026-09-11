import { afterEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";

const AUTH_SOURCE = join(homedir(), ".fx", "opencode-auth.json");
const ENABLED = process.env.FX_ORCHESTRATION_LIVE === "1";
const SKIP = !ENABLED || !tmuxAvailable() || !existsSync(AUTH_SOURCE);
const TIMEOUT = 180_000;
const ANSWER_MARKER = "CRUCIBLE_FIXER_LIVE_7F31";
const CONTEXT_SETUP_MARKER = "CRUCIBLE_FIXER_CONTEXT_READY_2B19";
const CONTEXT_MEMORY_MARKER = "CRUCIBLE_FIXER_CONTEXT_MEMORY_5D2C";
const PEER_ANSWER_MARKER = "CRUCIBLE_FIXER_PEER_DONE_A821";
const TOOL_ANSWER_MARKER = "CRUCIBLE_FIXER_TOOL_DONE_91C4";
const TOOL_FILE_CONTENT = "FIXER_FX_PERMISSION_BRIDGE_42";
const STEERING_ANSWER_MARKER = "CRUCIBLE_FIXER_LIVE_STEERING_6E93";

let session: TmuxSession | null = null;
const tempDirs: string[] = [];

async function sendSteering(active: TmuxSession, text: string) {
  await active.sendLiteral(text);
  await active.sendLiteral("\x1b[13;5u");
}

async function waitForTerminalTrace(
  path: string,
  timeoutMs: number,
  publicationCount = 1,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let latest = "";
  while (Date.now() < deadline) {
    latest = existsSync(path) ? readFileSync(path, "utf8") : "";
    if ((latest.match(/event=answer_published/g)?.length ?? 0) >= publicationCount) {
      return latest;
    }
    if (latest.includes("event=agent_protocol_rejected") ||
        latest.includes("event=agent_run_failed") ||
        latest.includes("event=specialist_run_failed")) {
      throw new Error(`Fixer live run failed before publication.\n${latest}`);
    }
    await Bun.sleep(50);
  }
  throw new Error(`Timed out waiting for Fixer terminal trace.\n${latest}`);
}

async function waitForTerminalTraceEvent(
  path: string,
  event: string,
  timeoutMs: number,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let latest = "";
  while (Date.now() < deadline) {
    latest = existsSync(path) ? readFileSync(path, "utf8") : "";
    if (latest.includes(event)) return latest;
    if (latest.includes("event=agent_protocol_rejected") ||
        latest.includes("event=specialist_run_failed")) {
      throw new Error(`Fixer live run failed before ${event}.\n${latest}`);
    }
    await Bun.sleep(50);
  }
  throw new Error(`Timed out waiting for ${event}.\n${latest}`);
}

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

describe.skipIf(SKIP)("tui: live Fixer Crucible", () => {
  test(
    "a real OpenCode leader run crosses the fx host and publishes a terminal answer",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-fixer-live-crucible-"));
      const home = join(root, "home");
      const fxHome = join(home, ".fx");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "causal.trace.log");
      mkdirSync(fxHome, { recursive: true });
      mkdirSync(workspace);
      copyFileSync(AUTH_SOURCE, join(fxHome, "opencode-auth.json"));
      chmodSync(join(fxHome, "opencode-auth.json"), 0o600);
      tempDirs.push(root);

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        env: {
          HOME: home,
          FX_AUTO_UPGRADE: "0",
          FX_DISABLE_KEYCHAIN: "1",
          FX_SKIP_ONBOARDING: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES:
            "orchestration,agent,provider,permission,tool,worker,interrupt",
        },
      });

      try {
        await session.waitForComposer(15_000);
        await session.sendText("/fixer");
        await session.waitForText("Fixer mode enabled.", 10_000);
        await session.waitForComposer(10_000);
        await session.sendText(
          `This is a runtime probe. Do not call tools, peers, or specialists. Answer now with exactly ${ANSWER_MARKER} and no other text.`,
        );

        const trace = await waitForTerminalTrace(tracePath, TIMEOUT);
        await session.waitForText(ANSWER_MARKER, 15_000);
        await session.waitForComposer(15_000);
        expect(session.paneStatus()).toEqual({ dead: false, status: null });

        const lifecycle = [
          "event=session_created",
          "event=agent_run_requested",
          "event=agent_run_started",
          "event=agent_run_completed",
          "event=answer_published",
        ];
        let cursor = -1;
        for (const event of lifecycle) {
          const next = trace.indexOf(event, cursor + 1);
          expect(next).toBeGreaterThan(cursor);
          cursor = next;
        }
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(10_000)).toBe(true);
        session = null;
      } catch (error) {
        // Retain diagnostics, never the copied credential.
        rmSync(join(fxHome, "opencode-auth.json"), { force: true });
        if (session) {
          writeFileSync(
            join(root, "failure-scrollback.txt"),
            await session.captureFullScrollback(),
          );
          writeFileSync(
            join(root, "failure-scrollback.ansi.txt"),
            await session.captureFullScrollbackEscapes(),
          );
        }
        writeFileSync(
          join(root, "failure-summary.txt"),
          [
            String(error),
            "",
            "stderr:",
            existsSync(stderrPath)
              ? readFileSync(stderrPath, "utf8")
              : "<missing>",
            "",
            "causal trace:",
            existsSync(tracePath)
              ? readFileSync(tracePath, "utf8")
              : "<missing>",
          ].join("\n"),
        );
        const cleanupIndex = tempDirs.indexOf(root);
        if (cleanupIndex >= 0) tempDirs.splice(cleanupIndex, 1);
        console.error(`retained live Fixer failure artifacts at ${root}`);
        throw error;
      }
    },
    TIMEOUT + 30_000,
  );

  test(
    "a second real OpenCode turn receives Fixer's durable conversation view",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-fixer-live-context-crucible-"));
      const home = join(root, "home");
      const fxHome = join(home, ".fx");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "causal.trace.log");
      mkdirSync(fxHome, { recursive: true });
      mkdirSync(workspace);
      copyFileSync(AUTH_SOURCE, join(fxHome, "opencode-auth.json"));
      chmodSync(join(fxHome, "opencode-auth.json"), 0o600);
      tempDirs.push(root);

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        env: {
          HOME: home,
          FX_AUTO_UPGRADE: "0",
          FX_DISABLE_KEYCHAIN: "1",
          FX_SKIP_ONBOARDING: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES:
            "orchestration,agent,provider,permission,tool,worker,interrupt",
        },
      });

      try {
        await session.waitForComposer(15_000);
        await session.sendText("/fixer");
        await session.waitForText("Fixer mode enabled.", 10_000);
        await session.waitForComposer(10_000);
        await session.sendText(
          `Remember the exact nonce ${CONTEXT_MEMORY_MARKER} for my next turn. Do not call tools, peers, or specialists. Answer now with exactly ${CONTEXT_SETUP_MARKER}.`,
        );
        await waitForTerminalTrace(tracePath, TIMEOUT, 1);
        await session.waitForText(CONTEXT_SETUP_MARKER, 15_000);
        await session.waitForComposer(15_000);

        await session.sendText(
          "Use the prior Fixer conversation view. Do not call tools, peers, or specialists. Answer with exactly the nonce I asked you to remember in my previous turn and no other text.",
        );
        const trace = await waitForTerminalTrace(tracePath, TIMEOUT, 2);
        await session.waitForText(CONTEXT_MEMORY_MARKER, 15_000);
        await session.waitForComposer(15_000);

        expect(trace.match(/event=session_created/g)?.length).toBe(2);
        expect(trace.match(/event=context_view_committed/g)?.length).toBe(2);
        expect(trace.match(/event=answer_published/g)?.length).toBe(2);
        expect(session.paneStatus()).toEqual({ dead: false, status: null });
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(10_000)).toBe(true);
        session = null;
      } catch (error) {
        rmSync(join(fxHome, "opencode-auth.json"), { force: true });
        if (session) {
          writeFileSync(
            join(root, "failure-scrollback.txt"),
            await session.captureFullScrollback(),
          );
          writeFileSync(
            join(root, "failure-scrollback.ansi.txt"),
            await session.captureFullScrollbackEscapes(),
          );
        }
        writeFileSync(
          join(root, "failure-summary.txt"),
          [
            String(error),
            "",
            "stderr:",
            existsSync(stderrPath)
              ? readFileSync(stderrPath, "utf8")
              : "<missing>",
            "",
            "causal trace:",
            existsSync(tracePath)
              ? readFileSync(tracePath, "utf8")
              : "<missing>",
          ].join("\n"),
        );
        const cleanupIndex = tempDirs.indexOf(root);
        if (cleanupIndex >= 0) tempDirs.splice(cleanupIndex, 1);
        console.error(`retained live Fixer context failure artifacts at ${root}`);
        throw error;
      }
    },
    TIMEOUT * 2 + 30_000,
  );

  test(
    "a real OpenCode peer consultation returns evidence without moving leadership",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-fixer-live-peer-crucible-"));
      const home = join(root, "home");
      const fxHome = join(home, ".fx");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "causal.trace.log");
      mkdirSync(fxHome, { recursive: true });
      mkdirSync(workspace);
      copyFileSync(AUTH_SOURCE, join(fxHome, "opencode-auth.json"));
      chmodSync(join(fxHome, "opencode-auth.json"), 0o600);
      tempDirs.push(root);

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        env: {
          HOME: home,
          FX_AUTO_UPGRADE: "0",
          FX_DISABLE_KEYCHAIN: "1",
          FX_SKIP_ONBOARDING: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES:
            "orchestration,agent,provider,permission,tool,worker,interrupt",
        },
      });

      try {
        await session.waitForComposer(15_000);
        await session.sendText("/fixer");
        await session.waitForText("Fixer mode enabled.", 10_000);
        await session.waitForComposer(10_000);
        await session.sendText(
          `Keep Engineering as sole leader. Before answering, consult the authorized coding peer exactly once for a concise correctness check. Do not hand off leadership and do not call a specialist. After the consultation returns, answer with exactly ${PEER_ANSWER_MARKER}.`,
        );

        const trace = await waitForTerminalTrace(tracePath, TIMEOUT);
        await session.waitForText(PEER_ANSWER_MARKER, 15_000);
        await session.waitForComposer(15_000);
        const lifecycle = [
          "event=peer_consultation_created",
          "event=peer_consultation_requested",
          "event=peer_consultation_started",
          "event=peer_consultation_completed",
          "event=team_coordination_completed",
          "event=answer_published",
        ];
        let cursor = -1;
        for (const event of lifecycle) {
          const next = trace.indexOf(event, cursor + 1);
          expect(next).toBeGreaterThan(cursor);
          cursor = next;
        }
        expect(trace.match(/event=leadership_transferred/g)?.length).toBe(1);
        expect(trace).toContain("native_subagent=absent");
        expect(session.paneStatus()).toEqual({ dead: false, status: null });
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(10_000)).toBe(true);
        session = null;
      } catch (error) {
        rmSync(join(fxHome, "opencode-auth.json"), { force: true });
        if (session) {
          writeFileSync(
            join(root, "failure-scrollback.txt"),
            await session.captureFullScrollback(),
          );
          writeFileSync(
            join(root, "failure-scrollback.ansi.txt"),
            await session.captureFullScrollbackEscapes(),
          );
        }
        writeFileSync(
          join(root, "failure-summary.txt"),
          [
            String(error),
            "",
            "stderr:",
            existsSync(stderrPath)
              ? readFileSync(stderrPath, "utf8")
              : "<missing>",
            "",
            "causal trace:",
            existsSync(tracePath)
              ? readFileSync(tracePath, "utf8")
              : "<missing>",
          ].join("\n"),
        );
        const cleanupIndex = tempDirs.indexOf(root);
        if (cleanupIndex >= 0) tempDirs.splice(cleanupIndex, 1);
        console.error(`retained live Fixer peer failure artifacts at ${root}`);
        throw error;
      }
    },
    TIMEOUT + 30_000,
  );

  test(
    "a real OpenCode tool call pauses in fx ask mode and resumes the exact Fixer run",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-fixer-live-tool-crucible-"));
      const home = join(root, "home");
      const fxHome = join(home, ".fx");
      const workspace = join(root, "workspace");
      const target = join(workspace, "fixer-crucible.txt");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "causal.trace.log");
      mkdirSync(fxHome, { recursive: true });
      mkdirSync(workspace);
      copyFileSync(AUTH_SOURCE, join(fxHome, "opencode-auth.json"));
      chmodSync(join(fxHome, "opencode-auth.json"), 0o600);
      tempDirs.push(root);

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        env: {
          HOME: home,
          FX_AUTO_UPGRADE: "0",
          FX_DISABLE_KEYCHAIN: "1",
          FX_PERMISSION_MODE: "ask",
          FX_SKIP_ONBOARDING: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES:
            "orchestration,agent,provider,permission,tool,worker,interrupt",
        },
      });

      try {
        await session.waitForComposer(15_000);
        await session.sendText("/fixer");
        await session.waitForText("Fixer mode enabled.", 10_000);
        await session.waitForComposer(10_000);
        await session.sendText(
          `I want the authorized coding peer to own and execute this exact turn. Use the write_file tool to create fixer-crucible.txt with exact content ${JSON.stringify(TOOL_FILE_CONTENT)}. Only after that tool succeeds, answer with exactly ${TOOL_ANSWER_MARKER}.`,
        );

        await session.waitForText("Apply this change?", TIMEOUT);
        expect(existsSync(target)).toBe(false);
        await session.sendKeys("1");

        const trace = await waitForTerminalTrace(tracePath, TIMEOUT);
        await session.waitForText(TOOL_ANSWER_MARKER, 15_000);
        await session.waitForComposer(15_000);
        expect(readFileSync(target, "utf8")).toBe(TOOL_FILE_CONTENT);
        expect(trace).toContain("event=answer_published");
        expect(session.paneStatus()).toEqual({ dead: false, status: null });
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(10_000)).toBe(true);
        session = null;
      } catch (error) {
        rmSync(join(fxHome, "opencode-auth.json"), { force: true });
        if (session) {
          writeFileSync(
            join(root, "failure-scrollback.txt"),
            await session.captureFullScrollback(),
          );
          writeFileSync(
            join(root, "failure-scrollback.ansi.txt"),
            await session.captureFullScrollbackEscapes(),
          );
        }
        writeFileSync(
          join(root, "failure-summary.txt"),
          [
            String(error),
            "",
            "stderr:",
            existsSync(stderrPath)
              ? readFileSync(stderrPath, "utf8")
              : "<missing>",
            "",
            "causal trace:",
            existsSync(tracePath)
              ? readFileSync(tracePath, "utf8")
              : "<missing>",
          ].join("\n"),
        );
        const cleanupIndex = tempDirs.indexOf(root);
        if (cleanupIndex >= 0) tempDirs.splice(cleanupIndex, 1);
        console.error(`retained live Fixer tool failure artifacts at ${root}`);
        throw error;
      }
    },
    TIMEOUT + 30_000,
  );

  test(
    "a real OpenCode leader is replaced by an in-session user instruction",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-fixer-live-steering-crucible-"));
      const home = join(root, "home");
      const fxHome = join(home, ".fx");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "causal.trace.log");
      mkdirSync(fxHome, { recursive: true });
      mkdirSync(workspace);
      copyFileSync(AUTH_SOURCE, join(fxHome, "opencode-auth.json"));
      chmodSync(join(fxHome, "opencode-auth.json"), 0o600);
      tempDirs.push(root);

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        env: {
          HOME: home,
          FX_AUTO_UPGRADE: "0",
          FX_DISABLE_KEYCHAIN: "1",
          FX_SKIP_ONBOARDING: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES:
            "orchestration,agent,provider,permission,tool,worker,interrupt",
        },
      });

      try {
        await session.waitForComposer(15_000);
        await session.sendText("/fixer");
        await session.waitForText("Fixer mode enabled.", 10_000);
        await session.waitForComposer(10_000);
        await session.sendText(
          "Begin a detailed architecture review of the workspace. Do not call tools, peers, or specialists, and do not answer with the later steering marker unless I explicitly provide it.",
        );

        const firstTrace = await waitForTerminalTraceEvent(
          tracePath,
          "event=agent_run_started",
          15_000,
        );
        expect(firstTrace.match(/event=session_created/g)?.length).toBe(1);
        await sendSteering(session,
          `Replace the work in progress. Do not call tools, peers, or specialists. Answer now with exactly ${STEERING_ANSWER_MARKER} and no other text.`,
        );

        const trace = await waitForTerminalTrace(tracePath, TIMEOUT);
        await session.waitForText(STEERING_ANSWER_MARKER, 15_000);
        await session.waitForComposer(15_000);
        const lifecycle = [
          "event=agent_run_interrupted",
          "event=user_instruction_committed",
          "event=agent_run_requested",
          "event=agent_run_started",
          "event=answer_published",
        ];
        let cursor = trace.indexOf("event=agent_run_started");
        for (const event of lifecycle) {
          const next = trace.indexOf(event, cursor + 1);
          expect(next).toBeGreaterThan(cursor);
          cursor = next;
        }
        expect(trace.match(/event=session_created/g)?.length).toBe(1);
        expect(trace.match(/event=answer_published/g)?.length).toBe(1);
        expect(session.paneStatus()).toEqual({ dead: false, status: null });
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(10_000)).toBe(true);
        session = null;
      } catch (error) {
        rmSync(join(fxHome, "opencode-auth.json"), { force: true });
        if (session) {
          writeFileSync(
            join(root, "failure-scrollback.txt"),
            await session.captureFullScrollback(),
          );
          writeFileSync(
            join(root, "failure-scrollback.ansi.txt"),
            await session.captureFullScrollbackEscapes(),
          );
        }
        writeFileSync(
          join(root, "failure-summary.txt"),
          [
            String(error),
            "",
            "stderr:",
            existsSync(stderrPath)
              ? readFileSync(stderrPath, "utf8")
              : "<missing>",
            "",
            "causal trace:",
            existsSync(tracePath)
              ? readFileSync(tracePath, "utf8")
              : "<missing>",
          ].join("\n"),
        );
        const cleanupIndex = tempDirs.indexOf(root);
        if (cleanupIndex >= 0) tempDirs.splice(cleanupIndex, 1);
        console.error(`retained live Fixer steering failure artifacts at ${root}`);
        throw error;
      }
    },
    TIMEOUT + 30_000,
  );
});
