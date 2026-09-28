# message-agent — tool contract

**The most important tool in the communication layer.** Message any sibling agent by name and get its reply, via the sibling's `-mcp` service.

## Contract

- **Inputs:** `sibling` (agent name, e.g. `fa-glm-l` / `ms-glm-l`), `prompt` (the message), optional `new_chat` (bool, default false), optional `json` (bool), optional `mode` (`direct` | `inbox`), optional `source` (id tag for group-by-source ordering).
- **Behavior:** reach `http://sudo-{sibling}-mcp:8000/mcp` → MCP `initialize` → `tools/call` the sibling's prompt tool (`letta_prompt` for Letta planners, `hermes_prompt` for Hermes engineers) with `prompt` → return the reply string.
- **Session semantics:** planner sibling = stateful (resumes its persisted conversation unless `new_chat=true`); engineer sibling = stateless one-shot (no `new_chat` — it is ignored).
- **Concurrency is the RECIPIENT's job, not the sender's.** The tool only sends. The sibling's Redis-backed distributor queues every prompt and feeds the agent ONE at a time — N rapid messages = N queued runs, never N parallel races, nothing dropped.
- **Two delivery modes (both factories):**
  - `mode="direct"` (default) — enqueue and WAIT for the reply. No timeout; long jobs are fine.
  - `mode="inbox"` — enqueue and return a message `id` immediately; fetch the reply later via the sibling's `*_queue_status` tool, or by id.
- **`source`** tags the enqueuer for the **group-by-source ordering rule**: first-in first-out by arrival → then drain ALL remaining from that same source before anyone else → then the next most-recent source → FIFO within a source.
- **No-timeout:** long jobs must not be cut (`HERMES_STREAM_*_TIMEOUT=inf` equivalent on the call path).

## The recipient's queue (its own MCP surface, same shape on both factories)

- `letta_prompt(prompt, json, new_chat, mode, source)` — Letta planner.
- `hermes_prompt(prompt, json, mode, source)` — Hermes engineer (stateless; `new_chat` is a no-op and not exposed).
- `letta_queue_status()` / `hermes_queue_status()` — pending queue + recent processed results (ids, sources, timestamps); the observability window, and how `inbox` replies are fetched.
- Backing store: shared fleet Redis (`sudo-letta-redis` on `127.0.0.1:6379`; `sudo-agent-redis` on `127.0.0.1:6380`, AOF-durable), hostNetwork on the node loopback, each agent keyed by its own queue namespace (unique `MCP_PORT` / `AGENT_NAME`).

## Backend

Undecided (operator: "shit idk") — shell script vs. Letta mod tool. forge decides during build; this file pins the contract only.
