import { spawn } from "node:child_process";

// --- Config ---
export interface LettaLocalAgentConfig {
  agentId?: string;
  agentName?: string;
  lettaPath?: string;
  home?: string;
  timeoutSec?: number;
  backend?: "local" | "cloud";
  extraArgs?: string[];
}

export interface LettaLocalRunResult {
  stdout: string;
  stderr: string;
  exitCode: number;
  timedOut: boolean;
  durationMs: number;
}

// --- Core: spawn `letta -p` headless (the hermes_local pattern) ---
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
    const child = spawn(letta, args, {
      env: { ...process.env, ...(config.home ? { HOME: config.home } : {}) },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; child.kill("SIGTERM"); }, (config.timeoutSec ?? 600) * 1000);
    child.stdout.on("data", (d) => (stdout += d.toString()));
    child.stderr.on("data", (d) => (stderr += d.toString()));
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ stdout, stderr, exitCode: code ?? -1, timedOut, durationMs: Date.now() - start });
    });
    child.on("error", (err) => {
      clearTimeout(timer);
      resolve({ stdout, stderr: stderr + String(err), exitCode: -1, timedOut, durationMs: Date.now() - start });
    });
  });
}

// --- The Paperclip ServerAdapterModule (contract from @paperclipai/adapter-utils) ---
type AdapterExecutionContextLike = {
  agentName: string;
  agentConfig: unknown;
  prompt: string;
  sessionId?: string | null;
  heartbeatContext?: unknown;
};

type AdapterExecutionResultLike = {
  status: "success" | "error";
  output?: string;
  error?: string;
  tokenUsage?: { input?: number; output?: number; total?: number };
  session?: Record<string, unknown> | null;
  displayId?: string;
};

type ServerAdapterModule = {
  type: string;
  models: Array<{ id: string; name: string }>;
  agentConfigurationDoc?: Record<string, unknown>;
  execute(ctx: AdapterExecutionContextLike): Promise<AdapterExecutionResultLike>;
  testEnvironment(ctx: { agentConfig?: unknown }): Promise<{ ok: boolean; message?: string }>;
};

/**
 * Factory entry — Paperclip's plugin-loader (`buildExternalAdapters`) imports the
 * package root and calls `createServerAdapter()` to get the ServerAdapterModule.
 * (This is the contract; NOT a bare exported object.)
 */
export function createServerAdapter(): ServerAdapterModule {
  return {
    type: "letta_local",

    // UI metadata only — does NOT bind a model. The agent runs whatever model it
    // is already configured for (Qwen3.8-27B on the local A6000 vLLM).
    models: [{ id: "letta-local", name: "Letta Code (local backend)" }],

    agentConfigurationDoc: {
      agentId: { type: "string", required: false, description: "Agent id for `--agent <id>`" },
      agentName: { type: "string", required: false, description: "Display name" },
      lettaPath: { type: "string", required: false, description: "Path to the letta CLI (default `letta`)" },
      home: { type: "string", required: false, description: "HOME for the child process" },
      timeoutSec: { type: "number", required: false, description: "Child timeout seconds (default 600)" },
    },

    async execute(ctx) {
      const cfg = (ctx.agentConfig ?? {}) as LettaLocalAgentConfig;
      try {
        const res = await runLettaLocal(cfg, ctx.prompt);
        if (res.exitCode !== 0 && !res.timedOut) {
          return { status: "error", error: res.stderr || `letta exited ${res.exitCode}`, output: res.stdout, tokenUsage: {} };
        }
        return {
          status: "success",
          output: res.stdout,
          error: res.stderr || undefined,
          tokenUsage: {},
          session: ctx.sessionId ? { sessionId: ctx.sessionId } : null,
          displayId: cfg.agentId ?? cfg.agentName ?? ctx.agentName,
        };
      } catch (e) {
        return { status: "error", error: String(e) };
      }
    },

    async testEnvironment(ctx) {
      const cfg = (ctx.agentConfig ?? {}) as LettaLocalAgentConfig;
      const res = await runLettaLocal(cfg, "Reply with exactly one word: ping");
      return {
        ok: res.exitCode === 0 && res.stdout.trim().length > 0,
        message: res.exitCode === 0 ? `letta local OK (${res.durationMs}ms)` : `letta failed: ${res.stderr || res.exitCode}`,
      };
    },
  };
}

export default createServerAdapter;
