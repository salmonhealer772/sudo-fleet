# Communication layer — tools + skills + persona

This directory ships the **native cross-agent communication layer** for a `sudo-fleet`: the tools and skills every agent gets so it can talk to, and check on, any sibling agent — over the MCP + watch sidecars that already run on every agent.

Three folders, three layers that must **align**:

| Layer | Folder | What it is |
|---|---|---|
| **Tool** | `tools/` | the mechanism — a callable thing that hits a sibling's sidecar |
| **Skill** | `skills/` | the procedure — *when + how* to use the tool |
| **Persona** | `persona/` | the awareness — a snippet that teaches the agent it *has* this |

A tool without a skill is a bare callable nobody reaches for. A tool + skill without the persona snippet gets ignored because the agent doesn't know it exists (the whole point of the persona layer is to make the agent *actually use* what it has).

## The three tools (and their skills)

1. **`list-siblings`** — see who exists and how to reach them (read `kubectl get services`, the live roster).
2. **`message-agent`** — BY FAR the most important. Message any sibling by name (`letta_prompt`/`hermes_prompt` via the sibling's `-mcp`).
3. **`check-agent`** — read a sibling's trail at any depth (`GET ...-watch/events?n=N`, or the compressed `transcript.txt` read directly; `n=-1` = the whole file). Answers both "what has it been doing" and "what is it doing right now" — the merged check-what-agent-is-doing + check-agent-logs tool.

## Base skills — the universal starter set

For the *base skill set* every fleet agent ships (cross-host, skill-vetter, find-skills, clawhub, creating-skills, plus the pair skills) — see base-skills/BASE-SKILLS.md. It is a separate axis from the comm layer: comm = "how to talk", base skills = "how to be capable" (reach the machine, extend yourself, self-repair). Both are baked by the router at spawn-time.

## The router default

In a `sudo-fleet`, the spawner/router (psnvc + forge) bakes these into **every spawned agent** as a spawn-time default — a new agent is *born* able to talk to the fleet. This directory is the canonical source of that default: what `up.sh`/spawn copies into each new agent.

## Persona snippet — read this first

See `persona/PERSONA-SNIPPET.md`. It is **not** a full persona, `SOUL.md`, or `AGENTS.md`. It's a drop-in block you add to an agent's existing persona so it always knows about these skills/tools and reaches for them.
