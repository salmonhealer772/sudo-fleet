# Marc + Caesar — status

Task: make `Marc` (= psnvc, renamed) and `Caesar` (= forge, renamed) come up on any
Linux box via the sudo-fleet README command, seeded from committed glimors — never
a blank Tutor / bare Hermes. Three pieces + fabean acceptance + commit/push.

## Result: DONE (all three pieces implemented, pushed, and proven on fabean)

## What shipped

| repo | branch | commit | change |
|---|---|---|---|
| sudo-letta | master | 35292c3 | `--from-glimor` initContainer seed in up.sh |
| sudo-agent | main | 8333892 | `--from-glimor` initContainer seed in up.sh |
| sudo-fleet | main | 9b63b06 | committed `deployments/{Marc,Caesar}/` glimors + README + k8s-up.sh |

- Piece 1 — glimors: `deployments/Marc/` (Letta: agent record name=Marc + memfs
  brain a290e69d + settings.json) and `deployments/Caesar/` (Hermes: SOUL.md
  "You are Caesar" + config.yaml + scrubbed state.db + .hermes_history + .local/).
  Narrow rename (psnvc->Marc, forge->Caesar, infra sudo-*/--forge preserved) +
  full secret/PII scrub (verified clean, passes GitHub push protection).
- Piece 2 — seed: both factories' up.sh gained `--from-glimor <dir>`; an
  initContainer copies the committed glimor into the PVC BEFORE the agent process
  runs (idempotent `.glimor-seeded` marker; fail-loud on missing/invalid glimor).
  Fleet k8s-up.sh passes the committed dirs and no longer does post-Ready kubectl cp.
- Piece 3 — hostname: already on remote (1c7dd9b); `LaptopOfBlake -> laptopofblake`.

## fabean acceptance (verified, live)

- Wiped sudo-marc/sudo-caesar + PVCs + services + configmaps (test targets only).
- Clean clone of sudo-fleet + factories; ran README flow (setup.sh + k8s-up.sh).
- Result: sudo-marc + sudo-caesar both 2/2 Running, seeded from committed glimors.
- Marc persisted: record name=Marc, agent-id=a290e69d (the source psnvc id),
  matching memfs brain a290e69d, active agent a290e69d. No blank Tutor.
- Caesar persisted: SOUL "You are Caesar ... paired with Marc", planner=Marc,
  `.glimor-seeded` marker present, scrubbed state.db loaded. No bare Hermes.
- Restart (rollout restart): initContainer skips (marker), state persists,
  committed glimors unchanged (git status clean).

## Scrub result

- No secrets/PII ship: Vast/NeedPorts tokens, DeepSeek/Tavily keys (ghp_/sk-/Bearer
  shapes), operator/family emails + names, fabean sudo password, laptopofblake
  hostname — all redacted. state.db scrubbed DB-aware (messages emptied, metadata
  kept+scrubbed, FTS rebuilt, VACUUM, WAL checkpointed).

## Known nuance (honest)

- Marc's persona.md correctly says "Caesar is my other half, my engineer". The
  `talk-to-my-engineer` SKILL still references "forge" (the reach mechanics are
  kept per the narrow-rename contract: "instructions and knowledge survive",
  infra `sudo-forge`/`--forge` untouched). A direct "who is your engineer" query
  surfaces the skill's "forge"; the persona (the identity) says "Caesar".
- Caesar's live answer fully passes ("I'm Caesar ... my planner is Marc").

## Next / follow-up

- Optional: rename the engineer-NAME reference in `talk-to-my-engineer` skill
  (forge->Caesar, infra-preserving) so Marc's skill matches his persona, if the
  operator wants the skill-level pointer renamed too (currently left per the
  "narrow rename" instruction).
