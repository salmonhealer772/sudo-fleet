# check-agent-logs — tool contract

Tail a sibling's recent activity trail, in TWO modes, both depth-controllable.

## Contract

- **Inputs:** `sibling` (agent name), `mode` (`full` or `compressed`), optional `n` (depth; how far back to look). `n=-1` (or a dedicated "all" sentinel) = the ENTIRE file, no depth cap — identical semantics on Letta and Hermes siblings.
- **Behavior:**
  - **full mode** → `GET http://sudo-{sibling}-watch:8000/events?n=N` (or `/stream` for live tail) — every event incl. `thinking`/`tool_call`/`tool_result`/`session`/`process_state`. Schema `{ts, conversation, event, ...}`. `n=-1` → the entire events file.
  - **compressed mode** → read the sibling's `transcript.txt` file (plain chat log: real prompts + replies only) — the SAME read `stream.sh -t` already does: `kubectl exec deploy/sudo-{sibling} -c watch -- tail -n N /home/node/.letta/watch/transcript.txt` (Letta) / the Hermes-equivalent transcript path. No HTTP route needed — read the file directly. `n=-1` → `cat` the entire transcript (no `tail` bound).
- **Depth control:** `n` in both modes (full → `/events?n=N`; compressed → `tail -n N`). Small n = recent, large n = deep history, `n=-1` = whole file.
- **Purpose:** read what a sibling has been saying (compressed) or thinking/doing (full) — catch up before messaging it.

## Notes

- The compressed transcript (`transcript.txt`) is ALREADY written by both sidecars (Letta distills `messages.jsonl`; Hermes distills `state.db`) — it is on-disk, just not served over the `-watch` HTTP tap. So compressed mode reads the FILE, not an HTTP route. Full mode goes over the HTTP tap (`/events`, `/stream`).
- If a future sidecar version adds a `/transcript?n=N` route, the tool MAY prefer that, but it is NOT required — the file read works today.

## Backend

Undecided — same as message-agent. Contract only.
