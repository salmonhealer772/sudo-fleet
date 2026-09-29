---
name: check-agent
description: Read a sibling agent's trail — what it has been doing and what it is doing right now, from the same trail. Use when you want to catch up on a sibling before messaging it, or to see its current state (idle vs active). This is the ONE observability read for the fleet.
---

# check-agent

> **THIS IS A START, NOT A FULL PRODUCT.** It contains the critical info — what the tool does and every way to call it — so it is immediately usable. It is not yet the polished procedural guidance (when-to-use nuance, examples, gotchas) a finished skill will have.

## What it does

Reads a sibling's **trail**, and it is the ONE observability read: it answers BOTH **what has it been doing** and **what is it doing right now** from that same trail. The what-is-it-doing-now answer falls out of the **freshest entries** — a small `n` returns the newest events, which carry the current conversation and the latest `process_state` (idle vs active). There is **no separate `/status` or `/ps` surface** to call any more.

**This is the merged tool.** It replaces the former `check-agent-logs` AND `check-what-agent-is-doing` — one tool, one depth knob, two modes.

It works **identically on Letta planners and Hermes engineers** — they keep their transcripts at different paths, and the tool picks the right one per sibling kind.

Load this skill **before messaging a sibling you want to catch up on** — read the trail first so your prompt lands in context.

## Every way to call it

One required argument; two optional flags.

```python
check_agent(sibling, n=None, mode="full", *, fleet)
```

- `sibling` (required) — which agent to read. Bare name, e.g. `ya-glm-l`.
- `fleet` (injected) — supplied by the harness, not chosen by you.

## The flags

| flag | required | default | what it does |
|---|---|---|---|
| `sibling` | yes | — | which sibling to read, by bare name. |
| `n` | no | `None` | trailing depth, **identical in both modes**: `k>0` = the last k entries; `n=-1` = the ENTIRE file (no depth cap, so you never guess a huge number); omitted = the default depth of `100`. |
| `mode` | no | `"full"` | `"full"` = `GET /events?n=N` over HTTP — the raw trail (`user`/`thinking`/`assistant`/`tool_call`/`tool_result`/`session`/`process_state`). `"compressed"` = read `transcript.txt` directly — plain `You:`/`Agent:` chat, reasoning and tool calls stripped. |
| `fleet` | yes (injected) | — | the roster+transport; supplied by the harness, not picked by you. |

There is no `stream` flag (retired — to follow along, call again with a small `n`) and no `/status` or `/ps` facet flag. That is the complete public surface: `sibling`, `n`, `mode`, `fleet`.

## Full vs compressed (the one behavioral split)

- **full mode (default)** — `GET /events?n=N` on the sibling's `-watch` sidecar. Every event: thinking, tool calls, tool results, sessions, process states. The raw, unabridged trail of everything the agent has thought and done.
- **compressed mode** — reads the sibling's `transcript.txt` file directly, the plain chat log: only real user prompts and assistant replies. Thinking, tool calls/results, sessions, process states and system reminders are stripped.

Full goes over the HTTP tap; compressed reads the file on disk. Both take the same `n`.

## Name resolution (how `sibling` is matched)

Exact match → case-insensitive → unique substring → **ambiguous** (errors, listing candidates) → **not found** (errors). If unsure of the exact name, call `list-siblings` first.
