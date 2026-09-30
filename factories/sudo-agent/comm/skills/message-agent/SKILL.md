---
name: message-agent
description: Send a prompt to any sibling agent by name and get its reply. This is the PRIMARY way agents in the fleet work together — delegate, ask, coordinate, hand off. Use whenever you need another agent to do or answer something.
---

# message-agent

Send a prompt to any sibling agent (by name) and get its reply. This is the
primary way agents in the fleet work together.

The tool is **deliberately simple: it just sends.** The recipient's
Redis-backed prompt distributor does all the ordering and concurrency — it
queues every prompt and feeds the agent ONE at a time (never parallel, nothing
dropped). So you never manage ordering or concurrency yourself: address a
sibling, hand it a prompt, read the reply.

It works on **both kinds** of sibling — the tool learns each sibling's kind and
calls the right prompt tool for you (`letta_prompt` for a Letta planner,
`hermes_prompt` for a Hermes engineer), so you never choose the prompt tool.

## How to call it (the tool lives at /opt/comm-tools/)

```sh
python3 /opt/comm-tools/message_agent.py <sibling> "<prompt>" [flags]
```

```sh
python3 /opt/comm-tools/message_agent.py fa-glm-l "Who are you?"          # inbox (default): enqueue, id back now
python3 /opt/comm-tools/message_agent.py fa-glm-l "hi" --mode direct      # opt-in: send + wait for the reply
python3 /opt/comm-tools/message_agent.py fa-glm-l "hi" --new-chat         # fresh conversation
python3 /opt/comm-tools/message_agent.py fa-glm-l "hi" --json             # structured reply
python3 /opt/comm-tools/message_agent.py fa-glm-l "do X" --source me      # tag for grouping
```

## The flags

| flag | default | what it does |
|---|---|---|
| `sibling` (positional) | — | which sibling to message, by bare name (the `sibling` field off `list-siblings`). |
| `prompt` (positional) | — | the message text to send. |
| `--mode` | `inbox` | `inbox` = send and return a message `id` immediately (fire-and-forget; fetch later via the sibling's queue-status). `direct` = send and WAIT for the full reply (no timeout) — for recall/read answers ONLY (see the warning below); never for work. |
| `--new-chat` | off | **planners only.** Start a fresh conversation instead of resuming. Ignored for engineers. |
| `--json` | off | Structured reply — planners return a JSON object; engineers pretty-print valid JSON (else raw text). |
| `--source` | none | a stable tag (e.g. your own name) so the recipient groups your messages together — the group-by-source ordering rule. |

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
  immediately (fire-and-forget); fetch the result later, by id, via the
  sibling's `*_queue_status` tool.

**If the sibling must do ANYTHING, use `inbox` + `queue_status`.** Reserve
`direct` for the one case where the answer is already sitting in the sibling's
memory and comes back instantly — never for work, and never for an engineer.

## Planner vs engineer (the one behavioral split)

- **Letta planner** (`letta_prompt`) — stateful: resumes its persisted
  conversation unless `--new-chat`.
- **Hermes engineer** (`hermes_prompt`) — stateless one-shot: `--new-chat` is
  ignored (and not sent).

If unsure of the exact sibling name, call `list-siblings` first.
