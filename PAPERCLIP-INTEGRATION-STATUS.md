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
  letta's stale `deepseek` catalog (now connected as `openai-compatible`), and
  the adapter sending `new_chat` to a door that has no such parameter.

## Still open

- `k8s-down.sh` does not tear Paperclip down as a unit.
- The seeded planner persona (Marc) sometimes answers a heartbeat without
  closing the assigned issue (`SUD-2` stayed `in_progress`). Wiring is fine —
  runs are delivered and succeed — but planner-style agents need the
  manager/objective contract.
- The earlier `paperclip-ops/*` branches (goal-decompose, assign-picker,
  attention-detector, fleet-manager, adapter-env, issue-triage, paperclip-api)
  are still separate and unmerged; they are a *manager-agent* layer on top of
  this auto-hire base and are not required for it to work.
- Demo-default exposure: NodePort `:31310`, no TLS, no edge gate.
