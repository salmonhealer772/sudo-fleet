# check-agent-logs — tool contract

Tail a sibling's recent activity trail via its `-watch` sidecar — in TWO modes, both depth-controllable.

## Contract

- **Inputs:** `sibling` (agent name), `mode` (`full` or `compressed`), optional `n` (depth; how far back to look).
- **Behavior:**
  - **full mode** → `GET http://sudo-{sibling}-watch:8000/events?n=N` (or `/stream` for live tail). Every event — including `thinking`, `tool_call`, `tool_result`, `session`, `process_state`. Schema `{ts, conversation, event, ...}`.
  - **compressed mode** → `GET http://sudo-{sibling}-watch:8000/transcript?n=N`. Only real user prompts (`You:`) + assistant replies (`Agent:`); thinking/tools/reminders stripped. Plain `[ts] You:/Agent: text` lines.
- **Depth control:** `n` in both modes; small n = recent, large n = deep history. Default n when omitted: `/events` = 100 (sidecar default); `/transcript` = to be determined when the route is added.
- **Purpose:** read what a sibling has been saying (compressed) or thinking/doing (full) — catch up before messaging it.

## REQUIRED SIDECAR CHANGE (blocking)

`/events?n=N` and `/stream` already exist in `watch_sidecar.py`. **`/transcript?n=N` does NOT exist yet** — the compressed transcript (`transcript.txt`) is written to disk but not exposed over HTTP (today only reachable via `kubectl exec tail -f` / `stream.sh -t`). The sidecar must add a `/transcript?n=N` route (mirroring `/events?n=N`) that serves the last N `transcript.txt` lines, so the compressed mode is reachable in-cluster by sibling agents. This is the one piece of the two-mode contract that is not yet built.

## Backend

Undecided — same as message-agent. Contract only.
