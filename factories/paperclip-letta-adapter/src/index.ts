/**
 * letta_local — Paperclip adapter that drives the LIVE sudo-letta agent (k8s).
 *
 * v0.2.0 — ONE JOB: a Paperclip heartbeat must run its prompt INSIDE the live
 * `deploy/sudo-<agent>` pod (the one `stream.sh --<agent>` tails), NOT in a
 * detached clone.
 *
 * The bug v0.1.x shipped: it spawned `letta -p` locally against a COPIED letta
 * home that lived inside the Paperclip pod (`/paperclip/letta-bin/letta` +
 * `/paperclip/letta-home`). That "worked" — exit 0, vLLM lit up — but it ran a
 * private clone of the agent whose conversations the live deployment never saw,
 * so `stream.sh` on the real pod showed nothing.
 *
 * Now `execute()` speaks MCP (streamable HTTP) to the running agent's OWN MCP
 * door — the `letta_prompt` tool of `sudo-<agent>-mcp.<namespace>.svc.cluster.local`
 * — so the prompt is enqueued and executed by the live deployment itself
 * (in-pod `mcp_server.py` -> drain worker -> `letta -p` inside that pod). GPU
 * activity, the pod's `events.jsonl` and `stream.sh` all reflect the run.
 *
 * There is deliberately NO local-spawn fallback: if the live door is unreachable
 * the run FAILS LOUDLY rather than silently executing a clone again.
 *
 * adapterConfig:
 *   mcpUrl      MCP endpoint of the live agent (default: derived from agentName,
 *               else the live ONalwase door)
 *   mcpTool     MCP tool to call (default "letta_prompt")
 *   mode        "direct" (wait for the reply — default) | "inbox" (enqueue only)
 *   newChat     start a fresh conversation (default false = resume the agent's chat)
 *   namespace   k8s namespace of the live deployment (default "sudo-fleet")
 *   timeoutSec  hard cap on the whole MCP conversation (default 600)
 *   agentName   derives the door hostname (ONalwase -> sudo-onalwase-mcp)
 *
 * Legacy keys (agentId / lettaPath / home / backend / extraArgs) are accepted
 * but IGNORED: the live pod is the authority for its own agent id, home and
 * backend. Keeping them accepted means existing agent records do not need to be
 * rewritten for the fix to take effect.
 */

import { appendFileSync } from "node:fs";

const ADAPTER_VERSION = "0.2.0";
const TRACE_PATH = process.env.PAPERCLIP_LETTA_TRACE ?? "/paperclip/adapter-trace.log";

function trace(line: string): void {
  try {
    appendFileSync(TRACE_PATH, new Date().toISOString() + " " + line + "\n");
  } catch {
    /* tracing must never break a run */
  }
}

const DEFAULT_NAMESPACE = "sudo-fleet";
const DEFAULT_TOOL = "letta_prompt";
const DEFAULT_TIMEOUT_SEC = 600;
/** Last-resort door: the live ONalwase deployment (namespace sudo-fleet). */
const FALLBACK_MCP_URL = "http://sudo-onalwase-mcp.sudo-fleet.svc.cluster.local:8000/mcp";

export interface LettaLocalAgentConfig {
  mcpUrl?: string;
  mcpTool?: string;
  mode?: "direct" | "inbox";
  newChat?: boolean;
  namespace?: string;
  timeoutSec?: number;
  agentName?: string;
  // legacy keys — accepted, ignored (the live pod owns these)
  agentId?: string;
  lettaPath?: string;
  home?: string;
  cwd?: string;
  backend?: "local" | "cloud";
  extraArgs?: string[];
}

export interface LettaLocalRunResult {
  stdout: string;
  stderr: string;
  exitCode: number;
  timedOut: boolean;
  durationMs: number;
  url?: string;
}

