---
name: summarize-status
description: Turn a status_input dict into a short colloquial status summary that opens with the 1-3 concrete next actions. Use when you need a human-readable one-line-per-agent status (standups, heartbeat reports). PURE function. Load this skill before running summarize_status.py.
---

# summarize-status

Turn a `status_input` dict into a short, colloquial status summary that
OPENS with the 1-3 concrete next actions.

```python
from summarize_status import summarize

line = summarize({
    "agent": "fa-glm-l", "phase": "running",
    "next_actions": ["clear the stuck run", "fire a fresh ticket"],
    "last_event": "PROMPT", "events_n": 42, "stuck": False,
})
```

The tool is **PURE**: no network, no filesystem, no side effects.

## Input keys

| key           | default     | meaning                        |
|---------------|-------------|--------------------------------|
| `agent`       | `"unknown"` | agent name                     |
| `phase`       | `"unknown"` | current phase                  |
| `stuck`       | `False`     | whether the agent looks stuck  |
| `next_actions`| `[]`        | 1-3 concrete next actions      |
| `last_event`  | `""`        | freshest trail event label     |
| `events_n`    | `0`         | number of trail events         |

## Output

A single plain-text string, always opening with exactly one of:

- stuck → `"<agent> looks stuck in <phase>. "`
- next actions → `"Next for <agent> (<phase>): a; b; c. "`
- otherwise → `"<agent> is in <phase> with no pending actions. "`

then the trail tail (`"Last event: X (N events in trail)."` or
`"N events in trail."`).

## When to use it

- A standup or heartbeat report needs a one-line summary per agent.
- A status card needs a human-readable headline before its structured fields.
