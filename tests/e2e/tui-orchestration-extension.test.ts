import { afterEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";

const ENABLED = process.env.FX_ORCHESTRATION_E2E === "1";
const SKIP = !ENABLED || !tmuxAvailable();
const TIMEOUT = 30_000;
const STEERING_MARKER = "CRUCIBLE_ALT_STEERING_DONE_D4C7";
const STEERING_FOLLOWUP_MARKER = "CRUCIBLE_ALT_STEERING_MEMORY_8A21";
const CORRECTION_MARKER = "CRUCIBLE_ALT_CORRECTION_DONE_31B9";
const CONTINUITY_MARKER = "CRUCIBLE_ALT_CONTEXT_SURFACE_DONE_5E72";
const CONTINUITY_FILE_SENTINEL = "EXACT_PRE_CONSULTATION_TOOL_EVIDENCE_C82D";
const CONTINUITY_PEER_SENTINEL = "PEER_REVIEW_EVIDENCE_4F19";
const TEAM_FAILURE_MARKER = "CRUCIBLE_ALT_TEAM_FAILURE_RECOVERED_9C44";
const NESTED_SPECIALIST_RAW = "CRUCIBLE_NESTED_SPECIALIST_RAW_73E1";
const NESTED_PEER_SYNTHESIS = "CRUCIBLE_NESTED_PEER_SYNTHESIS_A902";
const NESTED_ANSWER_MARKER = "CRUCIBLE_NESTED_UNWIND_DONE_6F3B";
const TEAM_UX_FIRST_MARKER = "CRUCIBLE_TEAM_UX_REVISION_ONE_8C31";
const TEAM_UX_SECOND_MARKER = "CRUCIBLE_TEAM_UX_REVISION_TWO_4D09";

let session: TmuxSession | null = null;
const tempDirs: string[] = [];

const ENGINEERING_TEAM = {
  schema: 2,
  id: "engineering",
  revision: 1,
  name: "Engineering",
  provider_id: "opencode",
  models: [
    { id: "engineering", route: "go", name: "kimi-k3" },
    { id: "coding", route: "go", name: "deepseek-v4-flash" },
    { id: "multimodal", route: "go", name: "mimo-v2.5" },
  ],
  primary: {
    id: "engineering",
    model_id: "engineering",
    definition: "Own the task, use evidence, and publish the final answer.",
    specialists: ["visual-inspector"],
  },
  peers: [{
    id: "coding",
    model_id: "coding",
    definition: "Contribute code-centered work and consult specialists when useful.",
    specialists: ["visual-inspector"],
  }],
  specialists: [{
    id: "visual-inspector",
    model_id: "multimodal",
    definition: "Inspect only the caller's bounded projection and selected attachments.",
  }],
};

function seedAltEngineeringTeam(home: string) {
  const source = `${JSON.stringify(ENGINEERING_TEAM, null, 2)}\n`;
  const digest = createHash("sha256").update(source).digest("hex");
  const identity = join(home, ".fx", "extensions", "alt", "teams", "engineering");
  mkdirSync(identity, { recursive: true, mode: 0o700 });
  writeFileSync(join(identity, `1-${digest}.json`), source, { mode: 0o600 });
  writeFileSync(join(identity, "manifest.json"), JSON.stringify({
    schema: 1,
    id: "engineering",
    name: "Engineering",
    latest_revision: 1,
    latest_digest: digest,
    created_at_ms: 1,
    updated_at_ms: 1,
    deleted: false,
  }), { mode: 0o600 });
}

async function enterSeededAlt(active: TmuxSession) {
  await active.sendText("/alt");
  await active.waitForText("ALT Teams 1", 5_000);
  await active.sendKeys("Down");
  await active.sendKeys("Enter");
  await active.waitForText("Start a new conversation", 5_000);
  await active.sendKeys("Enter");
  await active.waitForText("ALT mode enabled.", 5_000);
  await active.waitForComposer(5_000);
}

async function sendSteering(active: TmuxSession, text: string) {
  await active.sendLiteral(text);
  await active.sendLiteral("\x1b[13;5u");
}

async function waitForFileText(
  path: string,
  expected: string,
  timeoutMs: number,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let latest = "";
  while (Date.now() < deadline) {
    latest = existsSync(path) ? readFileSync(path, "utf8") : "";
    if (latest.includes(expected)) return latest;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for ${expected}.\n${latest}`);
}

async function waitForFileOccurrences(
  path: string,
  pattern: RegExp,
  count: number,
  timeoutMs: number,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let latest = "";
  while (Date.now() < deadline) {
    latest = existsSync(path) ? readFileSync(path, "utf8") : "";
    if ((latest.match(pattern)?.length ?? 0) >= count) return latest;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for ${count} trace occurrences.\n${latest}`);
}

function startHeldOpenCodeSteeringServer() {
  const encoder = new TextEncoder();
  const requestBodies: string[] = [];
  let heldTimer: ReturnType<typeof setInterval> | null = null;
  let heldController: ReadableStreamDefaultController<Uint8Array> | null = null;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      if (url.pathname !== "/chat") return new Response("not found", { status: 404 });
      requestBodies.push(await request.text());
      if (requestBodies.length === 1) {
        return new Response(
          new ReadableStream<Uint8Array>({
            start(controller) {
              heldController = controller;
              const keepAlive = () => controller.enqueue(encoder.encode(": held\n\n"));
              keepAlive();
              heldTimer = setInterval(keepAlive, 50);
            },
            cancel() {
              if (heldTimer) clearInterval(heldTimer);
              heldTimer = null;
              heldController = null;
            },
          }),
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      const terminal = JSON.stringify({
        kind: "answer",
        answer: requestBodies.length === 2
          ? STEERING_MARKER
          : STEERING_FOLLOWUP_MARKER,
      });
      return new Response(
        `data: ${JSON.stringify({
          id: "alt-steering",
          choices: [{ delta: { content: terminal }, finish_reason: null }],
        })}\n\n` +
          `data: ${JSON.stringify({
            choices: [{ delta: {}, finish_reason: "stop" }],
            usage: { prompt_tokens: 10, completion_tokens: 4 },
          })}\n\n` +
          "data: [DONE]\n\n",
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    requestBodies,
    chatUrl: `http://127.0.0.1:${server.port}/chat`,
    stop() {
      if (heldTimer) clearInterval(heldTimer);
      heldTimer = null;
      server.stop(true);
    },
  };
}

function startOpenCodeTeamUxServer() {
  let requestCount = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      if (url.pathname === "/zen/models") {
        return Response.json({ data: [
          { id: "deepseek-v4-flash", object: "model" },
          { id: "kimi-k3", object: "model" },
          { id: "glm-5", object: "model" },
        ] });
      }
      if (url.pathname === "/go/models") {
        return Response.json({ data: [
          { id: "deepseek-v4-pro", object: "model" },
        ] });
      }
      if (url.pathname === "/protocols") {
        return Response.json({
          opencode: { npm: "@ai-sdk/openai-compatible", models: {} },
          "opencode-go": { npm: "@ai-sdk/openai-compatible", models: {} },
        });
      }
      if (url.pathname !== "/chat") return new Response("not found", { status: 404 });
      await request.text();
      requestCount += 1;
      const terminal = JSON.stringify({
        kind: "answer",
        answer: requestCount === 1 ? TEAM_UX_FIRST_MARKER : TEAM_UX_SECOND_MARKER,
      });
      return new Response(
        `data: ${JSON.stringify({
          id: "alt-team-ux",
          choices: [{ delta: { content: terminal }, finish_reason: null }],
        })}\n\n` +
          `data: ${JSON.stringify({
            choices: [{ delta: {}, finish_reason: "stop" }],
            usage: { prompt_tokens: 8, completion_tokens: 3 },
          })}\n\n` +
          "data: [DONE]\n\n",
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    chatUrl: `http://127.0.0.1:${server.port}/chat`,
    zenModelsUrl: `http://127.0.0.1:${server.port}/zen/models`,
    goModelsUrl: `http://127.0.0.1:${server.port}/go/models`,
    protocolMetadataUrl: `http://127.0.0.1:${server.port}/protocols`,
    stop() {
      server.stop(true);
    },
  };
}

function startOpenCodeCorrectionServer() {
  const requestBodies: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      if (url.pathname !== "/chat") return new Response("not found", { status: 404 });
      requestBodies.push(await request.text());
      const terminal = requestBodies.length === 1
        ? JSON.stringify({
            kind: "handoff",
            peer_id: "intruder",
            reason: "unauthorized semantic fixture",
          })
        : JSON.stringify({ kind: "answer", answer: CORRECTION_MARKER });
      return new Response(
        `data: ${JSON.stringify({
          id: "alt-correction",
          choices: [{ delta: { content: terminal }, finish_reason: null }],
        })}\n\n` +
          `data: ${JSON.stringify({
            choices: [{ delta: {}, finish_reason: "stop" }],
            usage: { prompt_tokens: 12, completion_tokens: 5 },
          })}\n\n` +
          "data: [DONE]\n\n",
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    requestBodies,
    chatUrl: `http://127.0.0.1:${server.port}/chat`,
    stop() {
      server.stop(true);
    },
  };
}

function startOpenCodeContinuityServer() {
  const requestBodies: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      if (url.pathname !== "/chat") return new Response("not found", { status: 404 });
      requestBodies.push(await request.text());
      const ordinal = requestBodies.length;
      if (ordinal === 1) {
        const argumentsJson = JSON.stringify({
          path: "continuity-sentinel.txt",
          start_line: 1,
          line_count: 20,
        });
        return new Response(
          `data: ${JSON.stringify({
            id: "alt-continuity-tool",
            choices: [{
              delta: {
                tool_calls: [{
                  index: 0,
                  id: "call_continuity_read",
                  type: "function",
                  function: { name: "read_file", arguments: argumentsJson },
                }],
              },
              finish_reason: "tool_calls",
            }],
            usage: { prompt_tokens: 14, completion_tokens: 5 },
          })}\n\n` + "data: [DONE]\n\n",
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      const terminal = ordinal === 2
        ? JSON.stringify({
            kind: "coordinate",
            peer_turns: [{
              key: "review",
              peer_id: "coding",
              objective: "Review the evidence-gathering approach.",
              context: "Check whether the leader can safely synthesize after consultation.",
            }],
          })
        : ordinal === 3
          ? JSON.stringify({
              result: CONTINUITY_PEER_SENTINEL,
              findings: ["consultation completed"],
              risks: [],
              confidence: 0.9,
            })
          : JSON.stringify({ kind: "answer", answer: CONTINUITY_MARKER });
      return new Response(
        `data: ${JSON.stringify({
          id: `alt-continuity-${ordinal}`,
          choices: [{ delta: { content: terminal }, finish_reason: null }],
        })}\n\n` +
          `data: ${JSON.stringify({
            choices: [{ delta: {}, finish_reason: "stop" }],
            usage: { prompt_tokens: 18, completion_tokens: 6 },
          })}\n\n` +
          "data: [DONE]\n\n",
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    requestBodies,
    chatUrl: `http://127.0.0.1:${server.port}/chat`,
    stop() {
      server.stop(true);
    },
  };
}

function startOpenCodeTeamFailureServer() {
  const requestBodies: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      if (url.pathname !== "/chat") return new Response("not found", { status: 404 });
      requestBodies.push(await request.text());
      const ordinal = requestBodies.length;
      const terminal = ordinal === 1
        ? JSON.stringify({
            kind: "coordinate",
            peer_turns: [{
              key: "review",
              peer_id: "coding",
              objective: "Return a typed review.",
            }],
          })
        : ordinal <= 3
          ? "malformed peer result sentinel"
          : JSON.stringify({ kind: "answer", answer: TEAM_FAILURE_MARKER });
      return new Response(
        `data: ${JSON.stringify({
          id: `alt-team-failure-${ordinal}`,
          choices: [{ delta: { content: terminal }, finish_reason: null }],
        })}\n\n` +
          `data: ${JSON.stringify({
            choices: [{ delta: {}, finish_reason: "stop" }],
            usage: { prompt_tokens: 15, completion_tokens: 5 },
          })}\n\n` +
          "data: [DONE]\n\n",
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    requestBodies,
    chatUrl: `http://127.0.0.1:${server.port}/chat`,
    stop() {
      server.stop(true);
    },
  };
}

function startOpenCodeNestedTeamServer() {
  const requestBodies: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      if (url.pathname !== "/chat") return new Response("not found", { status: 404 });
      requestBodies.push(await request.text());
      const ordinal = requestBodies.length;
      if (ordinal === 3) {
        const argumentsJson = JSON.stringify({
          path: "nested-specialist-sentinel.txt",
          start_line: 1,
          line_count: 20,
        });
        return new Response(
          `data: ${JSON.stringify({
            id: "alt-nested-specialist-tool",
            choices: [{
              delta: {
                tool_calls: [{
                  index: 0,
                  id: "call_nested_specialist_read",
                  type: "function",
                  function: { name: "read_file", arguments: argumentsJson },
                }],
              },
              finish_reason: "tool_calls",
            }],
            usage: { prompt_tokens: 18, completion_tokens: 5 },
          })}\n\n` + "data: [DONE]\n\n",
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      const terminal = ordinal === 1
        ? JSON.stringify({
            kind: "coordinate",
            peer_turns: [{
              key: "nested-review",
              peer_id: "coding",
              objective: "Inspect the bounded problem and consult your visual specialist.",
              context: "Return a synthesis rather than forwarding raw specialist output.",
            }],
          })
        : ordinal === 2
          ? JSON.stringify({
              kind: "coordinate",
              delegations: [{
                key: "nested-visual-check",
                specialist_id: "visual-inspector",
                objective: "Read nested-specialist-sentinel.txt and return its exact contents.",
              }],
            })
          : ordinal === 4
            ? JSON.stringify({
                result: NESTED_SPECIALIST_RAW,
                findings: ["leaf completed"],
                risks: [],
                confidence: 1,
              })
            : ordinal === 5
              ? JSON.stringify({
                  result: NESTED_PEER_SYNTHESIS,
                  findings: ["consultant synthesized its direct return"],
                  risks: [],
                  confidence: 0.95,
                })
              : JSON.stringify({ kind: "answer", answer: NESTED_ANSWER_MARKER });
      return new Response(
        `data: ${JSON.stringify({
          id: `alt-nested-team-${ordinal}`,
          choices: [{ delta: { content: terminal }, finish_reason: null }],
        })}\n\n` +
          `data: ${JSON.stringify({
            choices: [{ delta: {}, finish_reason: "stop" }],
            usage: { prompt_tokens: 20, completion_tokens: 7 },
          })}\n\n` +
          "data: [DONE]\n\n",
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    requestBodies,
    chatUrl: `http://127.0.0.1:${server.port}/chat`,
    stop() {
      server.stop(true);
    },
  };
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

describe.skipIf(SKIP)("tui: orchestration extension host", () => {
  for (const removeSpecialist of [false, true]) {
    test(`Team model selections survive role growth with ${removeSpecialist ? 0 : 1} specialists`, async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-team-model-growth-"));
      tempDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace);
      writeFileSync(join(home, ".fx", "opencode-auth.json"), JSON.stringify({
        schema_version: 1, api_key: "team-growth-fixture",
      }), { mode: 0o600 });
      writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
        provider: "opencode", models: { opencode: "deepseek-v4-flash" },
      }));
      const provider = startOpenCodeTeamUxServer();
      try {
        session = await TmuxSession.create({ cwd: workspace, stderrPath, env: {
          HOME: home, FX_AUTO_UPGRADE: "0", FX_DISABLE_KEYCHAIN: "1",
          FX_SKIP_ONBOARDING: "1", OPENCODE_API_KEY: undefined,
          FX_E2E_OPENCODE_CHAT_URL: provider.chatUrl,
          FX_E2E_OPENCODE_ZEN_MODELS_URL: provider.zenModelsUrl,
          FX_E2E_OPENCODE_GO_MODELS_URL: provider.goModelsUrl,
          FX_E2E_OPENCODE_PROTOCOL_METADATA_URL: provider.protocolMetadataUrl,
        } });
        const active = session;
        const choose = async (label: string) => {
          for (let i = 0; i < 12; i++) {
            if ((await active.capturePane()).includes(`› ${label}`)) {
              await active.sendKeys("Enter");
              return;
            }
            await active.sendKeys("Down");
          }
          throw new Error(`Could not select ${label}: ${await active.capturePane()}`);
        };
        const back = async (selected: string) => {
          await active.sendKeys("Escape");
          await active.waitForPane((pane) => pane.includes(`› ${selected}`), 5_000);
        };
        const model = async (id: string) => {
          await choose("Model");
          await active.waitForText("Models", 5_000);
          await active.sendLiteral(id);
          await active.sendKeys("Enter");
          await active.waitForText(`Model  ${id}`, 5_000);
        };
        await active.waitForComposer(10_000);
        await active.sendText("/alt");
        await active.waitForText("ALT Teams 0", 5_000);
        await active.sendKeys("Enter");
        await choose("Primary");
        await model("deepseek-v4-flash");
        await back("Name");
        await choose("Peers");
        await choose("Peer 1");
        await model("go/deepseek-v4-pro");
        await back("Peer 1");
        await choose("+ Add peer");
        if (removeSpecialist) {
          await choose("Model");
          await active.waitForText("Models", 5_000);
          await active.sendLiteral("deepseek-v4-flash");
          await active.sendKeys("Enter");
          await active.waitForText("Every Team role must use a distinct model.", 5_000);
          await back("Peer 1");
          await back("Name");
          await choose("Save & start");
          await active.waitForText("Choose a model for Peer 2.", 5_000);
          await choose("Peers");
          await choose("Peer 2");
        }
        await model("kimi-k3");
        await back("Peer 1");
        await back("Name");
        await choose("Specialists");
        await choose("+ Add specialist");
        await model("glm-5");
        if (removeSpecialist) {
          await choose("Remove role");
          await choose("Remove ");
        } else {
          await back("Specialist 1");
        }
        await back("Name");
        await choose("Save & start");
        await active.waitForText("ALT mode enabled.", 5_000);
        const teamsRoot = join(home, ".fx", "extensions", "alt", "teams");
        const teamIds = readdirSync(teamsRoot, { withFileTypes: true })
          .filter((entry) => entry.isDirectory())
          .map((entry) => entry.name);
        expect(teamIds).toHaveLength(1);
        const teamId = teamIds[0]!;
        const manifest = JSON.parse(readFileSync(join(teamsRoot, teamId, "manifest.json"), "utf8"));
        const saved = JSON.parse(readFileSync(join(teamsRoot, teamId, `1-${manifest.latest_digest}.json`), "utf8"));
        expect(saved.peers).toHaveLength(2);
        expect(saved.specialists).toHaveLength(removeSpecialist ? 0 : 1);
        const assigned = (role: { model_id: string }) => saved.models.find(
          (entry: { id: string }) => entry.id === role.model_id,
        );
        expect(assigned(saved.primary)).toMatchObject({ route: "zen", name: "deepseek-v4-flash" });
        expect(assigned(saved.peers[0])).toMatchObject({ route: "go", name: "deepseek-v4-pro" });
        expect(assigned(saved.peers[1])).toMatchObject({ route: "zen", name: "kimi-k3" });
        if (!removeSpecialist) {
          expect(assigned(saved.specialists[0])).toMatchObject({ route: "zen", name: "glm-5" });
        }
        expect(saved.models.map((entry: { name: string }) => entry.name).sort()).toEqual(
          (removeSpecialist ? ["deepseek-v4-flash", "deepseek-v4-pro", "kimi-k3"] :
            ["deepseek-v4-flash", "deepseek-v4-pro", "kimi-k3", "glm-5"]).sort(),
        );
        await active.waitForComposer(5_000);
        await active.sendText("Exercise the saved Team.");
        await active.waitForText(TEAM_UX_FIRST_MARKER, 10_000);
        await active.waitForComposer(5_000);
        expect(active.paneStatus()).toEqual({ dead: false, status: null });
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd(5_000)).toBe(true);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        session = null;
      } catch (error) {
        if (session) console.error(await session.capturePane());
        throw error;
      } finally {
        provider.stop();
      }
    }, 60_000);
  }

  test(
    "native Team UX creates revises deletes and resumes immutable ALT sessions",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-orchestration-team-ux-"));
      const home = join(root, "home");
      const fxHome = join(home, ".fx");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(fxHome, { recursive: true, mode: 0o700 });
      mkdirSync(workspace);
      const authPath = join(fxHome, "opencode-auth.json");
      writeFileSync(
        authPath,
        `${JSON.stringify({ schema_version: 1, api_key: "opencode-team-ux-fixture" })}\n`,
        { mode: 0o600 },
      );
      chmodSync(authPath, 0o600);
      tempDirs.push(root);
      const provider = startOpenCodeTeamUxServer();

      try {
        session = await TmuxSession.create({
          cwd: workspace,
          stderrPath,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_E2E_OPENCODE_CHAT_URL: provider.chatUrl,
            FX_E2E_OPENCODE_ZEN_MODELS_URL: provider.zenModelsUrl,
            FX_E2E_OPENCODE_GO_MODELS_URL: provider.goModelsUrl,
            FX_E2E_OPENCODE_PROTOCOL_METADATA_URL: provider.protocolMetadataUrl,
            FX_SKIP_ONBOARDING: "1",
            OPENCODE_API_KEY: undefined,
          },
        });
        await session.waitForComposer(10_000);

        await session.sendText("/alt");
        await session.waitForText("ALT Teams 0", 5_000);
        await session.sendKeys("Enter");
        await session.waitForText(
          "Configure a primary plus at least one peer or specialist.",
          5_000,
        );

        await session.sendKeys("Down");
        await session.sendKeys("Down");
        await session.sendKeys("Enter");
        await session.waitForText("Primary", 5_000);
        await session.sendKeys("Enter");
        await session.waitForText("Models", 5_000);
        await session.sendLiteral("deepseek-v4-flash");
        await session.waitForText("deepseek-v4-flash", 5_000);
        await session.sendKeys("Enter");
        await session.waitForText("Model  deepseek-v4-flash", 5_000);
        await session.sendKeys("Escape");
        await session.waitForPane(
          (pane) => pane.includes("› Name") && pane.includes("Save & start"),
          5_000,
        );

        for (const label of ["Provider", "Primary", "Peers"]) {
          await session.sendKeys("Down");
          await session.waitForPane((pane) => pane.includes(`› ${label}`), 5_000);
        }
        await session.sendKeys("Enter");
        await session.waitForPane((pane) => pane.includes("› Peer 1") && pane.includes("+ Add peer"), 5_000);
        await session.sendKeys("Enter");
        await session.waitForText("Peer 1", 5_000);
        await session.sendKeys("Enter");
        await session.waitForText("Models", 5_000);
        await session.sendLiteral("go/deepseek-v4-pro");
        await session.waitForText("go/deepseek-v4-pro", 5_000);
        await session.sendKeys("Enter");
        await session.waitForText("Model  go/deepseek-v4-pro", 5_000);
        await session.sendKeys("Escape");
        await session.waitForText("Peers", 5_000);
        await session.sendKeys("Escape");
        await session.waitForPane(
          (pane) => pane.includes("› Name") && pane.includes("Save & start"),
          5_000,
        );
        expect(existsSync(join(fxHome, "settings.json"))).toBe(false);
        for (const label of ["Provider", "Primary", "Peers", "Specialists", "Specialist access", "Save & start"]) {
          await session.sendKeys("Down");
          await session.waitForPane((pane) => pane.includes(`› ${label}`), 5_000);
        }
        await session.sendKeys("Enter");
        await session.waitForText("ALT mode enabled.", 5_000);
        await session.waitForComposer(5_000);
        await session.sendText("Persist a conversation on Team revision one.");
        await session.waitForText(TEAM_UX_FIRST_MARKER, 10_000);
        await session.waitForComposer(5_000);

        const teamsRoot = join(
          home,
          ".fx",
          "extensions",
          "alt",
          "teams",
        );
        const teamIds = readdirSync(teamsRoot, { withFileTypes: true })
          .filter((entry) => entry.isDirectory())
          .map((entry) => entry.name);
        expect(teamIds).toHaveLength(1);
        const teamId = teamIds[0]!;
        expect(teamId).toMatch(/^team-[0-9a-f]{24}$/);
        const manifestPath = join(
          teamsRoot,
          teamId,
          "manifest.json",
        );
        const initialManifest = JSON.parse(readFileSync(manifestPath, "utf8"));
        expect(initialManifest).toMatchObject({
          id: teamId,
          name: "My Team",
          latest_revision: 1,
          deleted: false,
        });
        const initialRevisionPath = join(
          home,
          ".fx",
          "extensions",
          "alt",
          "teams",
          teamId,
          `1-${initialManifest.latest_digest}.json`,
        );
        expect(existsSync(initialRevisionPath)).toBe(true);
        const initialTeam = JSON.parse(readFileSync(initialRevisionPath, "utf8"));
        expect(initialTeam.primary.id).toMatch(/^role-[0-9a-f]{24}$/);
        expect(initialTeam.peers[0].id).toMatch(/^role-[0-9a-f]{24}$/);
        expect(initialTeam.primary.id).not.toBe(initialTeam.peers[0].id);

        await session.sendText("/alt off");
        await session.waitForText("ALT mode disabled.", 5_000);
        await session.waitForComposer(5_000);
        await session.sendText("/alt teams");
        await session.waitForText("ALT Teams 1", 5_000);
        await session.sendKeys("Down");
        await session.sendKeys("Enter");
        await session.waitForText("Edit as a new revision", 5_000);
        await session.sendKeys("Down");
        await session.sendKeys("Enter");
        await session.waitForText("Configure a primary plus at least one peer or specialist.", 5_000);

        await session.sendKeys("Enter");
        await session.sendKeys("C-u");
        await session.sendText("Revised Team");
        await session.waitForPane(
          (pane) => pane.includes("› Name  Revised Team") && pane.includes("Save & start"),
          5_000,
        );
        for (const label of ["Provider", "Primary", "Peers", "Specialists", "Specialist access", "Save & start"]) {
          await session.sendKeys("Down");
          await session.waitForPane((pane) => pane.includes(`› ${label}`), 5_000);
        }
        await session.sendKeys("Enter");
        await session.waitForText("ALT mode enabled.", 5_000);
        await session.waitForComposer(5_000);
        await session.sendText("Persist a conversation on Team revision two.");
        await session.waitForText(TEAM_UX_SECOND_MARKER, 10_000);
        await session.waitForComposer(5_000);

        const revisedManifest = JSON.parse(readFileSync(manifestPath, "utf8"));
        expect(revisedManifest).toMatchObject({
          id: teamId,
          name: "Revised Team",
          latest_revision: 2,
          deleted: false,
        });
        expect(existsSync(join(
          home,
          ".fx",
          "extensions",
          "alt",
          "teams",
          teamId,
          `2-${revisedManifest.latest_digest}.json`,
        ))).toBe(true);

        await session.sendText("/alt off");
        await session.waitForText("ALT mode disabled.", 5_000);
        await session.waitForComposer(5_000);
        await session.sendText("/resume");
        await session.waitForText("ALT · Revised Team r2", 5_000);
        await session.waitForText("ALT · My Team r1", 5_000);
        await session.sendKeys("Escape");
        await session.waitForPane((pane) => !pane.includes("Sessions 2"), 5_000);
        await session.waitForComposer(5_000);

        await session.sendText("/alt teams");
        await session.waitForText("ALT Teams 1", 5_000);
        await session.sendKeys("Down");
        await session.sendKeys("Enter");
        await session.sendKeys("Down");
        await session.sendKeys("Down");
        await session.sendKeys("Enter");
        await session.waitForText("Delete Team?", 5_000);
        await session.sendKeys("Up");
        await session.sendKeys("Enter");
        await session.waitForText("ALT Teams 0", 5_000);
        expect(JSON.parse(readFileSync(manifestPath, "utf8"))).toMatchObject({
          latest_revision: 2,
          deleted: true,
        });

        await session.sendKeys("Escape");
        await session.waitForPane((pane) => !pane.includes("ALT Teams 0"), 5_000);
        await session.waitForComposer(5_000);
        await session.sendText("/alt");
        await session.waitForText("ALT mode enabled.", 5_000);
        await session.waitForComposer(5_000);
        expect(session.paneStatus()).toEqual({ dead: false, status: null });
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        session = null;
      } catch (error) {
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
          `${String(error)}\n\nstderr:\n${existsSync(stderrPath) ? readFileSync(stderrPath, "utf8") : "<missing>"}`,
        );
        const cleanupIndex = tempDirs.indexOf(root);
        if (cleanupIndex >= 0) tempDirs.splice(cleanupIndex, 1);
        console.error(`retained Team UX failure artifacts at ${root}`);
        throw error;
      } finally {
        provider.stop();
      }
    },
    TIMEOUT,
  );

  test(
    "enter leave and refusal paths preserve a live native fx session",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-orchestration-extension-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "causal.trace.log");
      mkdirSync(home);
      mkdirSync(workspace);
      seedAltEngineeringTeam(home);
      tempDirs.push(root);

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_DISABLE_KEYCHAIN: "1",
          FX_SKIP_ONBOARDING: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "orchestration",
          VERCEL_OIDC_TOKEN: undefined,
        },
      });
      try {
        await session.waitForComposer(10_000);
        expect(existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "").not.toContain(
          "event=activation_accepted",
        );

        await session.sendLiteral("/al");
        await session.waitForPane(
          (pane) =>
            pane.includes("/alt") &&
            pane.includes("resume ALT or manage Teams"),
          5_000,
        );
        await session.sendKeys("C-u");
        await session.waitForComposer(5_000);
        await enterSeededAlt(session);
        await session.waitForComposer(5_000);
        expect(session.paneStatus()).toEqual({ dead: false, status: null });

        for (const [command, expected] of [
          ["/alt", "ALT mode is already enabled."],
          ["/alt off", "ALT mode disabled."],
          ["/alt off", "ALT mode is already disabled."],
          ["/alt nonsense", "/alt [off|teams|new]"],
        ] as const) {
          await session.sendText(command);
          await session.waitForText(expected, 5_000);
          await session.waitForComposer(5_000);
          expect(session.paneStatus()).toEqual({ dead: false, status: null });
        }

        const trace = readFileSync(tracePath, "utf8");
        const expectedEvents = [
          "event=activation_accepted",
          "event=activation_idempotent",
          "event=deactivation_completed",
        ];
        let previousIndex = -1;
        for (const event of expectedEvents) {
          const index = trace.indexOf(event, previousIndex + 1);
          expect(index).toBeGreaterThan(previousIndex);
          previousIndex = index;
        }
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        session = null;
      } catch (error) {
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
            existsSync(stderrPath) ? readFileSync(stderrPath, "utf8") : "<missing>",
            "",
            "causal trace:",
            existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "<missing>",
          ].join("\n"),
        );
        const cleanupIndex = tempDirs.indexOf(root);
        if (cleanupIndex >= 0) tempDirs.splice(cleanupIndex, 1);
        console.error(`retained orchestration failure artifacts at ${root}`);
        throw error;
      }
    },
    TIMEOUT,
  );

  test(
    "ordinary ALT input steers the held run through the native queue",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-orchestration-queue-"));
      const home = join(root, "home");
      const fxHome = join(home, ".fx");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "causal.trace.log");
      mkdirSync(fxHome, { recursive: true, mode: 0o700 });
      mkdirSync(workspace);
      seedAltEngineeringTeam(home);
      writeFileSync(
        join(fxHome, "opencode-auth.json"),
        `${JSON.stringify({ schema_version: 1, api_key: "opencode-queue-fixture" })}\n`,
        { mode: 0o600 },
      );
      tempDirs.push(root);
      const provider = startHeldOpenCodeSteeringServer();
      const replacement =
        "REPLACEMENT ALT INSTRUCTION MUST STEER THE HELD RUN";

      try {
        session = await TmuxSession.create({
          cwd: workspace,
          stderrPath,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_E2E_OPENCODE_CHAT_URL: provider.chatUrl,
            FX_SKIP_ONBOARDING: "1",
            FX_TRACE_LOG: tracePath,
            FX_TRACE_SCOPES: "orchestration,agent,provider,worker,input",
            OPENCODE_API_KEY: undefined,
          },
        });
        await session.waitForComposer(10_000);
        await enterSeededAlt(session);
        await session.sendText("FIRST ALT TURN HELD BY THE PROVIDER");
        await waitForFileText(tracePath, "event=agent_run_started", 10_000);
        expect(provider.requestBodies).toHaveLength(1);

        // Plain Enter is steering during an active turn, so the held run is
        // interrupted and the replacement instruction is committed to the same
        // ALT session instead of starting a second concurrent turn.
        await session.sendText(replacement);
        const steeringTrace = await waitForFileText(
          tracePath,
          "event=user_instruction_committed",
          10_000,
        );
        expect(steeringTrace).toContain("event=agent_run_interrupted");
        await session.waitForText(STEERING_MARKER, 10_000);
        await session.waitForComposer(10_000);
        expect(provider.requestBodies).toHaveLength(2);
        expect(provider.requestBodies[1]).toContain(replacement);
        expect((steeringTrace.match(/event=session_created/g) ?? []).length).toBe(1);
        expect(session.paneStatus()).toEqual({ dead: false, status: null });
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        session = null;
      } finally {
        provider.stop();
      }
    },
    TIMEOUT,
  );

  test(
    "an active ALT turn accepts a canonical instruction and replaces its held run",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-orchestration-steering-"));
      const home = join(root, "home");
      const fxHome = join(home, ".fx");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "causal.trace.log");
      mkdirSync(fxHome, { recursive: true, mode: 0o700 });
      mkdirSync(workspace);
      seedAltEngineeringTeam(home);
      const authPath = join(fxHome, "opencode-auth.json");
      writeFileSync(
        authPath,
        `${JSON.stringify({
          schema_version: 1,
          api_key: "opencode-steering-fixture",
        })}\n`,
        { mode: 0o600 },
      );
      chmodSync(authPath, 0o600);
      tempDirs.push(root);
      const provider = startHeldOpenCodeSteeringServer();

      try {
        session = await TmuxSession.create({
          cwd: workspace,
          stderrPath,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_E2E_OPENCODE_CHAT_URL: provider.chatUrl,
            FX_SKIP_ONBOARDING: "1",
            FX_TRACE_LOG: tracePath,
            FX_TRACE_SCOPES: "orchestration,agent,provider,worker,interrupt",
            OPENCODE_API_KEY: undefined,
          },
        });
        await session.waitForComposer(10_000);
        await enterSeededAlt(session);
        await session.sendText("ROOT ALT REQUEST THAT MUST REMAIN CANONICAL");
        await waitForFileText(tracePath, "event=agent_run_started", 10_000);

        await sendSteering(session,
          `IN-SESSION STEERING: replace the held work and answer with ${STEERING_MARKER}`,
        );
        const trace = await waitForFileText(
          tracePath,
          "event=answer_published",
          15_000,
        );
        await session.waitForText(STEERING_MARKER, 10_000);
        await session.waitForComposer(10_000);

        expect(provider.requestBodies.length).toBeGreaterThanOrEqual(2);
        const replacementRequest = provider.requestBodies[1];
        expect(replacementRequest).toContain("ROOT ALT REQUEST THAT MUST REMAIN CANONICAL");
        expect(replacementRequest).toContain("IN-SESSION STEERING");
        const lifecycle = [
          "event=agent_run_interrupted",
          "event=user_instruction_committed",
          "event=agent_run_requested",
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

        await session.sendText(
          "Start the next ALT turn and use the durable conversation view.",
        );
        const followupTrace = await waitForFileOccurrences(
          tracePath,
          /event=answer_published/g,
          2,
          15_000,
        );
        await session.waitForText(STEERING_FOLLOWUP_MARKER, 10_000);
        await session.waitForComposer(10_000);
        expect(provider.requestBodies.length).toBeGreaterThanOrEqual(3);
        const followupRequest = provider.requestBodies[2];
        expect(followupRequest).toContain("ROOT ALT REQUEST THAT MUST REMAIN CANONICAL");
        expect(followupRequest).toContain("IN-SESSION STEERING");
        expect(followupRequest).toContain(STEERING_MARKER);
        expect(followupTrace.match(/event=session_created/g)?.length).toBe(2);
        expect(followupTrace.match(/event=answer_published/g)?.length).toBe(2);

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        session = null;
      } catch (error) {
        if (session) {
          writeFileSync(
            join(root, "failure-scrollback.txt"),
            await session.captureFullScrollback(),
          );
        }
        writeFileSync(
          join(root, "failure-summary.txt"),
          [
            String(error),
            "",
            "stderr:",
            existsSync(stderrPath) ? readFileSync(stderrPath, "utf8") : "<missing>",
            "",
            "causal trace:",
            existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "<missing>",
            "",
            `provider request count: ${provider.requestBodies.length}`,
          ].join("\n"),
        );
        const cleanupIndex = tempDirs.indexOf(root);
        if (cleanupIndex >= 0) tempDirs.splice(cleanupIndex, 1);
        console.error(`retained steering failure artifacts at ${root}`);
        throw error;
      } finally {
        provider.stop();
      }
    },
    TIMEOUT,
  );

  test(
    "an invalid semantic transition gets one evidence-bearing correction run",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-orchestration-correction-"));
      const home = join(root, "home");
      const fxHome = join(home, ".fx");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "causal.trace.log");
      mkdirSync(fxHome, { recursive: true, mode: 0o700 });
      mkdirSync(workspace);
      seedAltEngineeringTeam(home);
      const authPath = join(fxHome, "opencode-auth.json");
      writeFileSync(
        authPath,
        `${JSON.stringify({ schema_version: 1, api_key: "opencode-correction-fixture" })}\n`,
        { mode: 0o600 },
      );
      chmodSync(authPath, 0o600);
      tempDirs.push(root);
      const provider = startOpenCodeCorrectionServer();

      try {
        session = await TmuxSession.create({
          cwd: workspace,
          stderrPath,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_E2E_OPENCODE_CHAT_URL: provider.chatUrl,
            FX_SKIP_ONBOARDING: "1",
            FX_TRACE_LOG: tracePath,
            FX_TRACE_SCOPES: "orchestration,agent,provider,worker",
            OPENCODE_API_KEY: undefined,
          },
        });
        await session.waitForComposer(10_000);
        await enterSeededAlt(session);
        await session.sendText("Exercise semantic protocol correction.");
        const trace = await waitForFileText(tracePath, "event=answer_published", 15_000);
        await session.waitForText(CORRECTION_MARKER, 10_000);
        await session.waitForComposer(10_000);

        expect(provider.requestBodies.length).toBe(2);
        expect(provider.requestBodies[1]).toContain("unauthorized_handoff");
        expect(provider.requestBodies[1]).toContain("intruder");
        const correction = trace.indexOf("event=agent_protocol_correction_requested");
        const answer = trace.indexOf("event=answer_published", correction + 1);
        expect(correction).toBeGreaterThanOrEqual(0);
        expect(answer).toBeGreaterThan(correction);
        expect(trace).not.toContain("event=agent_protocol_rejected");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        expect(session.paneStatus()).toEqual({ dead: false, status: null });

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        session = null;
      } catch (error) {
        if (session) {
          writeFileSync(
            join(root, "failure-scrollback.txt"),
            await session.captureFullScrollback(),
          );
        }
        writeFileSync(
          join(root, "failure-summary.txt"),
          [
            String(error),
            "",
            "stderr:",
            existsSync(stderrPath) ? readFileSync(stderrPath, "utf8") : "<missing>",
            "",
            "causal trace:",
            existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "<missing>",
            "",
            `provider request count: ${provider.requestBodies.length}`,
          ].join("\n"),
        );
        const cleanupIndex = tempDirs.indexOf(root);
        if (cleanupIndex >= 0) tempDirs.splice(cleanupIndex, 1);
        console.error(`retained correction failure artifacts at ${root}`);
        throw error;
      } finally {
        provider.stop();
      }
    },
    TIMEOUT,
  );

  test(
    "a resumed leader retains its exact pre-consultation fx tool trajectory",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-orchestration-continuity-"));
      const home = join(root, "home");
      const fxHome = join(home, ".fx");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "causal.trace.log");
      mkdirSync(fxHome, { recursive: true, mode: 0o700 });
      mkdirSync(workspace);
      seedAltEngineeringTeam(home);
      writeFileSync(join(workspace, "continuity-sentinel.txt"), `${CONTINUITY_FILE_SENTINEL}\n`);
      const authPath = join(fxHome, "opencode-auth.json");
      writeFileSync(
        authPath,
        `${JSON.stringify({ schema_version: 1, api_key: "opencode-continuity-fixture" })}\n`,
        { mode: 0o600 },
      );
      chmodSync(authPath, 0o600);
      tempDirs.push(root);
      const provider = startOpenCodeContinuityServer();
      const exactRoot = "Read the continuity sentinel, consult the authorized peer, then answer.";

      try {
        session = await TmuxSession.create({
          cwd: workspace,
          stderrPath,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_E2E_OPENCODE_CHAT_URL: provider.chatUrl,
            FX_SKIP_ONBOARDING: "1",
            FX_TRACE_LOG: tracePath,
            FX_TRACE_SCOPES: "orchestration,agent,provider,worker,tool",
            OPENCODE_API_KEY: undefined,
          },
        });
        await session.waitForComposer(10_000);
        await enterSeededAlt(session);
        await session.sendText(exactRoot);
        await waitForFileText(tracePath, "event=answer_published", 20_000);
        await session.waitForText(CONTINUITY_MARKER, 10_000);
        await session.waitForComposer(10_000);

        expect(provider.requestBodies.length).toBe(4);
        expect(provider.requestBodies[1]).toContain(CONTINUITY_FILE_SENTINEL);
        const resumedLeader = provider.requestBodies[3];
        expect(resumedLeader).toContain(CONTINUITY_FILE_SENTINEL);
        expect(resumedLeader).toContain("call_continuity_read");
        expect(resumedLeader).toContain(CONTINUITY_PEER_SENTINEL);
        expect(resumedLeader.split(exactRoot).length - 1).toBe(1);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        expect(session.paneStatus()).toEqual({ dead: false, status: null });

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        session = null;
      } catch (error) {
        if (session) {
          writeFileSync(
            join(root, "failure-scrollback.txt"),
            await session.captureFullScrollback(),
          );
        }
        writeFileSync(
          join(root, "failure-summary.txt"),
          [
            String(error),
            "",
            "stderr:",
            existsSync(stderrPath) ? readFileSync(stderrPath, "utf8") : "<missing>",
            "",
            "causal trace:",
            existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "<missing>",
            "",
            `provider request count: ${provider.requestBodies.length}`,
          ].join("\n"),
        );
        const cleanupIndex = tempDirs.indexOf(root);
        if (cleanupIndex >= 0) tempDirs.splice(cleanupIndex, 1);
        console.error(`retained continuity failure artifacts at ${root}`);
        throw error;
      } finally {
        provider.stop();
      }
    },
    TIMEOUT,
  );

  test(
    "failed Team work returns typed evidence to the leader instead of killing the turn",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-orchestration-team-failure-"));
      const home = join(root, "home");
      const fxHome = join(home, ".fx");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "causal.trace.log");
      mkdirSync(fxHome, { recursive: true, mode: 0o700 });
      mkdirSync(workspace);
      seedAltEngineeringTeam(home);
      const authPath = join(fxHome, "opencode-auth.json");
      writeFileSync(
        authPath,
        `${JSON.stringify({ schema_version: 1, api_key: "opencode-team-failure-fixture" })}\n`,
        { mode: 0o600 },
      );
      chmodSync(authPath, 0o600);
      tempDirs.push(root);
      const provider = startOpenCodeTeamFailureServer();

      try {
        session = await TmuxSession.create({
          cwd: workspace,
          stderrPath,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_E2E_OPENCODE_CHAT_URL: provider.chatUrl,
            FX_SKIP_ONBOARDING: "1",
            FX_TRACE_LOG: tracePath,
            FX_TRACE_SCOPES: "orchestration,agent,provider,worker",
            OPENCODE_API_KEY: undefined,
          },
        });
        await session.waitForComposer(10_000);
        await enterSeededAlt(session);
        await session.sendText("Exercise Team failure recovery.");
        const trace = await waitForFileText(tracePath, "event=answer_published", 15_000);
        await session.waitForText(TEAM_FAILURE_MARKER, 10_000);
        await session.waitForComposer(10_000);

        expect(provider.requestBodies.length).toBe(4);
        expect(provider.requestBodies[2]).toContain("invalid_consultation_result");
        expect(provider.requestBodies[2]).toContain("malformed peer result sentinel");
        expect(provider.requestBodies[3]).toContain("peer returned an invalid consultation result");
        expect(provider.requestBodies[3]).toContain('\\"status\\":\\"failed\\"');
        expect(trace).toContain("event=peer_consultation_failed");
        expect(trace).toContain("event=answer_published");
        expect(trace).not.toContain("event=agent_protocol_rejected");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        expect(session.paneStatus()).toEqual({ dead: false, status: null });

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        session = null;
      } catch (error) {
        if (session) {
          writeFileSync(
            join(root, "failure-scrollback.txt"),
            await session.captureFullScrollback(),
          );
        }
        writeFileSync(
          join(root, "failure-summary.txt"),
          [
            String(error),
            "",
            "stderr:",
            existsSync(stderrPath) ? readFileSync(stderrPath, "utf8") : "<missing>",
            "",
            "causal trace:",
            existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "<missing>",
            "",
            `provider request count: ${provider.requestBodies.length}`,
          ].join("\n"),
        );
        const cleanupIndex = tempDirs.indexOf(root);
        if (cleanupIndex >= 0) tempDirs.splice(cleanupIndex, 1);
        console.error(`retained Team-failure artifacts at ${root}`);
        throw error;
      } finally {
        provider.stop();
      }
    },
    TIMEOUT,
  );

  test(
    "a consulted peer can call its specialist and only its synthesis unwinds to the leader",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-orchestration-nested-team-"));
      const home = join(root, "home");
      const fxHome = join(home, ".fx");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "causal.trace.log");
      mkdirSync(fxHome, { recursive: true, mode: 0o700 });
      mkdirSync(workspace);
      seedAltEngineeringTeam(home);
      writeFileSync(
        join(workspace, "nested-specialist-sentinel.txt"),
        `${NESTED_SPECIALIST_RAW}\n`,
      );
      const authPath = join(fxHome, "opencode-auth.json");
      writeFileSync(
        authPath,
        `${JSON.stringify({ schema_version: 1, api_key: "opencode-nested-team-fixture" })}\n`,
        { mode: 0o600 },
      );
      chmodSync(authPath, 0o600);
      tempDirs.push(root);
      const provider = startOpenCodeNestedTeamServer();
      const exactRoot = "Exercise recursive Team ownership through a consultant specialist.";

      try {
        session = await TmuxSession.create({
          cwd: workspace,
          stderrPath,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_E2E_OPENCODE_CHAT_URL: provider.chatUrl,
            FX_SKIP_ONBOARDING: "1",
            FX_TRACE_LOG: tracePath,
            FX_TRACE_SCOPES: "orchestration,agent,provider,worker",
            OPENCODE_API_KEY: undefined,
          },
        });
        await session.waitForComposer(10_000);
        await enterSeededAlt(session);
        await session.sendText(exactRoot);
        const trace = await waitForFileText(tracePath, "event=answer_published", 20_000);
        await session.waitForText(NESTED_ANSWER_MARKER, 10_000);
        await session.waitForComposer(10_000);

        const transcript = await session.captureFullScrollback();
        expect(transcript).toContain("go/kimi-k3 → go/deepseek-v4-flash · consultation started.");
        expect(transcript).toContain("go/deepseek-v4-flash → go/mimo-v2.5 · specialist started.");
        expect(transcript).toContain("go/mimo-v2.5 → go/deepseek-v4-flash · specialist returned.");
        expect(transcript).toContain("go/deepseek-v4-flash → go/kimi-k3 · consultation returned.");

        expect(provider.requestBodies.length).toBe(6);
        const specialistRequest = provider.requestBodies[2];
        expect(specialistRequest).toContain("nested-specialist-sentinel.txt");
        expect(specialistRequest).not.toContain(exactRoot);
        const specialistAfterTool = provider.requestBodies[3];
        expect(specialistAfterTool).toContain("call_nested_specialist_read");
        expect(specialistAfterTool).toContain(NESTED_SPECIALIST_RAW);
        const resumedConsultant = provider.requestBodies[4];
        expect(resumedConsultant).toContain(NESTED_SPECIALIST_RAW);
        const resumedLeader = provider.requestBodies[5];
        expect(resumedLeader).toContain(NESTED_PEER_SYNTHESIS);
        expect(resumedLeader).not.toContain(NESTED_SPECIALIST_RAW);
        expect(trace).toContain("event=peer_consultation_suspended");
        expect(trace).toContain("event=specialist_run_completed");
        expect(trace.match(/event=team_coordination_completed/g)?.length).toBe(2);
        const suspended = trace.indexOf("event=peer_consultation_suspended");
        const specialistCompleted = trace.indexOf("event=specialist_run_completed", suspended);
        const peerCompleted = trace.indexOf("event=peer_consultation_completed", specialistCompleted);
        const answered = trace.indexOf("event=answer_published", peerCompleted);
        expect(suspended).toBeGreaterThanOrEqual(0);
        expect(specialistCompleted).toBeGreaterThan(suspended);
        expect(peerCompleted).toBeGreaterThan(specialistCompleted);
        expect(answered).toBeGreaterThan(peerCompleted);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        expect(session.paneStatus()).toEqual({ dead: false, status: null });

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        session = null;
      } catch (error) {
        if (session) {
          writeFileSync(
            join(root, "failure-scrollback.txt"),
            await session.captureFullScrollback(),
          );
        }
        writeFileSync(
          join(root, "failure-summary.txt"),
          [
            String(error),
            "",
            "stderr:",
            existsSync(stderrPath) ? readFileSync(stderrPath, "utf8") : "<missing>",
            "",
            "causal trace:",
            existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "<missing>",
            "",
            `provider request count: ${provider.requestBodies.length}`,
          ].join("\n"),
        );
        const cleanupIndex = tempDirs.indexOf(root);
        if (cleanupIndex >= 0) tempDirs.splice(cleanupIndex, 1);
        console.error(`retained nested-Team artifacts at ${root}`);
        throw error;
      } finally {
        provider.stop();
      }
    },
    TIMEOUT,
  );
});
