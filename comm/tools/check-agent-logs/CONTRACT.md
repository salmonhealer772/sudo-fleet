# check-agent-logs — tool contract

Tail a sibling's recent activity trail via its `-watch` sidecar.

## Contract

- **Inputs:** `sibling` (agent name), optional `n` (last N events, default e.g. 20).
- **Behavior:** `GET http://sudo-{sibling}-watch:8000/events?n=N` → return the trailing event trail (`{ts, conversation, event, ...}` lines), or `/stream` for a live tail.
- **Purpose:** read what a sibling has been doing — catch up before messaging it.

## Backend

Undecided — same as message-agent. Contract only.
