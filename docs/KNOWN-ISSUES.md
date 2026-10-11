# Known issues

## Comm layer

### 1. The load-skill-first gate is per-conversation — compaction can leave a tool unlocked

The gate records "skill was loaded" keyed by conversation/session, and the tool
stays unlocked for the rest of that conversation. If a long conversation is
compacted, the skill's text can drop out of context while the gate's "loaded"
record persists — so the tool remains callable, but the agent no longer has the
skill's syntax/guidance in view. The gate guarantees "the skill was loaded at
least once this conversation", NOT "the skill text is still in context". On very
long conversations a compacted agent may call a comm tool from a half-remembered
invocation. (Hermes: `comm-gate/state.json` keyed by `HERMES_SESSION_ID`; Letta:
in-memory map keyed by conversation id.)

### 2. Hermes comm tools are CLI-only — the gate's BLOCKED path isn't reachable by prompt

The three Hermes comm tools are plain CLIs (`/opt/comm-tools/*.py`), not
registered native tools; the skill is the ONLY entry point that teaches the
agent to run them. So a prompt like "call list_siblings without loading any
skill" yields `Tool 'list_siblings' does not exist` — not the gate's BLOCKED —
because there is no native `list_siblings` tool to call, and without the skill
the agent doesn't know the CLI path. The gate's BLOCKED only fires when the CLI
is actually run with its skill unloaded (e.g. a scripted call). The Letta side
is symmetric — its comm tools ARE native mod tools, so the same prompt cleanly
hits the gate's BLOCKED. (Phase 7.)

### 3. ~~Hermes pods run `hermes` without the docker group active~~ — RESOLVED (a4df988)

Fixed by `fix(comm): arm the docker-socket group before the first privilege drop`
(`bin/mcp_entrypoint.sh`), image rebuilt + re-imported (containerd
manifest `827fdada`).

Root cause was not a missing `initgroups` — the drop already uses
`s6-setuidgid hermes`, which does call initgroups — it was ORDER. Our entrypoint
drops the MCP server (and the offline-fallback Redis) to hermes BEFORE the BASE
image's `stage2-hook.sh` has run, and it is stage2-hook — reached only via the
`entrypoint-dispatch.sh` exec on our entrypoint's LAST line — that inspects the
bind-mounted `/var/run/docker.sock`, creates the `hostdocker` group and adds
`hermes` to it. initgroups rebuilds the supplementary list from `/etc/group` AS
IT IS AT THAT MOMENT, so the drop yielded `[10000]` only; the MCP server — and
every `hermes -z` session it spawns, i.e. the whole fleet traffic path — was
denied `/var/run/docker.sock`. The supervised gateway escaped only because
`main-wrapper.sh` drops to hermes AFTER stage2-hook has run.
`securityContext.supplementalGroups` would NOT have helped: s6-setuidgid
rewrites the list from `/etc/group` regardless.

The entrypoint now mirrors stage2-hook's socket block before the first drop,
idempotently, and logs the outcome (`[sudo-agent] docker-socket gid 109 armed for
hermes (comm host bridge OK)`), warning loudly on failure.

Verified clean-room (brand-new agent + brand-new PVC, `sudo-clean-gid-test`):
`mcp_server` supplementary groups `109 10000`; a real MCP-driven `hermes -z`
session reports `groups=10000(hermes),109(hostdocker)` and
`python3 /opt/comm-tools/list_siblings.py --filter gid` reaches the host bridge
and returns the roster. Before the fix the same call failed with
`could not reach the host ... docker permission denied`.

Residual papercut: the `watch` sidecar container overrides the image entrypoint
(`command: [python3, /opt/watch-sidecar/watch_sidecar.py]`) and runs as
`runAsUser: 10000`, so gid 109 is NOT active there. It touches no docker today
(verified: zero docker/nsenter references in `watch_sidecar.py`), but anything
docker-ish added to the sidecar later must arm the gid itself.

## Change-protocol findings — 2026-10-11

Findings from running `docs/CHANGE-PROTOCOL.md` against the live Paperclip
deployment (procedure and full worked example in that doc).

### PC-1. fabean (tailnet box) unreachable from the lima host — HIGH — unresolved

Finding: the fabean-side Paperclip (and its nginx basic-auth front) could not be
inspected; every check against it is unverified and must be reported OPEN.

Evidence: `ssh -o ConnectTimeout=10 who@100.117.138.128 true` →
`Connection timed out`.

Unresolved: yes.

### PC-2. Paperclip heartbeat floor is 10s on the local pod, not 1s — MEDIUM — unresolved

Finding: the "1s heartbeat" startup `sed`-patch of the built `dist/config.js` is
NOT present in the local k3s paperclip; the floor in the running image is 10s.
If a 1s floor is required, it is represented nowhere in the image or the repo, so
any redeploy resets it to 10s.

Evidence: `/app/server/dist/config.js:244` reads
`Math.max(10000, Number(process.env.HEARTBEAT_SCHEDULER_INTERVAL_MS) || 30000)`.

Unresolved: yes — the 1s floor must be moved into the image or into the
`HEARTBEAT_SCHEDULER_INTERVAL_MS` env, not re-applied by hand after deploy.

### PC-3. Bootstrap invite already consumed — INFO — resolved (by design)

Finding: the instance is already bootstrapped, so an unattended re-`claim` would
fail. The repo's `bin/paperclip-up.sh` already branches on this and signs in
with the persisted admin password instead of re-claiming.

Evidence: `/api/health` → `"bootstrapStatus":"ready","bootstrapInviteActive":false`.

Unresolved: no.

### PC-4. Advertised nginx basic-auth layer absent from the local image — MEDIUM — unresolved

Finding: no `nginx.conf` or `htpasswd` exists anywhere in the local paperclip
image; there is no reverse-proxy auth layer on this box at all. The empty-htpasswd
drift (auth "on" but the credential file is zero bytes) is a fabean-side artifact
and could not be verified this run.

Evidence: `find / -iname nginx.conf -o -iname htpasswd` inside the pod → nothing.

Unresolved: yes (fabean unreachable).

### PC-5. NodePort 31310 exposed with no edge auth gate — LOW — unresolved

Finding: `svc/paperclip-node` (NodePort 3100:31310) exposes the app on
`192.168.5.15:31310` with no TLS and no proxy auth in front. `/api/health` is
open; the API endpoints are guarded only by the app's own auth.

Evidence: `curl /api/health` → 200; `curl /api/companies` (no auth) → 403;
`curl /api/companies` (Bearer bogus) → 401.

Unresolved: yes.

### PC-6. No recent database backup — LOW — unresolved

Finding: the health endpoint reports `database_backup_missing`.

Evidence: `/api/health` →
`"databaseBackup":{"enabled":true,"status":"warning",...}`.

Unresolved: yes.
