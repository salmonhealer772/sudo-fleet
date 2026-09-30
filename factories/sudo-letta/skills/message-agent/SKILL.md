---
name: message-agent
description: Send a prompt to any sibling agent by name and get its reply. This is the PRIMARY way agents in the fleet work together — delegate, ask, coordinate, hand off. Use whenever you need another agent to do or answer something. Load this skill before calling message-agent — the tool is blocked until it is loaded this conversation.
---

# message-agent

## What it does

Sends a prompt to any sibling agent (by name) and returns its reply. This is the whole point of the mesh — the primary way agents work together.

The tool is **deliberately simple: it just sends.** The recipient's Redis-backed distributor does all the ordering and concurrency — it queues every prompt and feeds the agent ONE at a time (never parallel, nothing dropped). So you never manage ordering or concurrency yourself: you address a sibling, hand it a prompt, and read the reply.

It works **on both kinds of sibling** — the tool learns each sibling's kind and calls the right prompt tool for you (`letta_prompt` for a Letta planner, `hermes_prompt` for a Hermes engineer), so you never choose the prompt tool.

## Every way to call it

Two required arguments; the rest are optional flags.

```python
message_agent(sibling, prompt, mode="inbox", new_chat=False, json=False,
              source=None)
```

```python
message_agent("fa-glm-l", "Who are you?")                 # inbox (default): enqueue, get an id back now
message_agent("fa-glm-l", "say hi", mode="direct")        # opt-in: send + wait for the full reply
message_agent("fa-glm-l", "hi", new_chat=True)            # start a fresh conversation
message_agent("fa-glm-l", "hi", json=True)                # structured reply
message_agent("fa-glm-l", "do X", source="me")            # tag the message for grouping
```

## The flags

| flag | required | default | what it does |
|---|---|---|---|
| `sibling` | yes | — | which sibling to message, by bare name (the `sibling` field off `list-siblings`). |
| `prompt` | yes | — | the message text to send. |
| `mode` | no | `"inbox"` | `"inbox"` = send and return a message `id` immediately (fire-and-forget; fetch the reply later via `queue_status`). `"direct"` = send and WAIT for the full reply (no timeout) — for recall/read answers ONLY (see the warning below); never for work. |
| `new_chat` | no | `False` | **planners only.** `True` = start a fresh conversation; `False` = resume the planner's persisted conversation. Ignored for engineers. |
| `json` | no | `False` | `True` = structured reply — planners return a JSON object; engineers pretty-print valid JSON (else the raw text). |
| `source` | no | `None` | a stable tag (e.g. your own name) so the recipient groups your messages together — the group-by-source ordering rule. |

There is no `fleet` argument to pass — the live roster and transport are wired in by the harness, not chosen by you. There is no `stream` flag (retired — `direct` mode already returns the full reply; to watch a long job, use `inbox` + `queue_status`). That is the complete public surface: `sibling`, `prompt`, `mode`, `new_chat`, `json`, `source`.

## Direct vs inbox — pick the mode by whether the sibling must DO work

> **⚠️ WARNING — `direct` blocks with NO timeout until the sibling finishes its
> whole turn.** On a Hermes engineer, `hermes_prompt` does not return until the
> engineer completes its ENTIRE job — so a `direct` call to an engineer can hang
> effectively forever (the live test hung ~1m16s+ and showed no sign of stopping).
> **Never use `direct` for an engineer, or for ANY job where the sibling must go
> DO work.**

The sharp rule:

- **`direct`** = the answer is **already in the sibling's head** — a pure
  recall/read with no work required: "who are you", "ping", "read this value".
  Enqueue and WAIT for the full reply (no timeout). This is the right tool for
  instant recall/read answers.
- **`inbox` (default)** = the sibling has to **go DO work** — run a build, touch
  a box, search, anything that takes steps. Enqueue and return a message `id`
  immediately (fire-and-forget); fetch the result later, by id, via
  `queue_status`.

**If the sibling must do ANYTHING, use `inbox` + `queue_status`.** Reserve
`direct` for the one case where the answer is already sitting in the sibling's
memory and comes back instantly — never for work, and never for an engineer.

## Planner vs engineer (the one behavioral split)

- **Letta planner** (`letta_prompt`) — stateful: it resumes its persisted conversation unless `new_chat=True`.
- **Hermes engineer** (`hermes_prompt`) — stateless one-shot: `new_chat` is ignored (and not sent).

The tool resolves which kind a sibling is on its own, so this split only matters for choosing `new_chat`.

## Name resolution (how `sibling` is matched)

Exact match → case-insensitive → unique substring → **ambiguous** (errors, listing candidates) → **not found** (errors). If unsure of the exact name, call `list-siblings` first and copy the name straight out of the roster.

## Fetching an inbox reply — `queue_status`

Sent a message with `mode="inbox"` and got back a message `id`? Fetch the reply
later with the `queue_status` tool — it is registered in the same mod as
`message_agent`, so it is your tool, not the recipient's:

```python
queue_status(sibling)
```

- `sibling` (required) — the bare name of the agent whose inbox to read (the
  same name you passed to `message_agent`).

```python
queue_status("fa-glm-l")
# → pending + recent results, each {id, source, status, reply}
```

`queue_status` resolves the sibling live, reaches its `-mcp` door over MCP, and
reads its prompt queue for you — calling the sibling's own queue-status tool
(`letta_queue_status` on a planner, `hermes_queue_status` on an engineer). You
never touch those names directly; `queue_status(sibling)` is the whole call.

## When to reach for it first

- **Any time you need another agent to do or answer something** — this is the primary inter-agent call. Delegate, ask, coordinate, hand off: all of it is `message_agent`.
- **When you want to kick off something long or fire-and-forget** — `mode="inbox"` (the default) returns an id immediately, then `queue_status` later to collect the result.
- **When you genuinely want the answer now** — `mode="direct"` waits for the full reply; there is no timeout to worry about. This is an explicit opt-in.
- **When the sibling should start fresh rather than resume** — `new_chat=True` for a planner (ignored for an engineer).
- **When you need a machine-readable answer** — `json=True` gives you a structured reply instead of prose.

If you are unsure of a sibling's exact name, don't guess — `list-siblings` first, then message the name it gives you.
