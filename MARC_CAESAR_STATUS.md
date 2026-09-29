# Marc + Caesar — status

Task: make `Marc` (= psnvc, renamed) and `Caesar` (= forge, renamed) come up on any
Linux box via the sudo-fleet README command, seeded from committed glimors — never
a blank Tutor / bare Hermes. Three pieces + fabean acceptance + commit/push.

## Ground truth (verified against live systems, not guesswork)

- **Source agents live on the LIMA host** (lima-ubuntu k3s, v1.36.3+k3s1), NOT fabean:
  - `sudo-psnvc` (Letta planner = the mind half). Active agent = **`agent-local-a290e69d-fc84-495e-b46c-c7ed8aaeeae0`**
    (pinned:true, memfs:true, sessionsByServer -> local-conv-30). Brain = memfs
    `/home/node/.letta/lc-local-backend/memfs/agent-local-a290e69d-.../`.
  - `sudo-forge` (Hermes engineer). State = `/opt/data` identity subset
    (SOUL.md, config.yaml, state.db, .hermes_history, .local/).
- **fabean** is the acceptance target (reachable: `ssh who@<tailnet-ip>`; no magic
  DNS from the lima pod). It ALREADY has sudo-marc + sudo-caesar running from a
  prior attempt that must be WIPED and re-proven.

## Repos (github.com/salmonhealer772/*)

| repo | branch | remote HEAD (at start) |
|---|---|---|
| sudo-letta | master | 1c7dd9b (hostname fix already done+pushed) |
| sudo-agent | main | 55de655 |
| sudo-fleet | main | df3df7c |

## Progress

- [x] Piece 3 — hostname fix: already on remote (1c7dd9b); transform verified (`LaptopOfBlake` -> `laptopofblake`).
- [x] Piece 1 — glimors built under `sudo-fleet/deployments/{Marc,Caesar}/` (narrow rename + scrub, verified clean).
- [x] Piece 2 — `--from-glimor` + initContainer seed in BOTH factories' up.sh; fleet k8s-up.sh passes the committed dirs.
- [ ] Commit + push all 3 repos.
- [ ] fabean acceptance: wipe -> README command -> identity/response evidence.

## Glimor layout

- `deployments/Marc/letta/` = agent record (name=Marc) + memfs brain (persona renamed, all scrubbed) + settings.json.
- `deployments/Caesar/hermes/` = SOUL.md (You are Caesar / planner Marc) + config.yaml + state.db (scrubbed DB-aware) + .hermes_history + .local/.

## Scrub notes (no secrets/PII ship)

- Secrets: Vast + NeedPorts tokens, fabean sudo password — redacted.
- PII: operator/family emails + names, Blake's laptop hostname — redacted.
- state.db: messages emptied (recall bodies), sessions/system_prompts/state_meta kept+scrubbed, FTS rebuilt, VACUUM, WAL checkpointed.

## Next action

1. Commit + push sudo-letta (up.sh), sudo-agent (up.sh), sudo-fleet (README, k8s-up.sh, deployments/, status).
2. fabean: wipe sudo-marc/sudo-caesar + PVCs, clean clone of pushed sudo-fleet, run README command, verify identities.
