---
name: list-siblings
description: See every sibling agent in the fleet and how to reach them. Use when you need to know who else exists, confirm a sibling's exact name, or get the message/watch addresses to reach or observe another agent. Call this FIRST before messaging or checking on a sibling whose name you are not sure of.
---

# list-siblings

> **THIS IS A START, NOT A FULL PRODUCT.** It contains the critical info — what the tool does and every way to call it — so it is immediately usable. It is not yet the polished procedural guidance (when-to-use nuance, examples, gotchas) a finished skill will have.

## What it does

Returns the **entire fleet** as a live roster: every sibling agent, with its bare name and its two reach addresses. Read it when you're not sure who exists or what a sibling's exact name is — before you message or check on them.

Each entry is one agent with three fields:

| field | meaning |
|---|---|
| `sibling` | the bare name — what you use to `message-agent` / check it |
| `mcp_host` | where to **send a prompt** (`sudo-<name>-mcp:8000`) |
| `watch_host` | where to **observe** it (`sudo-<name>-watch:8000`) |

The roster is **live**, not cached — it re-reads the fleet every call, so a newly-spawned sibling appears and a removed one drops off automatically, with no edit to anything.

## Every way to call it

Both forms take an injected `fleet` (the roster+transport the harness wires in — not something you choose).

### 1. Full roster (no args)

```python
list_siblings(fleet=fleet)
```

Returns everyone. Each entry: `{sibling, mcp_host, watch_host}`.

### 2. Filtered by substring (one optional flag)

```python
list_siblings(filter="glm", fleet=fleet)
```

Narrows the roster to siblings whose `sibling` name contains the substring. The flag has exactly three outcomes:

| filter result | returns |
|---|---|
| unique match | one entry |
| multiple matches | all matching entries |
| no match | empty list `[]` (clean empty — not an error, not a hang) |

## Syntax reference (all the flags)

| flag | required | meaning |
|---|---|---|
| `filter` | no | substring to narrow the roster by bare name. Omit for the full fleet. |
| `fleet` | yes (injected) | the roster+transport; supplied by the harness, not picked by you. |

That is the complete public surface. There are no other flags.
