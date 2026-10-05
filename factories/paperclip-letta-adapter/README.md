# letta_local — Paperclip adapter for Letta Code (local backend)

A Paperclip adapter that drives a **Letta Code agent on the local backend** by
spawning the `letta` CLI headless (`letta -p "<prompt>" --backend local --agent <id>`).
No Letta *server* is required — this is the Letta equivalent of Paperclip's
built-in `hermes_local`.

## Why this exists

- Paperclip's built-in provider list has no Letta adapter; the generic
  OpenAI-compatible/vLLM provider is an open feature request (#4344).
- `snowctl/letta-code-paperclip-adapter` requires a running `letta server`
  (`lettaServerUrl`). The sudo-fleet planners (Marc / ONalwase) run on the
  **local backend** (files on disk, `--backend local`), so that server adapter
  does not apply directly.
- This adapter closes that gap the same way `hermes_local` does: **spawn the
  CLI, capture the reply + exit code, report back as a run.**

## How it connects the model

The adapter does **not** bind a model. The agent runs whatever model it is
already configured for. In sudo-fleet that is the local A6000 vLLM
(`openai-compatible/Qwen/Qwen3.8-27B`, base_url `http://127.0.0.1:8000/v1`),
resolved on the Letta side via the agent's own settings — so a heartbeat
through this adapter runs off the GPU with no fork needed.

## Contract

Implements `ServerAdapterModule` (`@paperclipai/adapter-utils`):

- `type: "letta_local"`
- `execute(ctx): Promise<AdapterExecutionResult>` — spawns `letta -p`, returns
  `{ status, output, error, tokenUsage, session, displayId }`.
- `testEnvironment(ctx)` — spawns `letta -p "ping"` and reports ok/fail.

Agent config (`agentConfig` object):
```jsonc
{
  "agentId": "agent-local-...",   // --agent <id>
  "agentName": "Marc",            // optional display name
  "lettaPath": "letta",           // CLI on PATH (absolute path recommended)
  "home": "/home/node",           // HOME for the child (local backend + agents live here)
  "backend": "local",
  "timeoutSec": 600
}
```

## Build

```bash
npm install
npm run build     # -> dist/index.js
```

## Notes / known limits

- `letta -p` (text mode) does not emit token counts, so `tokenUsage` is returned
  empty rather than fabricated. If Paperclip requires usage for budget caps,
  wrap the spawn to also hit the vLLM endpoint's usage, or run the prompt via
  the Letta SDK with stream-json to capture `usage_statistics`.
- `--agent <id>` is required for agents with multiple records; omit it to let
  the CLI use the pinned/last agent.
