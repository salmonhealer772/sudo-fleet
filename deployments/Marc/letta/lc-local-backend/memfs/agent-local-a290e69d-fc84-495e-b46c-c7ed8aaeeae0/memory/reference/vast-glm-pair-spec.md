---
description: Spec for the vast-glm-l / vast-glm-h agent pair (Letta planner + Hermes engineer) that operates the Vast.ai A6000 host on fabean. Roles, naming, persona shape, and the skills-first knowledge-transfer model.
---

# vast-glm pair — build spec

A Letta-planner (`vast-glm-l`) + Hermes-engineer (`vast-glm-h`) pair that takes over operating the Vast.ai host on fabean. Deployed on the **lima** k3s cluster (like forge and every other pair). The *target* is fabean, reached over Tailscale SSH.

## The job (what the person talks to vast-glm-l about)

Primary: **operate Vast on fabean** — check machine state, list/unlist, change price, run + fix self-test, monitor the NeedPorts tunnel and the Vast daemon, keep the A6000 rentable. Scope (confirmed 2026-09-28): "its point is vast but it will need to do a lot of other shit too — really only for the ends of 'operate vast good'." So: Vast-first, plus the general fabean admin needed to keep hosting healthy (Docker, k3s, GPU via nvidia-smi, logs, SSH, driver/updates) — all in service of Vast, not free-roam.

## Model
- `vast-glm-l`: **deepseek-v4.1-flash** via DeepSeek official API (`api.deepseek.com`, `LLM_PROVIDER=deepseek`) — same as `rabbit`. (reference/rabbit-second-cluster.md has the working env resolution.)
- `vast-glm-h`: default Hermes engineer model (DeepSeek, as forge).

## Names
- Planner: **vast-glm-l** (the one the person talks to — Letta)
- Engineer: **vast-glm-h** (Hermes)

## Persona shape (IMPORTANT — do NOT bulk the persona)

Both personas must be **good base-agent personas for the work** — a real person with name, role, temperament, goal — NOT a dump of fabean domain knowledge. The domain knowledge does **NOT** go in the persona. Instead:

1. The persona states WHO the agent is and WHAT it is here to do (operate the Vast host on fabean, through its engineer).
2. The persona tells the agent **its domain knowledge lives in its SKILLS**, and it should get good at *loading and using* those skills — not try to memorize fabean/Vast facts.
3. The actual fabean/Vast operational knowledge goes into a set of **high-quality "info manual" skills** (procedural memory) that the agents load on demand — see skills list below.

The planner's persona must also carry the relay (unambiguous engineer identity + verbatim one-shot + no-time-limit env vars) and point to a `reaching-my-engineer` skill — NOT a "figure it out yourself" docker+nsenter hint (that caused the ms-glm core failure). See [[make-agents-talk]] and [[standing-up-agent-pairs]] for the canonical relay recipe.

## Skills to author (the "info manual" set — this is where the domain knowledge lives)

For **vast-glm-l** (planner/systematic; loads + uses these):
1. `skills/reaching-my-engineer/SKILL.md` — the relay: engineer identity (`deploy/sudo-vast-glm-h`, a k3s Deployment on lima, NOT docker/sudo-forge/sudo-FA24), the verbatim `hermes -z` one-shot WITH the three `inf` timeout env vars, the "read result when asked, no monitors" rule.
2. `skills/operating-vast-on-fabean/SKILL.md` — the core info manual: current machine state (id 152421), the two-key model (account key `[REDACTED]...` vs host/install auth that expires hourly), list/unlist/price commands, self-test procedure, what verification means, the CGNAT/public-IPv4 caveat, the NeedPorts port range `33013-33062` + endpoint `15.204.86.122`, and the "rentable ≠ profitable" bottom line.
3. `skills/fabean-access-and-admin/SKILL.md` — fabean ground truth: the two sudo users (`[REDACTED]`/password `[REDACTED]` via `echo [REDACTED] | sudo -S`; `who` with its own kubeconfig `/home/who/.kube/config`), Tailscale SSH re-auth behavior, the hostname/VM ambiguity, Docker+k3s+ollama+nvidia-smi stack, where Vast creds live (`/home/who/vast-hosting/.env`).
4. `skills/vast-daemon-and-tunnel-ops/SKILL.md` — Kaalia daemon (`vastai.service`, `/var/lib/vastai_kaalia/`), the install command + `--reset-machine --no-driver --no-docker --no-libvirt` flags, NeedPorts installer, port range wiring (`host_port_range`/`host_ipaddr`), reading `kaalia.log`/`send_mach_info.log` for the 404/registration state.

For **vast-glm-h** (engineer/technical; the same manuals so it can read them too, plus it owns the HOW).

## Verification (when done)
- Both `sudo-vast-glm-l`/`sudo-vast-glm-h` pods `Running`.
- `letta -p "who are you"` → vast-glm-l answers as itself (NOT "Letta Code"); `hermes -z "who are you"` → vast-glm-h.
- vast-glm-l can actually reach vast-glm-h via the relay (prove by having it run the bridge, not just "pod Running").
- vast-glm-l can reach fabean (e.g. `ssh [REDACTED]@fabean 'hostname'` → `fabean`).

## The persona self-write pitfall (critical, from standing-up-agent-pairs)
For a NEW Letta agent, `persona.md` only sticks if the agent **SELF-WRITES** it inside a session (raw outside file-commit does NOT inject — the `<self>` core-memory block is projected one-way). Have vast-glm-l self-write `system/persona.md` + commit via its own memory/Write tool. Same for the skills: write them into the agent's MemFS and have the agent pick them up. `persona.md` MUST have `--- description: ... ---` frontmatter.

## Record
Log the pair in [[reference/agents-ledger.md]]: name, roles, model, deploy state, skills authored.

## Related
- Relay recipe: [[make-agents-talk]]
- Build procedure: [[standing-up-agent-pairs]]
- fabean/Vast ground truth: [[reference/environment.md]], [[reference/vast-a6000-end-state-prompt.md]]