// --------------------------------------------------------------------------
// Paperclip execution-context resolution
// (the real ServerAdapterModule contract hands us `ctx.context`, not `ctx.prompt`)
// --------------------------------------------------------------------------

function resolveConfig(ctx: any): LettaLocalAgentConfig {
  return (
    ctx?.agentConfig ??
    ctx?.agent?.adapterConfig ??
    ctx?.config?.adapterConfig ??
    {}
  );
}

/** Build the task prompt from Paperclip's execution context. */
function resolvePrompt(ctx: any): string {
  const c = ctx && ctx.context && typeof ctx.context === "object" ? ctx.context : {};
  const wake = c.paperclipWake && typeof c.paperclipWake === "object" ? c.paperclipWake : {};
  const issue =
    wake.issue && typeof wake.issue === "object"
      ? wake.issue
      : c.issue && typeof c.issue === "object"
        ? c.issue
        : null;
  const cont =
    c.executionContinuation && typeof c.executionContinuation === "object"
      ? c.executionContinuation
      : wake.executionContinuation && typeof wake.executionContinuation === "object"
        ? wake.executionContinuation
        : {};

  const bits: string[] = [];
  const push = (label: string, v: unknown) => {
    if (typeof v === "string" && v.trim()) bits.push(label + ": " + v.trim());
  };
  push("Objective", cont.objective);
  if (issue) {
    push("Task", issue.title);
    push("Details", issue.description);
    push("Task id", issue.identifier || issue.id);
    push("Task status", issue.status);
  }
  push("Wake reason", wake.reason || c.wakeReason);
  push("Wake source", wake.wakeSource || c.wakeSource);
  push("Agent message", wake.agentMessage);
  if (bits.length <= 2) {
    try {
      const slim: any = { ...c };
      delete slim.paperclipEnvironment;
      delete slim.paperclipRuntimeTools;
      bits.push("Paperclip run context:\n" + JSON.stringify(slim, null, 1).slice(0, 5000));
    } catch {
      /* best effort */
    }
  }
  return bits.join("\n\n");
}

// --------------------------------------------------------------------------
// MCP (streamable HTTP) client — initialize -> notifications/initialized -> tools/call
// --------------------------------------------------------------------------

type McpSession = { id?: string };

function decodeMcpBody(raw: string): any {
  const text = (raw ?? "").trim();
  if (!text) return {};
  if (text.startsWith("event:") || text.startsWith("data:")) {
    for (const line of text.split("\n")) {
      if (line.startsWith("data:")) {
        const chunk = line.slice(5).trim();
        if (!chunk) continue;
        try {
          return JSON.parse(chunk);
        } catch {
          continue;
        }
      }
    }
    return {};
  }
  try {
    return JSON.parse(text);
  } catch {
    return {};
  }
}

const fetchFn: any = (globalThis as any).fetch;
const AbortCtor: any = (globalThis as any).AbortController;

async function mcpPost(url: string, payload: unknown, session: McpSession, timeoutMs: number): Promise<any> {
  if (typeof fetchFn !== "function") {
    throw new Error("global fetch unavailable (adapter needs Node >= 18)");
  }
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json, text/event-stream",
  };
  if (session.id) headers["Mcp-Session-Id"] = session.id;

  let signal: any;
  let timer: any;
  if (typeof AbortCtor === "function") {
    const ctl = new AbortCtor();
    signal = ctl.signal;
    timer = setTimeout(() => ctl.abort(), timeoutMs);
  }
  try {
    const res = await fetchFn(url, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
      ...(signal ? { signal } : {}),
    });
    const sid = res.headers.get("mcp-session-id");
    if (sid) session.id = sid;
    const raw = await res.text();
    if (!res.ok) throw new Error(`HTTP ${res.status}: ${raw.slice(0, 200)}`);
    return decodeMcpBody(raw);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function mcpRpc(
  url: string,
  method: string,
  params: unknown,
  session: McpSession,
  timeoutMs: number,
): Promise<any> {
  const reply = await mcpPost(url, { jsonrpc: "2.0", id: method, method, params }, session, timeoutMs);
  if (reply && reply.error) throw new Error(`MCP ${method} failed: ${JSON.stringify(reply.error)}`);
  return reply ? reply.result : reply;
}

