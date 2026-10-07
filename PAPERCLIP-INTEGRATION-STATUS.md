# Paperclip Integration — Status (2026-10-06)

## Where we are
Building a "Paperclip section" in sudo-fleet so normal sudo-fleet agents (ONalwase/Marc = Letta planners, Caesar = Hermes engineer) can be registered as Paperclip agents, get heartbeats, and work the Paperclip issue/goal system. ONalwase is the designated **fleet manager** (always-on; scans goals, decomposes into child issues, assigns to Marc/Caesar, follows up; silent unless asked or something breaks).

Target repo: `salmonhealer772/sudo-fleet`, branch `paperclip`. New code home: `factories/paperclip-ops/ops/` (comm-style: `docs/-CONTRACT.md`, `features/.feature`, `skills//SKILL.md`, `tests/test_*.py`, `tools/*.py`).

## What's DONE (verified — files actually on origin)
### Live / Paperclip side
- Paperclip deployed in k3s ns `paperclip` (+ Postgres), bootstrap `ready`, admin creds in `/logs/paperclip/credentials.txt`.
- **3 Paperclip agents hired**: ONalwase (`letta_local`→`sudo-onalwase-mcp`, heartbeat 5s), Marc (`letta_local`→`sudo-marc-mcp`, 600s), Caesar (`hermes_gateway`→`sudo-caesar-mcp`, 600s).
- Custom `letta_local` adapter registered + driving the LIVE pod (not a clone), `inbox` mode, heartbeat prompt delivered.

### Repo (verified files on `paperclip-ops/*` branches)
- `paperclip_api.py` (control-plane: issues/goals/routines) ✅
- `issue_triage.py` ✅
- `task_planning.py` ✅
- `summarize_status.py` + `status_card_query.py` ✅
- 9 `docs/*-CONTRACT.md` ✅
- (partial) tests/conftest/fakes ✅
- 10 official Paperclip skills imported into memory + the `fa-glm-skills` repo.

## What's MISSING (reported "DONE" but branches are EMPTY on origin)
⚠️ These were self-reported complete by the DeepSeek lings but **0 files landed**:
- `paperclip-ops/adapter-env` — the CRITICAL env-forwarding fix (forward PAPERCLIP_* run JWT/env through letta_local so ONalwase can self-auth). REBUILD REQUIRED.
- `paperclip-ops/goal-decompose` — goal→child-issue graph engine.
- `paperclip-ops/assign-picker` — role→live-agent mapping (dynamic roster).
- `paperclip-ops/attention-detector` — "needs human" escalation.
- `paperclip-ops/fleet-manager` — the manager SKILL + heartbeat Objective contract.
- `paperclip-ops/harness` (fa-glm-h6) — ops_gate/ops_tools/conftest (never persisted).

## What's NEXT (next session)
1. REBUILD the 6 missing pieces (NOT re-trust self-reports — verify each branch has real files before accepting).
2. Merge all `paperclip-ops/*` into `paperclip` (file-disjoint; do merges + read-back myself).
3. Run the full pytest suite once merged.
4. Deploy live: re-apply adapter env-forwarding to the cluster, set ONalwase's manager prompt (scan goals → decompose → assign → follow up → silent unless asked/breaking).
5. Prove end-to-end: set a Goal → ONalwase decomposes → assigns Marc/Caesar → child issue. ## Correct next anchor
