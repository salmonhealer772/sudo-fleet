---
name: paperclip-heartbeat
description: Put a fleet agent on a Paperclip heartbeat — verify the existing wiring, change the cadence (interval), and give the daily wake real work (daily log + maintenance). Use when an agent must wake on a schedule and do routine work through the Paperclip control plane instead of ad-hoc 120s polling.
---

# paperclip-heartbeat

A Paperclip **heartbeat** is a control-plane timer that wakes a registered agent on an interval and runs it through its adapter (for Letta planners, the `letta_local` adapter driving the live pod's MCP `letta_prompt` door). This skill covers: verifying the existing heartbeat wiring, changing the cadence, giving the daily wake real work, and the exact control-plane endpoints that work (and the ones that 403/404).

## Ground truth about the control plane

- Base URL: `http://192.168.5.15:31310` (same for every agent: `PAPERCLIP_API_URL`).
- Every fleet agent is already registered with the control plane. Auth is a bearer token in the pod env `$PAPERCLIP_API_KEY`; identity is `$PAPERCLIP_AGENT_ID` + `$PAPERCLIP_COMPANY_ID`. **Never write the key anywhere** — run API calls from inside the agent's own pod (`kubectl exec`) so the key never leaves it.
- The authoritative route map is `GET /api/openapi.json` (~728 paths). Read it; do not guess endpoints.
- The heartbeat interval is stored per-agent in `runtimeConfig.heartbeat.intervalSec` (seconds). When `runtimeConfig` is `{}` the scheduler uses the default (~120–150s observed).

## Endpoints that work (verified)

- `GET /api/agents/me` — own record. Returns the RESOLVED view: `adapterConfig` includes the derived `mcpUrl`/`mcpTool`/`agentName`, and `runtimeConfig.heartbeat` is visible.
- `GET /api/agents/{id}` — any agent's record, BUT a cross-agent read REDACTS `adapterConfig` and `runtimeConfig` to `{}`. To see an agent's real heartbeat/interval, read it from that agent's own pod (self-read). This is the single most confusing gotcha: two reads disagree, and the self-read is the truth.
- `GET /api/companies/{companyId}/agents` — full company roster (name, id, status, adapterType, urlKey).
- `GET /api/agents/me/inbox-lite` — work check; returns `[]` when idle.
- `GET /api/companies/{companyId}/issues` | `/goals` | `/routines` — work check (200).
- `GET /api/companies/{companyId}/heartbeat-runs` — heartbeat run history (`invocationSource: "timer"`, per-run `status`/`exitCode`/`stdoutExcerpt`).
- `PATCH /api/agents/{id}` — update agent. Body accepts `runtimeConfig`, `adapterConfig`, `replaceAdapterConfig`, `status`, `instructionsBundle`, etc. **Permission:** cross-agent PATCH returns 403 `Missing permission: agents:configure or agents:suggest-changes`. An agent CAN patch itself: run the PATCH from its own pod against `/api/agents/$PAPERCLIP_AGENT_ID` (NOT `/api/agents/me`, which 404s on PATCH).
- `POST /api/agents/{id}/heartbeat/invoke` — manually fire one heartbeat.
- `POST /api/companies/{companyId}/routines` — create a routine (scheduled work). Body: `{title, description, assigneeAgentId, priority, status}` (`status` enum: `active|paused|archived`). **Permission:** an agent can only create/manage routines assigned to ITSELF — do it from the assignee's own pod with `assigneeAgentId` = its own `$PAPERCLIP_AGENT_ID`.
- `POST /api/routines/{id}/triggers` — add a schedule trigger. Body: `{kind:"schedule", cronExpression, timezone, enabled}`. Cron is **5-field** (min hour dom mon dow); `"0 9 * * *"` + `timezone:"UTC"` = daily 09:00 UTC (read-back shows `nextRunAt`).
- `POST /api/routines/{id}/run` — manually run a routine (accepts an `idempotencyKey`). Returns a run with `status:"issue_created"` + `linkedIssueId`; the created issue is assigned to the routine's `assigneeAgentId` and immediately dispatched (status flips `in_progress` → `done`).

## Endpoints that do NOT work (verified)

- `/api/attention` and `/api/task-sessions` → **404** with a valid key (not real routes). `/attention` and `/task-sessions` at the ROOT (no `/api`) return `200 text/html` — that is the SPA index.html fallback, not an API. (An earlier probe reported 403; with a valid bearer token the truth is 404 for the `/api/*` forms.)
- `/api/agents` (bare list) → `{"error":"API route not found"}`. Use `/api/companies/{companyId}/agents`.
- `PATCH /api/agents/me` → `{"error":"Agent not found"}` (the "me" alias is GET-only). PATCH the real id.

## Procedure

### 1. Verify the existing wiring (ground truth first)

From the host (docker+nsenter bridge, see `cross-host-execution`), read the agent's env and its self-view:

```sh
kubectl exec deploy/sudo-<name> -- bash -c "env | grep -i paperclip"
kubectl exec deploy/sudo-<name> -- bash -c \
  "curl -sS -H 'Authorization: Bearer \$PAPERCLIP_API_KEY' \$PAPERCLIP_API_URL/api/agents/me"
```

Confirm: registration (`id`/`companyId`), `runtimeConfig.heartbeat.intervalSec`, `adapterConfig.mcpUrl` (must point at `sudo-<name>-mcp.<ns>.svc.cluster.local:8000/mcp`), and `lastHeartbeatAt` (recent). Cross-check cadence with `/api/companies/{cid}/heartbeat-runs` filtered by `agentId`.

### 2. Change the cadence to daily

Run from inside the agent's own pod (so the key never leaves it), PATCHing its own id:

```sh
curl -sS -X PATCH -H "Authorization: Bearer $PAPERCLIP_API_KEY" -H "Content-Type: application/json" \
  -d '{"runtimeConfig":{"heartbeat":{"enabled":true,"intervalSec":86400,"maxConcurrentRuns":1}}}' \
  "$PAPERCLIP_API_URL/api/agents/$PAPERCLIP_AGENT_ID"
```

`intervalSec: 86400` = daily. Verify by re-reading `/api/agents/me` from the same pod (the self-read shows the persisted value; a cross-agent read will show `{}`).

### 3. Give the daily wake real work

The heartbeat only *polls*. To make a wake DO something, create a routine (the work definition) + a daily schedule trigger:

```sh
# 1) create the routine (from the assignee's own pod)
curl -sS -X POST -H "Authorization: Bearer $PAPERCLIP_API_KEY" -H "Content-Type: application/json" \
  -d '{"title":"Daily fleet log + maintenance","description":"<the work spec>","assigneeAgentId":"'"$PAPERCLIP_AGENT_ID"'","priority":"medium","status":"active"}' \
  "$PAPERCLIP_API_URL/api/companies/$PAPERCLIP_COMPANY_ID/routines"

# 2) add the daily trigger
curl -sS -X POST -H "Authorization: Bearer $PAPERCLIP_API_KEY" -H "Content-Type: application/json" \
  -d '{"kind":"schedule","cronExpression":"0 9 * * *","timezone":"UTC","enabled":true}' \
  "$PAPERCLIP_API_URL/api/routines/<routineId>/triggers"
```

The trigger fires daily, creates an issue assigned to the agent, and the agent is dispatched immediately (independent of the heartbeat interval). Verify `nextRunAt` in the trigger read-back, then prove the path with a manual `POST /api/routines/{id}/run` — the linked issue should go `in_progress` → `done`, and the agent should write + commit its daily log.

### Daily log + maintenance definition

- **Log location:** the sudo-fleet repo, `logs/<agent>-<YYYY-MM-DD>.md` (UTC date, one file per day).
- **Fixed skeleton** (keep this order so a month of logs is comparable):

      # Daily log — <agent> — <date>
      ## Fleet state          (what changed since the last log)
      ## What broke           (pod restarts, non-zero exits, error-status agents)
      ## Maintenance performed (each check + its result)
      ## Next actions         (1–3 concrete steps)

- **Maintenance checks:** review `docs/KNOWN-ISSUES.md`; detect stale/uncommitted/staged work (`git status --short`, `git branch -vv`); fleet pod health (`kubectl get pods`, flag CrashLoopBackOff/Error/Pending).
- Commit ONLY the log file (`git add logs/<agent>-<date>.md`), never `git add -A`.

## Pitfalls

- **Cross-agent read redacts runtimeConfig/adapterConfig to `{}`.** Always read an agent's heartbeat/interval from its OWN pod.
- **`PATCH /api/agents/me` 404s** — PATCH the real `$PAPERCLIP_AGENT_ID`.
- **Cross-agent PATCH 403s** (missing `agents:configure`) — the agent must patch itself from its own pod.
- **Routine permission:** an agent can only manage routines assigned to itself; create/trigger from the assignee's own pod.
- **Cron is 5-field**; confirm interpretation via `nextRunAt` in the trigger read-back (never assume it fires).
- **`/attention` / `/task-sessions` at root are SPA HTML, not endpoints** — do not treat a 200 there as a real route.
