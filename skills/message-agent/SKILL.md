---
name: message-agent
description: Send a prompt to any sibling agent by name and get its reply. This is the PRIMARY way agents in the fleet work together — delegate, ask, coordinate, hand off. Use whenever you need another agent to do or answer something.
---

# message-agent

> **THIS IS A START, NOT A FULL PRODUCT.** It contains the critical info — what the tool does and every way to call it — so it is immediately usable. It is not yet the polished procedural guidance (when-to-use nuance, examples, gotchas) a finished skill will have.

## What it does

Sends a prompt to any sibling agent (by name) and returns its reply. This is the whole point of the mesh — the primary way agents work together.

The tool is **deliberately simple: it just sends.** The recipient's Redis-backed distributor does all ordering and concurrency — it queues messages and feeds the agent one at a time, dropping nothing. So you never manage ordering or concurrency yourself; you address a sibling, hand it a prompt, and read the reply.

## Every way to call it

Two things are required; the rest are optional flags.

```python
message_agent(sibling, prompt, mode="direct", new_chat=False, json=False,
              source=None, *, fleet)
```

- `sibling` (required) — who to message. Bare name, e.g. `fa-glm-l`.
- `prompt` (required) — the message.
- `fleet` (injected) — supplied by the harness, not chosen by you.

## The flags

| flag | default | what it does |
|---|---|---|
| `mode` | `"direct"` | `"direct"` = send and WAIT for the full reply (no timeout; long jobs are fine). `"inbox"` = send, get a message `id` back immediately, fetch the reply later via `queue_status`. |
| `new_chat` | `False` | **Planners only.** `True` = start a fresh conversation; `False` = resume the planner's existing conversation. Ignored for engineers. |
| `json` | `False` | `True` = structured reply — planners return a JSON object; engineers pretty-print valid JSON (else raw text). |
| `source` | `None` | a stable tag (e.g. your own name) so your messages are grouped together in the recipient's queue. |

There is no `stream` flag (removed — direct mode already returns the full reply; "watch a long job" is what `inbox` + `queue_status` is for).

## Planner vs engineer (the one behavioral split)

- **Letta planner** (`letta_prompt`) — stateful: resumes its persisted conversation unless `new_chat=True`.
- **Hermes engineer** (`hermes_prompt`) — stateless one-shot: `new_chat` is ignored.

## Name resolution (how `sibling` is matched)

Exact match → case-insensitive → unique substring → **ambiguous** (errors, listing candidates) → **not found** (errors). If unsure of the exact name, call `list-siblings` first.

## Fetching an inbox reply — `queue_status`

Sent a message with `mode="inbox"` and got back an id? Fetch the result later:

```python
queue_status(sibling, fleet=fleet)
# → the recipient's queue: pending + recent results (id, status, reply)
```

This is the *recipient's* tool, used to read back an inboxed message by id.