async function mcpNotify(
  url: string,
  method: string,
  params: unknown,
  session: McpSession,
  timeoutMs: number,
): Promise<void> {
  try {
    await mcpPost(url, { jsonrpc: "2.0", method, params }, session, timeoutMs);
  } catch {
    /* an ignored notification must never sink the call */
  }
}

/** Unwrap an MCP tools/call result to its useful payload. */
function unwrapToolResult(result: any): any {
  if (!result || typeof result !== "object") return result;
  const content = result.content;
  if (Array.isArray(content)) {
    const parts = content
      .filter((c: any) => c && c.type === "text")
      .map((c: any) => String(c.text ?? ""));
    if (parts.length) {
      const text = parts.join("\n");
      try {
        return JSON.parse(text);
      } catch {
        return text;
      }
    }
  }
  return result;
}

/** Candidate doors, most specific first. */
function doorCandidates(cfg: LettaLocalAgentConfig): string[] {
  const urls: string[] = [];
  if (cfg.mcpUrl) urls.push(cfg.mcpUrl);
  const ns = cfg.namespace ?? DEFAULT_NAMESPACE;
  const name = (cfg.agentName ?? "").trim().toLowerCase();
  if (name) urls.push(`http://sudo-${name}-mcp.${ns}.svc.cluster.local:8000/mcp`);
  urls.push(FALLBACK_MCP_URL);
  return [...new Set(urls.filter(Boolean))];
}

/**
 * Run ONE prompt on the LIVE agent over MCP. Tries each candidate door; the
 * first one that answers wins. Returns a spawn-shaped result so the rest of the
 * adapter (and Paperclip) is unchanged.
 */
export async function runLettaLive(
  config: LettaLocalAgentConfig,
  prompt: string,
): Promise<LettaLocalRunResult> {
  const started = Date.now();
  const timeoutMs = (config.timeoutSec ?? DEFAULT_TIMEOUT_SEC) * 1000;
  const tool = config.mcpTool ?? DEFAULT_TOOL;
  const mode = config.mode ?? "direct";
  const candidates = doorCandidates(config);

  const errors: string[] = [];
  let timedOut = false;

  for (const url of candidates) {
    const session: McpSession = {};
    try {
      const init = await mcpRpc(
        url,
        "initialize",
        {
          protocolVersion: "2024-11-05",
          capabilities: {},
          clientInfo: { name: "paperclip-letta-local", version: ADAPTER_VERSION },
        },
        session,
        Math.min(15000, timeoutMs),
      );
      await mcpNotify(url, "notifications/initialized", {}, session, 5000);
      trace(
        "MCP-INIT url=" +
          url +
          " server=" +
          JSON.stringify(init?.serverInfo ?? null) +
          " sid=" +
          (session.id ?? "-"),
      );

      const result = await mcpRpc(
        url,
        "tools/call",
        { name: tool, arguments: { prompt, new_chat: config.newChat === true, mode } },
        session,
        timeoutMs,
      );
      const out = unwrapToolResult(result);
      const text = typeof out === "string" ? out : JSON.stringify(out, null, 2);
      const isError = !!(result && (result as any).isError);
      trace("MCP-DONE url=" + url + " mode=" + mode + " out=" + text.length + " isError=" + isError);
      return {
        stdout: text,
        stderr: isError ? `MCP tool ${tool} reported an error` : "",
        exitCode: isError ? 1 : 0,
        timedOut: false,
        durationMs: Date.now() - started,
        url,
      };
    } catch (e: any) {
      const msg = String(e?.message ?? e);
      if (String(e?.name) === "AbortError" || /abort/i.test(msg) || /timed? ?out/i.test(msg)) {
        timedOut = true;
      }
      errors.push(`${url} -> ${msg}`);
      trace("MCP-FAIL url=" + url + " " + msg);
    }
  }

  return {
    stdout: "",
    stderr: "no live MCP door answered: " + errors.join(" | "),
    exitCode: 1,
    timedOut,
    durationMs: Date.now() - started,
  };
}

