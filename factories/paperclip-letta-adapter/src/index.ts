/**
 * letta_local — Paperclip adapter for Letta Code agents running on the
 * LOCAL backend (no `letta server` required).
 *
 * Mechanism (mirrors hermes_local): spawn `letta -p "<prompt>" --backend local
 * --agent <id>` headlessly, capture the reply + token usage, and report back as
 * an AdapterExecutionResult. The agent runs whatever model it is already
 * configured for (e.g. Qwen3.8-27B on the local A6000 vLLM) — this adapter does
 * NOT bind a model; it just drives the existing local agent.
 *
 * Contract: implements ServerAdapterModule from `@paperclipai/adapter-utils`.
 */

import { spawn } from "node:child_process";

// ---- Types (kept local/loose so this compiles without a hard adapter-utils
// import at authoring time; align to the real package on install) ----
export interface LettaLocalAgentConfig {
  /** The agent id to target (`--agent <id>`). */
  agentId?: string;
  /** Optional agent name (resolved on the letta side if agentId omitted). */
  agentName?: string;
  /** Path to the letta CLI. Defaults to `letta` on PATH. */
  lettaPath?: string;
  /** HOME for the child (the Letta local backend + agents live under /home/node/.letta). */
  home?: string;
  /** Seconds before the child is killed. */
  timeoutSec?: number;
  /** Backend mode; almost always "local". */
  backend?: "local" | "cloud";
  /** Extra args appended to the spawn. */
  extraArgs?: string[];
}

export interface LettaLocalRunResult {
  stdout: string;
  stderr: string;
  exitCode: number;
  timedOut: boolean;
  durationMs: number;
}

interface AdapterExecutionContextLike {
  agentName: string;
  agentConfig: unknown;
  prompt: string;
  sessionId?: string | null;
  heartbeatContext?: unknown;
}

interface AdapterExecutionResultLike {
  status: "success" | "error";
  output?: string;
  error?: string;
  tokenUsage?: { input?: number; output?: number; total?: number };
  session?: Record<string, unknown> | null;
  displayId?: string;
}

/** Run a `letta -p` headless prompt against the local backend. */
export async function runLettaLocal(
  config: LettaLocalAgentConfig,
  prompt: string,
): Promise<LettaLocalRunResult> {
  const letta = config.lettaPath ?? "letta";
  const args = [
    "--backend", config.backend ?? "local",
    ...(config.agentId ? ["--agent", config.agentId] : []),
    "-p", prompt,
    ...(config.extraArgs ?? []),
  ];

  return await new Promise<LettaLocalRunResult>((resolve) => {
    const start = Date.now();
    const timeoutMs = (config.timeoutSec ?? 600) * 1000;
    const child = spawn(letta, args, {
      env: { ...process.env, ...(config.home ? { HOME: config.home } : {}) },
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let timedOut = false;

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
    }, timeoutMs);

    child.stdout.on("data", (d) => (stdout += d.toString()));
    child.stderr.on("data", (d) => (stderr += d.toString()));

    child.on("close", (exitCode) => {
      clearTimeout(timer);
      resolve({
        stdout,
        stderr,
        exitCode: exitCode ?? -1,
        timedOut,
        durationMs: Date.now() - start,
      });
    });

    child.on("error", (err) => {
      clearTimeout(timer);
      resolve({
        stdout,
        stderr: stderr + String(err),
        exitCode: -1,
        timedOut,
        durationMs: Date.now() - start,
      });
    });
  });
}

/** Best-effort token-usage estimate (letta CLI does not emit token counts in
 * `-p` text mode; we return null rather than fabricate). */
function estimateUsage(): { input?: number; output?: number; total?: number } {
  return {};
}

/**
 * The adapter module entry — the object Paperclip loads.
 *
 * `type` must be `"letta_local"`. Paperclip calls `execute()` per heartbeat.
 */
export const adapter = {
  type: "letta_local",

  async execute(ctx: AdapterExecutionContextLike): Promise<AdapterExecutionResultLike> {
    const cfg = (ctx.agentConfig ?? {}) as LettaLocalAgentConfig;
    try {
      const res = await runLettaLocal(cfg, ctx.prompt);

      if (res.exitCode !== 0 && !res.timedOut) {
        return {
          status: "error",
          error: res.stderr || `letta exited ${res.exitCode}`,
          output: res.stdout,
          tokenUsage: estimateUsage(),
        };
      }

      return {
        status: "success",
        output: res.stdout,
        error: res.stderr || undefined,
        tokenUsage: estimateUsage(),
        session: ctx.sessionId ? { sessionId: ctx.sessionId } : null,
        displayId: cfg.agentId ?? cfg.agentName ?? ctx.agentName,
      };
    } catch (e) {
      return { status: "error", error: String(e) };
    }
  },

  async testEnvironment(ctx: {
    agentConfig?: unknown;
  }): Promise<{ ok: boolean; message?: string }> {
    const cfg = (ctx.agentConfig ?? {}) as LettaLocalAgentConfig;
    const res = await runLettaLocal(cfg, "Reply with exactly one word: ping");
    return {
      ok: res.exitCode === 0 && res.stdout.trim().length > 0,
      message: res.exitCode === 0
        ? `letta local OK (${res.durationMs}ms)`
        : `letta failed: ${res.stderr || res.exitCode}`,
    };
  },
};

export default adapter;
