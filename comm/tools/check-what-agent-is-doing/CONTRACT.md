# check-what-agent-is-doing — tool contract

Read a sibling's live activity via its `-watch` sidecar.

## Contract

- **Inputs:** `sibling` (agent name).
- **Behavior:** `GET http://sudo-{sibling}-watch:8000/status` → return the status snapshot fields relevant to "what is it doing right now": `{active, current_conversation, last_event_ts, events_logged, uptime_s}`.
- **Purpose:** answer "is this sibling alive, and is it mid-run right now?" — the check before messaging.

## Backend

Undecided — same as message-agent. Contract only.
