# Base skills — the universal starter set every fleet agent ships

> Penciled 2026-09-28. This is a **spec**, not yet built — same state as the comm layer (contracts written, backends undecided). The router bakes these into every spawned agent as a spawn-time default, the same way it bakes in the 4 comm tools/skills.

## Why a base set exists at all

The comm layer teaches an agent **how to talk**. The base-skills layer teaches an agent **how to be a capable agent in this fleet**: extend itself, reach the machine, and self-repair. A fleet agent that can only talk is a mouth with no hands.

The meta (operator, 2026-09-28): "give agents personas that tell them to use the skills, and give them a base set of ~10 skills they really should need." Persona = awareness, base skills = capability. Both ship together, or the skills sit unused.

## The rule: where a skill is already Letta-native, don't rebuild it

Before adding a skill to the base set, check whether it already exists as a **built-in Letta skill** (shipped in the `letta-code` image) or a **battle-tested skill in the factory repo**. Rebuilding a skill that already ships is waste; porting one from another harness (Clawdbot/OpenClaw) is a *port*, not a paste — those assume `clawhub install`, `~/.agents/skills/`, and a different runtime, so they need adapting (see the `clawhub` + `find-skills` skills, which were ported this way on 2026-09-28: dead hostnames, fake CLIs).

## The base set (v1 — the ~8 that matter)

Split by who needs it, because a universal skill (every agent) is different from a pair skill (planner+engineer only).

### Universal — every agent, regardless of role

| # | Skill | What it is | Source |
|---|---|---|---|
| 1 | `cross-host-execution` | reach the host / another pod / a remote machine from inside a pod (the docker-socket + nsenter bridge and its quoting rules) | already lives in psnvc's MemFS — extract to a clean universal core |
| 2 | `skill-vetter` | security gate before installing any skill | ClawHub `spclaudehome/skill-vetter` |
| 3 | `find-skills` | search/discover skills (ClawHub + OpenClaw Directory + LobeHub + GitHub) | ClawHub `fangkelvin/find-skills-skill` |
| 4 | `clawhub` | download/install skills from ClawHub — the corrected API + owner-disambiguation | ClawHub `douglarek/clawhub-wrapper`, corrected |
| 5 | `creating-skills` | how to make a new skill (init/package/validate, frontmatter spec) | built-in Letta skill — port into the fleet as a `.skill` |

### Pair / role-specific (planner+engineer, the actual unit)

| # | Skill | What it is | Source |
|---|---|---|---|
| 6 | `talk-to-my-engineer` | the clean one-shot relay to the engineer | already in psnvc's MemFS — generalize to any pair |
| 7 | `make-agents-talk` | author the inter-agent relay (identity + one-shot + skill, three artifacts) | already in psnvc's MemFS |
| 8 | `standing-up-agent-pairs` | stand up a planner+engineer pair end-to-end | already in psnvc's MemFS |

### Candidates — flagged, not yet committed to the base set

- `github` (`gh` CLI — 199k downloads on ClawHub): the fleet ships as a repo, so git operations are near-universal. **Leaning in**, needs a port pass.
- `himalaya` / `imap-smtp-email`: email, but only agents that actually handle mail need it — probably *not* universal, keep as an on-demand install.

## Open questions (flag to operator, do NOT assume)

1. **Is the base set ~8 or ~10?** The operator said "~10." The 8 above are the confident room; `github` is the obvious 9th. What's the 10th — or is "~10" loose enough that 8-9 is fine?
2. **Do `cross-host-execution` and the pair skills live verbatim in every agent, or as a shared reference the router copies?** Copy-per-agent matches the comm-layer pattern (bake into each spawned agent); a shared fleet-level skill dir would drift.
3. **Port-from-ClawHub vs. pin-a-hash:** the ClawHub skills (`skill-vetter`, `find-skills`, `clawhub`) currently exist only in psnvc's MemFS, corrected by hand. Do we vendor them into `sudo-fleet` (so the base set is self-contained and reproducible), or pull-at-spawn from ClawHub (fresher, but depends on registry uptime + the owner-disambiguation bug)?

## How this relates to the comm layer

The comm layer is **aspect #2 of the vision** (the social layer — "the party talks"). The base-skills layer is a **different axis**: it's about individual agent *capability*, not fleet *communication*. Both are baked by the router at spawn-time, both ride the same persona-alignment principle (skill + awareness), but they serve different needs. An agent that talks to its siblings (comm) still needs hands (cross-host) and the ability to grow (skills/tools) — base skills fill that gap.
