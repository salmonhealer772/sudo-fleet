# check-agent — tool contract

Read a sibling's trail — the one read that answers both "what has it been
doing" and "what is it doing right now".

**This is the merged tool.** It replaces the former `check-agent-logs` AND
`check-what-agent-is-doing`; there is no separate status/ps surface any more.

## Contract

- **Inputs:** `sibling` (agent name); optional `n` (trailing depth); optional
  `mode` (`full` | `compressed`, default `full`). Three flags, one required.
- **Depth (`n`), identical in both modes:** `k>0` = the last k entries;
  `n=-1` = the ENTIRE file, no depth cap — identical semantics on Letta and
  Hermes siblings; omitted = the default depth of 100.
- **Behavior:**
  - **full mode (default)** → `GET http://sudo-{sibling}-watch:8000/events?n=N`
    — every event incl. `thinking`/`tool_call`/`tool_result`/`session`/
    `process_state`. Schema `{ts, conversation, event, ...}`. `n=-1` → the
    entire events file; omitted → the sidecar's default of 100.
  - **compressed mode** → read the sibling's `transcript.txt` file (plain chat
    log: real prompts + replies only) — the SAME read `stream.sh -t` already
    does: `kubectl exec deploy/sudo-{sibling} -c watch -- tail -n N
    /home/node/.letta/watch/transcript.txt` (Letta) / the Hermes transcript
    path for a Hermes engineer. No HTTP route needed — read the file directly.
    `n=-1` → `cat` the entire transcript (no `tail` bound); omitted →
    `tail -n 100`.
- **Answers "what is it doing right now":** from the FRESHEST entries of the
  same trail — the newest events carry the current conversation and the latest
  `process_state` (idle ↔ active). No `/status` and no `/ps` call.
- **Purpose:** catch up on a sibling before messaging it — what it has been
  saying (compressed) or thinking/doing (full), and what it is doing now.

## Retired surface

- `GET /status` and `GET /ps` (the old `check-what-agent-is-doing` facets) are
  **dropped from the contract** — the what-is-it-doing answer falls out of the
  trail. (The `-watch` sidecar still exposes those routes; the tool simply no
  longer surfaces them.)
- The `stream` flag (the old "live tail" via `GET /stream`) is **dropped** —
  fewer flags. A caller that wants to follow along asks again with a small `n`.
  It can be re-added later if something actually needs a blocking live follow.

## Notes

- The compressed transcript (`transcript.txt`) is ALREADY written by both
  sidecars (Letta distills `messages.jsonl`; Hermes distills `state.db`) — it is
  on-disk, just not served over the `-watch` HTTP tap. So compressed mode reads
  the FILE, not an HTTP route. Full mode goes over the HTTP tap (`/events`).
- If a future sidecar version adds a `/transcript?n=N` route, the tool MAY
  prefer that, but it is NOT required — the file read works today.

## Backend

Undecided — same as message-agent. Contract only.
