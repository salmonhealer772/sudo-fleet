# Paperclip Integration — Status (2026-10-07)

## Where we are

Paperclip is now **native to sudo-fleet**: bringing the fleet up brings the
control plane up and hires every agent, and building an agent hires that agent.
The core deliverable — **new-agent auto-hire** — is done and proven live, not
self-reported.

Target repo: `salmonhealer772/sudo-fleet`, branch `paperclip`. Code home:
`bin/paperclip-{up,hire,adopt}.sh`, `factories/paperclip-letta-adapter/`,
`docs/PAPERCLIP.md`.

## Proven on a fresh VM (paperclip-test, Ubuntu 24.04, 2 vCPU / 4 GB, 2026-10-07)

Box: `64.176.193.148`, root password auth. Clean install from the repo README.

1. `bash setup.sh` → COMPLETE. Docker + k3s (v1.36.5+k3s1) + all three images
   (`hermes-agent:latest`, `sudo-agent:latest`, `sudo-letta:latest`).
2. `cd bin && bash k8s-up.sh` → Marc 2/2, Caesar 2/2, then step 5/5 deployed
   Paperclip (ns `paperclip`, Postgres 1/1, app 1/1, `/api/health` ok,
   external adapter `letta_local` loaded) and hired **both** agents:
   `✓ all sudo-fleet agents are hired in Paperclip`.
3. `bash factories/sudo-letta/bin/up.sh --smoketest` → a **brand-new** agent,
   and its deploy log ends with
   `✓ hired 'Smoketest' as Paperclip agent 0f23f9b0-…` — no manual step.
4. Issue `SUD-3` created and assigned to that new agent → `todo` →
   `in_progress` → **`done`** in 75 s, with an agent-authored comment
   (`authorType: "agent"`, `createdByRunId` set).

### Read-backs

| Check | Result |
|---|---|
| agents hired | Marc `eee275f1…`, Caesar `e70ed882…`, Smoketest `0f23f9b0…`, all `adapterType: letta_local` |
| heartbeat | `{enabled: true, intervalSec: 120, maxConcurrentRuns: 1}` on all three |
| heartbeat runs | `MCP-DONE … isError=false`, `CLOSE exit=0`; agent status `idle` |
| MCP doors | `sudo-{marc,caesar,smoketest}-mcp` services all have endpoints |
| live-agent completion | `letta -p "Reply with exactly: PONG"` → `PONG` |
| `tags` | `["origin:letta-code","git-memory-enabled"]` (no tutorial/onboarding tags → real persona) |
| `context_window_limit` | `128000`, under the served cap (no 400 overflow) |
| memfs | git-committed (`seed-fork-state`, `seed comm skills`) |
| issues | `SUD-1` (Marc) done; `SUD-3` (new agent) done |

## Clean-room repro (same day, from the final commit)

All fleet + control-plane state wiped (`ns paperclip`, every `sudo-*`
deployment/service/configmap/secret/PVC, `/logs/paperclip`), then a **pristine
clone** of the branch tip (`d8ecda3`) was used end to end:

1. `bash bin/k8s-up.sh` → Marc 2/2, Caesar 2/2, Paperclip deployed fresh,
   `✓ all sudo-fleet agents are hired in Paperclip` — Marc `3c4e96a6…`,
   Caesar `a864e11e…`.
2. `bash factories/sudo-letta/bin/up.sh --reprobe` → NEW agent, log ends
   `✓ hired 'Reprobe' as Paperclip agent 4dff7a8d-…`.
3. Issue assigned to Reprobe → `done` at `2026-10-07T07:03:42Z` with an
   agent-authored comment (`authorType: "agent"`, `authorAgentId:
   4dff7a8d-…`, `createdByRunId: 6769b39a-…`).

This run is also what found the NodePort-range defect (reprobe first hashed to
port 30765 and could not be reached from another pod — see
[`docs/PAPERCLIP.md`](docs/PAPERCLIP.md#pitfalls-this-integration-had-to-solve-all-fixed-in-repo)).

## What landed (branch `paperclip`)

- `bin/paperclip-up.sh` — deploy the control plane, register the `letta_local`
  external adapter from a **prebuilt** `dist/`, then bootstrap an instance admin
  + board API key + company into `/logs/paperclip/paperclip.env` (0600).
- `bin/paperclip-hire.sh` — hire one agent: record + heartbeat + injected
  `PAPERCLIP_*` env into the agent's own Deployment.
- `bin/paperclip-adopt.sh` — reconcile every `sudo-*` deployment.
- Wiring so it is automatic: `k8s-up.sh` step 5/5, both factory `up.sh` scripts,
  and `k8s-auto-up.sh` on every boot.
- Adapter v0.3.1 — `apiUrl` config + a Paperclip control-plane block appended to
  every heartbeat prompt (the env-forwarding piece a previous session reported
  done but never landed).
- Repo-level fixes found by this run: stale `sudo-agent` heredoc guard (blocked
  the Caesar deploy), `letta model set` double-prefixing the model handle,
  letta's stale `deepseek` catalog (now connected as `openai-compatible`), the
  adapter sending `new_chat` to a door that has no such parameter, and
  per-agent MCP/WATCH ports colliding with the Kubernetes NodePort range
  (30000–32767) which made a hostNetwork agent unreachable from other pods.

## Still open

- `k8s-down.sh` does not tear Paperclip down as a unit.
- One of four issue runs on the seeded **planner** persona (Marc) stayed
  `in_progress` (`SUD-2`). Wiring was fine — a run was delivered and succeeded
  — so this is agent behaviour (answering without closing), and it needs the
  manager/objective contract rather than a wiring fix. Fresh agents close
  reliably (3 of 3), and Paperclip's own recovery closed the blocked
  clean-room issue once the door was reachable.
- A fresh agent is briefly unreachable for the few seconds its pod restarts
  after auto-hire injects `PAPERCLIP_*` env. Creating an issue inside that
  window now yields a blocked issue that Paperclip's recovery re-drives, but a
  readiness gate before the hire returns would be cleaner.
- The earlier `paperclip-ops/*` branches (goal-decompose, assign-picker,
  attention-detector, fleet-manager, adapter-env, issue-triage, paperclip-api)
  are still separate and unmerged; they are a *manager-agent* layer on top of
  this auto-hire base and are not required for it to work.
- Demo-default exposure: NodePort `:31310`, no TLS, no edge gate.
