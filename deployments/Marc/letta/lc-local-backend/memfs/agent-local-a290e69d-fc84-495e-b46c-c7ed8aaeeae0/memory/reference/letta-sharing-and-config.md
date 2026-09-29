---
description: How to share/package a Letta agent (AgentFile `.af`) and the Letta config features we under-use (tool_rules, memory-block read_only/limit). Researched 2026-09-17 via the web_search/Tavily tool.
---

# Sharing agents + Letta config features we're missing

## "How do I put an agent somewhere someone else can get one?" → AgentFile (`.af`)

The word for exporting an agent so another person can spin up their own copy (e.g. `lb-glm-l`/`lb-glm-h`) is **AgentFile**, a **`.af`** file.

- **`.af` is the canonical, supported sharing/portability format** for stateful Letta agents. It captures: **system prompt**, **memory blocks** (labeled, with description/value/limit), **tool configurations**, **LLM/model settings**, and skills — all in a portable JSON form. It versions in git and deploys across environments.
- **Sharing path = the community repo, not a marketplace.** The canonical repo is **`letta-ai/agent-file`** (GitHub) + the Letta **Discord** for sharing. There is **no central "Letta app store"** you publish to — `.af` sharing is a *community* mechanism, and `.af` files effectively serve as the "template library."
- **Two options for our situation:** (1) share just the *agent* as a thing → `.af` in the `letta-ai/agent-file` repo; (2) share the *whole paired-engineer + live-deployment architecture* → that's our own deploy recipe (the [[skills/standing-up-agent-pairs]] path), which no public `.af` example reproduces.
- The public `.af` examples (Personal Assistant, Research Companion, Customer Support, Code Review, Learning Tutor, DuckDB agent, etc.) are all **thin** — persona + tools + memory blocks. **None** carry the *paired engineer + live k8s deployment* architecture we build, so they're only useful for stealing patterns (memory-block structure, tool-graph syntax), not as architectural references.

## Letta config features we under-use (the real gaps the research surfaced)

1. **`tool_rules` — the big one.** Letta agents can define **DAG-like tool-ordering constraints** (e.g. "cleanup tool must run after data-processing tool", "tool X must precede tool Y"). **None of our agents (or my own config) use `tool_rules` at all** — a missed mechanism for enforcing pipeline order/repeatedly-corrected-sequence behavior without persona prose.
2. **`read_only` + `limit` on memory blocks.** Others set explicit per-block `limit` (e.g. 5000 chars) and mark policy blocks `read_only`. We've been writing personas as free-form text with implicit limits. Explicit limits force the memory discipline [REDACTED] repeatedly asks for.
3. **(Observed, not acting on yet) `image-understanding` needs a vision backend** and `web-search` needs a per-agent provider key — see the mods note in [[reference/environment.md]].

## Open follow-ups worth flagging when the person asks
- `tool_rules` is the most concrete "trick others use that we don't" — candidate for a future build once a pair needs enforced tool ordering.
- The `letta-guide` skill referenced in my Resources section does not currently exist in my skills tree; if Letta product questions keep coming up, install/author it rather than answering `.af`/config questions purely from memory.
