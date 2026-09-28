# Base skills — the universal starter set every fleet agent ships

> Penciled 2026-09-28. v2. This is a **spec**, not yet built — same state as the comm layer (contracts written, backends undecided). The router bakes these into every spawned agent as a spawn-time default, the same way it bakes in the comm tools/skills.

## Why a base set exists at all

The comm layer teaches an agent **how to talk**. The base-skills layer teaches an agent **how to be a capable agent in this fleet**: talk to siblings, extend itself, reach the machine, and self-repair. A fleet agent that can only compute is a brain with no hands and no mouth.

The meta (operator, 2026-09-28): "give agents personas that tell them to use the skills, and give them a base set of ~10 skills they really should need." Persona = awareness, base skills = capability. Both ship together, or the skills sit unused.

## The rule: where a skill is already Letta-native, don't rebuild it

Before adding a skill to the base set, check whether it already exists as a **built-in Letta skill** (shipped in the `letta-code` image) or a **battle-tested skill in the factory repo**. Rebuilding a skill that already ships is waste; porting one from another harness (Clawdbot/OpenClaw) is a *port*, not a paste — those assume `clawhub install`, `~/.agents/skills/`, and a different runtime, so they need adapting (see the `clawhub` + `find-skills` skills, which were ported this way on 2026-09-28: dead hostnames, fake CLIs).

## The base set (v2 — the full ~12, comm layer folded in)

One list now, because "how to talk" and "how to be capable" ship together and the operator folded the comm layer in. Split by who needs it: the **comm 4 + universal 5** go to *every* agent; the **pair 3** go to the planner+engineer unit.

### Comm layer — the 4 we are building right now (every agent)

These are the native "talk to the fleet" skills, already specced in `features/` + `docs/`. They are **part of the base set**, not a separate thing bolted on.

| # | Skill | What it is | State |
|---|---|---|---|
| 1 | `list-siblings` | see who exists and how to reach them (live roster via `kubectl get services`) | spec'd, backend undecided |
| 2 | `message-agent` | message any sibling by name and read the reply (the mesh's whole point) | spec'd, backend undecided |
| 3 | `check-what-agent-is-doing` | read a sibling's live activity (`-watch/status`) | spec'd, backend undecided |
| 4 | `check-agent-logs` | tail a sibling's event trail (`-watch/events`) | spec'd, backend undecided |

### Universal capability — every agent, regardless of role

| # | Skill | What it is | Source |
|---|---|---|---|
| 5 | `cross-host-execution` | reach the host / another pod / a remote machine from inside a pod (the docker-socket + nsenter bridge and its quoting rules) | already lives in psnvc's MemFS — extract to a clean universal core |
| 6 | `skill-vetter` | security gate before installing any skill | ClawHub `spclaudehome/skill-vetter` |
| 7 | `find-skills` | search/discover skills (ClawHub + OpenClaw Directory + LobeHub + GitHub) | ClawHub `fangkelvin/find-skills-skill` |
| 8 | `clawhub` | download/install skills from ClawHub — the corrected API + owner-disambiguation | ClawHub `douglarek/clawhub-wrapper`, corrected |
| 9 | `creating-skills` | how to make a new skill (init/package/validate, frontmatter spec) | built-in Letta skill — port into the fleet as a `.skill` |

### Pair / role-specific (planner+engineer, the actual unit)

| # | Skill | What it is | Source |
|---|---|---|---|
| 10 | `talk-to-my-engineer` | the clean one-shot relay to the engineer | already in psnvc's MemFS — generalize to any pair |
| 11 | `make-agents-talk` | author the inter-agent relay (identity + one-shot + skill, three artifacts) | already in psnvc's MemFS |
| 12 | `standing-up-agent-pairs` | stand up a planner+engineer pair end-to-end | already in psnvc's MemFS |

### Candidates — flagged, not yet committed to the base set

- `github` (`gh` CLI — 199k downloads on ClawHub): the fleet ships as a repo, so git operations are near-universal. **Leaning in**, needs a port pass.

## Open questions (flag to operator, do NOT assume)

1. **Is the base set 12 (comm 4 + universal 5 + pair 3), or does it trip a size limit?** 12 skills is a lot of per-agent context. The comm 4 and universal 5 are load-bearing for every agent; the pair 3 only ride the planner+engineer unit. Confirm 12 is the right count, or whether the pair 3 should shrink to a single fused "run-a-pair" skill.
2. **Do `cross-host-execution` and the pair skills live verbatim in every agent, or as a shared reference the router copies?** Copy-per-agent matches the comm-layer pattern (bake into each spawned agent); a shared fleet-level skill dir would drift.
3. **Port-from-ClawHub vs. pin-a-hash:** the ClawHub skills (`skill-vetter`, `find-skills`, `clawhub`) currently exist only in psnvc's MemFS, corrected by hand. Do we vendor them into `sudo-fleet` (so the base set is self-contained and reproducible), or pull-at-spawn from ClawHub (fresher, but depends on registry uptime + the owner-disambiguation bug)?

## How the layers relate

Two axes, one set:

- **Comm 4** (aspect #2 of the vision, "the party talks") — *reach and coordinate* with siblings.
- **Universal 5** — *be capable on your own*: touch the machine, grow new skills, vet what you pull.
- **Pair 3** — *exist as a unit*: the planner+engineer seam that spawns and maintains the fleet.

All of it rides the same persona-alignment principle: skill + awareness baked together at spawn-time, or the skill sits unused. The comm 4 is what makes the room a party; the universal 5 + pair 3 is what makes each guest actually worth talking to.
