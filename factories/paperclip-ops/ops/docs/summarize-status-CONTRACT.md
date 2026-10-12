# summarize-status — tool contract

Produce a short, colloquial, single-agent status summary that OPENS with the
1-3 concrete next actions. Pure function — no network, no side effects.

## Contract

- **Inputs:** `status_input` (dict) with these keys:
  - `agent` (str) — agent name; default `"unknown"`.
  - `phase` (str) — current phase; default `"unknown"`.
  - `stuck` (bool) — whether the agent looks stuck; default `False`.
  - `next_actions` (list[str]) — 1-3 concrete next actions; default `[]`.
  - `last_event` (str) — the freshest trail event label; default `""`.
  - `events_n` (int) — number of events in the trail; default `0`.
- **Output:** a single plain-text string (no markdown, no JSON).
- **Opening** (always first, exactly one of three forms):
  - `stuck=True` → `"<agent> looks stuck in <phase>. "`
  - else `next_actions` non-empty → `"Next for <agent> (<phase>): a; b; c. "`
  - else → `"<agent> is in <phase> with no pending actions. "`
- **Tail** (appended after the opening):
  - `last_event` present → `"Last event: <last_event> (<events_n> events in trail)."`
  - else → `"<events_n> events in trail."`
- **Purity:** no network, no filesystem, no side effects. Deterministic.

## Worked example

```python
summarize({
    "agent": "fa-glm-l", "phase": "running",
    "next_actions": ["clear the stuck run", "fire a fresh ticket"],
    "last_event": "PROMPT", "events_n": 42, "stuck": False,
})
# -> "Next for fa-glm-l (running): clear the stuck run; fire a fresh ticket. Last event: PROMPT (42 events in trail)."
```

## Error / edge cases

- **Empty dict `{}`** → degrades gracefully to
  `"unknown is in unknown with no pending actions. 0 events in trail."`
  (every key falls back to its default; never raises).
- **`stuck=True` with non-empty `next_actions`** → the stuck note wins; next
  actions are NOT printed.
- **Single `next_action`** → no `"; "` separator (only one action).
- **No `last_event`** → tail omits the "Last event:" clause.
- **Missing keys** → each missing key falls back to its default.

## Backend

Implemented as a pure function in `tools/summarize_status.py` (`summarize`).