// --------------------------------------------------------------------------
// The Paperclip ServerAdapterModule
// --------------------------------------------------------------------------

/**
 * Factory entry — Paperclip's plugin loader imports the package root and calls
 * `createServerAdapter()` to get the ServerAdapterModule.
 */
export function createServerAdapter(): any {
  return {
    type: "letta_local",

    models: [{ id: "letta-local", name: "Letta Code (live k8s agent)" }],

    runtimeToolDelivery: "invocation_context",

    agentConfigurationDoc: {
      mcpUrl: { type: "string", required: false, description: "MCP endpoint of the LIVE agent (default: derived from agentName, else the sudo-onalwase door)" },
      mcpTool: { type: "string", required: false, description: `MCP tool to call (default ${DEFAULT_TOOL})` },
      mode: { type: "string", required: false, description: '"direct" (wait for reply, default) or "inbox" (enqueue only)' },
      newChat: { type: "boolean", required: false, description: "Start a fresh conversation (default false = resume)" },
      namespace: { type: "string", required: false, description: `k8s namespace of the live deployment (default ${DEFAULT_NAMESPACE})` },
      agentName: { type: "string", required: false, description: "Agent name; derives sudo-<name>-mcp.<namespace>.svc.cluster.local" },
      timeoutSec: { type: "number", required: false, description: `Hard cap on the MCP conversation (default ${DEFAULT_TIMEOUT_SEC})` },
    },

    async execute(ctx: any) {
      const cfg = resolveConfig(ctx);
      const prompt = resolvePrompt(ctx);
      const startedAt = new Date().toISOString();

      trace(
        "PROMPT(live-mcp) doors=" +
          JSON.stringify(doorCandidates(cfg)) +
          " " +
          JSON.stringify(prompt).slice(0, 400),
      );

      try {
        ctx.onDispatch?.();
      } catch {
        /* optional hook */
      }

      const res = await runLettaLive(cfg, prompt);

      try {
        ctx.onLog?.("stdout", res.stdout);
        if (res.stderr) ctx.onLog?.("stderr", res.stderr);
      } catch {
        /* optional hook */
      }

      trace(
        "CLOSE exit=" +
          res.exitCode +
          " out=" +
          res.stdout.length +
          " err=" +
          res.stderr.length +
          " url=" +
          (res.url ?? "-"),
      );

      return {
        exitCode: res.exitCode,
        signal: null,
        timedOut: res.timedOut,
        ...(res.exitCode !== 0
          ? { errorMessage: res.stderr.trim() || `live MCP run exited ${res.exitCode}` }
          : {}),
        status: res.exitCode === 0 ? "success" : "error",
        output: res.stdout,
        ...(res.exitCode !== 0 ? { error: res.stderr.trim() } : {}),
        startedAt,
        resultJson: { stdout: res.stdout, stderr: res.stderr, url: res.url ?? null, durationMs: res.durationMs },
      };
    },

    async testEnvironment(ctx: any) {
      const cfg = resolveConfig(ctx);
      const res = await runLettaLive(
        { ...cfg, timeoutSec: Math.min(cfg.timeoutSec ?? 60, 120) },
        "Reply with exactly: PAPERCLIP LIVE DOOR OK",
      );
      return {
        ok: res.exitCode === 0,
        message:
          res.exitCode === 0
            ? `live agent answered via ${res.url} (${res.durationMs}ms)`
            : `live MCP door failed: ${res.stderr}`,
      };
    },
  };
}

export default createServerAdapter;
