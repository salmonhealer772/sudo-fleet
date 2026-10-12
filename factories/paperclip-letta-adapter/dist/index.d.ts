/**
 * letta_local — Paperclip adapter that drives the LIVE sudo-letta agent (k8s).
 *
 * v0.2.1 — same rewire, plus a fix for losing long replies: the live door
 * answers with `text/event-stream`, and sse-starlette injects a keep-alive
 * COMMENT frame (`: ping - <ts>`) every 15s while a tool call is in flight. A
 * call that outlived 15s therefore produced a body that no longer started with
 * `event:`/`data:`, the old decoder returned `{}`, and the run died with
 * "Cannot read properties of undefined (reading 'length')". `decodeMcpBody` is
 * now a real SSE frame parser (skips comment/ping lines, joins multi-line data,
 * matches the JSON-RPC reply id), `mcpRpc` fails loud on an unusable reply, and
 * a malformed reply is retried once before giving up.
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
export interface LettaLocalAgentConfig {
    mcpUrl?: string;
    mcpTool?: string;
    mode?: "direct" | "inbox";
    newChat?: boolean;
    namespace?: string;
    timeoutSec?: number;
    agentName?: string;
    /**
     * Paperclip control-plane base URL as reachable from the LIVE agent pod.
     * Appended to the prompt so the agent can call back (checkout / comment /
     * mark the issue done) using the PAPERCLIP_API_KEY already in its env.
     * Falls back to PAPERCLIP_API_URL from the adapter's own environment.
     */
    apiUrl?: string;
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
/**
 * Run ONE prompt on the LIVE agent over MCP. Tries each candidate door; the
 * first one that answers wins. Returns a spawn-shaped result so the rest of the
 * adapter (and Paperclip) is unchanged.
 */
export declare function runLettaLive(config: LettaLocalAgentConfig, prompt: string): Promise<LettaLocalRunResult>;
/**
 * Factory entry — Paperclip's plugin loader imports the package root and calls
 * `createServerAdapter()` to get the ServerAdapterModule.
 */
export declare function createServerAdapter(): any;
export default createServerAdapter;
