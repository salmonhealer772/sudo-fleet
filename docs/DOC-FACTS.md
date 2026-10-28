# DOC-FACTS — evidence appendix

Every factual claim the documentation makes, with the place it was checked, so the
next maintainer can tell which sentences are load-bearing and which have gone
stale. This is the documentation equivalent of a test suite.

Checked against a read-only working copy of the repo tree at
`/tmp/oct26/sudo-fleet-documentation/src/repo`, which is commit `1894b0b`
(2026-10-27) byte-for-byte: its `docs/SPEC.md` and `git show 1894b0b:docs/SPEC.md`
are the same file, both `md5 dbce5422b010ad3b523a945bb30b23f7`. Every range was
re-derived and re-grepped rather than shifted arithmetically — re-derived at
`9559afe`, then every cite re-resolved against the tree at `dc065db` (exact path,
then line count). `docs/SPEC.md` is unchanged since `9559afe`, so its re-points
below stand at HEAD. Re-grep before trusting a range after edits.

**Path rules (several filenames exist more than once).** Every cite is relative to
the repo root and carries the directory that makes it unambiguous:
`factories/sudo-agent/bin/up.sh`, never a bare `bin/up.sh`. Resolve the exact path
from the root first; a cite that still does not resolve from the root lives under
`factories/sudo-agent/` — `comm/README.md` is
`factories/sudo-agent/comm/README.md`. The factory modules are never cited bare:
they are `factories/sudo-agent/bin/api_server_ports.py`,
`factories/sudo-agent/comm/tools/comm_gate.py` and
`factories/sudo-agent/comm/tools/list_siblings.py`. `up.sh` exists four times and
`gate.mjs` six times, so both are always cited in full. `README.md` exists 18 times:
a bare `README.md` is the repo-root one, and a factory README is always qualified.
`setup.sh` unqualified in a row whose claim is Command-1 behaviour means the
**repo-root** script, and every such row says `(repo root)` beside the cite; the
other two are first-run factory scripts, `factories/sudo-agent/setup.sh` and
`factories/sudo-letta/setup.sh`, and are never meant.

**SPEC re-points.** `60dc842` — the commit that created this appendix — rewrote
`docs/SPEC.md` in the same commit, so every SPEC range measured off the copy was
stale the moment it was committed. SPEC cites are written `snapshot line → live
line`: `docs/SPEC.md:108` → `:121` means the claim was measured at `:108` in
`1894b0b` and `:121` is the line that carries it at HEAD. Every row with an arrow
is marked SNAPSHOT-ONLY, and so is any cite whose source exists only in the
snapshot, such as the `docs/MARC_CAESAR_STATUS.md` receipt deleted in `07d5d77`.

**Status vocabulary** — VERIFIED (seen in the cited file at the cited lines, as
stated) · STALE (doc says X, code says Y; corrected value in the row) · INFERRED
(not stated anywhere, concluded from adjacent evidence — the weakest status) ·
UNVERIFIED (could not be checked from the material handed over) · ABSENT (the file
or the claim's source is not in the tree) · SNAPSHOT-ONLY (resolves at `1894b0b`,
not at the rewrite; the re-pointed line is in this row)

**Missing inputs (read this first).** Three items named in the commissioning brief
were not present in the material: `FACTS.md` (nowhere under the handed-over tree,
`/tmp`, `/opt/data`, `/root` or `/home`), `PAPERCLIP-INTEGRATION-STATUS.md` (the
repo has `docs/PAPERCLIP.md` instead), and the repo-root `.gitignore`. Section 8
therefore cannot enumerate "D1–D6 from FACTS.md"; it lists the defect claims the
available material *does* contain, numbered as the sources number them. Nothing
here contradicts a FACTS.md that could not be read — see OPEN.

## 1. Layout and entry points

| CLAIM | VERIFIED WHERE | STATUS |
|---|---|---|
| `setup.sh` is Command 1 of 2: bootstrap only, explicitly does not deploy agents | `setup.sh:4-9` (repo root) | VERIFIED |
| `setup.sh` prompts for exactly three fields and writes them to `<repo>/.env`, mode 600 | `setup.sh:19-26`, `158-173`, `275-280` (repo root); `bin/k8s-up.sh:182-184` | VERIFIED |
| `setup.sh` derives the rest (`DEEPSEEK_API_KEY`, `API_KEY`, `LLM_PROVIDER`, `LLM_MODEL`) rather than prompting | `setup.sh:23-26`, `235-242`, `274-280` (repo root); `bin/k8s-up.sh:107-127` | **STALE (partial)** — `DEEPSEEK_API_KEY`, `API_KEY` and `LLM_PROVIDER` are derived (`:274-280`, `:235-242`); `LLM_MODEL` IS prompted when the endpoint is custom (`:250-257`), so "the rest, never prompted" overstates it |
| `setup.sh` runs five stages in order: keys, Docker, k3s, env-var bridge, image build; plus a durability step installing a boot unit | `setup.sh:146`, `325`, `380`, `441`, `466`, `486` (repo root) | VERIFIED |
| `bin/k8s-up.sh` is Command 2; it requires an existing k3s and dies without a kubeconfig | `bin/k8s-up.sh:4-16`, `99-102` | VERIFIED |
| `bin/k8s-up.sh` re-seeds the fleet `.env` and both factory env files so factory `up.sh` calls see the same credentials | `bin/k8s-up.sh:162-208` | VERIFIED |
| `bin/k8s-up.sh` deploys exactly two agents, planner first then engineer, each via that factory's `up.sh --<name> --from-glimor <dir>` | `bin/k8s-up.sh:210-223` | VERIFIED |
| `bin/k8s-up.sh` verifies both PVCs and four Services (`-mcp` and `-watch` for each agent) and dies if any is missing | `bin/k8s-up.sh:232-242` | VERIFIED |
| `bin/k8s-up.sh` ends with the Paperclip control plane plus auto-hire, deliberately non-fatal | `bin/k8s-up.sh:244-260` | VERIFIED |
| Only two entry points exist for an operator: `setup.sh` then `bin/k8s-up.sh` | `setup.sh:11-16` (repo root); `README.md:6-12`, `109-113` | **STALE** — the repo now documents three commands, not two: `setup.sh` ①, `bin/k8s-up.sh` ②, `bin/talk.sh` ③ (`README.md:6-7`). ③ opens a session rather than standing anything up, so "two entry points" still holds for bringing the fleet up and fails as written for the operator's command sequence |
| Deployment naming rule is `sudo-<name>`, so a bare name that already starts with `sudo-` yields a doubled prefix (`sudo-sudo-...`) | `factories/sudo-agent/DESIGN.md:35`; `factories/sudo-letta/bin/up.sh:33` | VERIFIED |
| PVC naming rule is `sudo-<name>-data` | `factories/sudo-letta/bin/up.sh:337`; `factories/sudo-agent/DESIGN.md:36` | VERIFIED |
| Each factory writes its generated manifest to `<factory>/deployments/<name>.yaml` | `factories/sudo-letta/bin/up.sh:32-34`; `factories/sudo-agent/bin/up.sh:51-54` | VERIFIED |
| Both factory `up.sh` emit the same closing summary: Queue, Talk, Shell, MCP, Watch, Logs, Stop | `factories/sudo-agent/bin/up.sh` (tail); `factories/sudo-letta/bin/up.sh` (tail) | VERIFIED |
| Each factory `up.sh` accepts `--from-glimor <dir>` and seeds it through an initContainer that runs before the agent process | `bin/k8s-up.sh:10-14`, `35-41`, `215`, `222`; `factories/sudo-letta/bin/up.sh:12` | VERIFIED |
| `--ALL` / `--all` is a reserved word; no script accepts it as an agent name | `factories/sudo-letta/bin/up.sh:24-26`; `factories/sudo-agent/DESIGN.md:38` | VERIFIED |
| A missing or invalid glimor fails the deploy loudly rather than producing a blank agent | `bin/k8s-up.sh:13-14`; `docs/ARCHITECTURE.md:45-48` | VERIFIED |

## 2. Ports

Every pod runs `hostNetwork: true`, so every port a pod binds is a node-global
resource. That single fact drives all of the derivation below.

| CLAIM | VERIFIED WHERE | STATUS |
|---|---|---|
| MCP port is `8000 + cksum(name) % 22000` | `factories/sudo-letta/bin/up.sh:57`; `factories/sudo-agent/bin/up.sh:82` | VERIFIED |
| The cksum window is 22000 values, i.e. 8000..29999 | `factories/sudo-letta/bin/up.sh:44-56` (comment states the window and its reason) | VERIFIED |
| Watch port is hashed from the different string `<name>-watch` so it does not collide with MCP | `factories/sudo-letta/bin/up.sh:63`; `factories/sudo-agent/bin/up.sh:87` | VERIFIED |
| Collision bump: if watch and MCP hash to the same port, watch is incremented by one | `factories/sudo-letta/bin/up.sh:64-66`; `factories/sudo-agent/bin/up.sh:88-90` | VERIFIED |
| Reserved range 1 — Kubernetes NodePort 30000..32767; a hostNetwork listener inside it is unreachable from other pods because kube-proxy intercepts and drops the packet | `factories/sudo-letta/bin/up.sh:48-53`; `factories/sudo-agent/bin/api_server_ports.py:71` | VERIFIED |
| Reserved range 2 — Linux ephemeral 32768..60999 (`ip_local_port_range`) | `factories/sudo-letta/bin/up.sh:54`; `factories/sudo-agent/bin/api_server_ports.py:72` | VERIFIED |
| The Hermes `api_server` port is *not* derived in `up.sh`; it is assigned by `bin/api_server_ports.py` into 61000..65535 | `factories/sudo-agent/bin/up.sh:92-96`; `factories/sudo-agent/bin/api_server_ports.py:76-79` | VERIFIED |
| `api_server` port = SHA-256 of `api-server:<name>` modulo 4536, linear-probed on collision, so it is machine-independent | `factories/sudo-agent/bin/api_server_ports.py:28-32`, `85-89` | VERIFIED |
| The `api_server` env block binds `0.0.0.0` on purpose so a non-hostNetwork pod can reach it through a ClusterIP Service | `factories/sudo-agent/bin/up.sh:951-962` | VERIFIED |
| A guard refuses to deploy a config that resolves to the built-in default 8642 or to a duplicate `api_server` port | `factories/sudo-agent/bin/up.sh:537-545`; `factories/sudo-agent/bin/api_server_ports.py:80` | VERIFIED |
| Offline fallback Redis port is `40000 + (MCP_PORT*7) % 20000` = 40000..59999, injective over the MCP range | `factories/sudo-agent/DESIGN.md:252-256`; `factories/sudo-agent/bin/api_server_ports.py:73` | VERIFIED |
| Each Service exposes the stable client port 8000 and forwards to the per-agent port | `factories/sudo-letta/bin/up.sh:494-526`; `factories/sudo-agent/bin/up.sh:1163-1186` | VERIFIED |
| The deterministic port scheme is `8642 + cksum(name) % 5000` | `docs/SPEC.md:26` → `:37` | **STALE** · SNAPSHOT-ONLY — and the doc now flags its own figure: `docs/SPEC.md:37` quotes `8642 + cksum(name)%5000` and calls it stale, pointing at `ARCHITECTURE.md` for the shipped formulas. Corrected value: `8000 + cksum(name) % 22000`, range 8000..29999 (`factories/sudo-letta/bin/up.sh:57`). 8642 is now a *forbidden* value, not a base (`factories/sudo-agent/bin/api_server_ports.py:80`; guard at `factories/sudo-agent/bin/up.sh:543`) |
| `docs/PAPERCLIP.md` describes the same window as `8000 + hash % 22000` = 8000..29999 | `docs/PAPERCLIP.md:99-107` | VERIFIED — agrees with the code; the stale statement is confined to SPEC.md |

## 3. Agent spec

| CLAIM | VERIFIED WHERE | STATUS |
|---|---|---|
| Deployment strategy is `Recreate`, not RollingUpdate, because the new pod would need the same node-global port the old pod still holds | `factories/sudo-letta/bin/up.sh:357-363`; `factories/sudo-agent/bin/up.sh:884-891` | VERIFIED |
| Pod sets `hostNetwork: true` | `factories/sudo-letta/bin/up.sh:376`; `factories/sudo-agent/bin/up.sh:927` | VERIFIED |
| Pod sets `shareProcessNamespace: true` so the sidecar sees the agent container's processes | `factories/sudo-letta/bin/up.sh:375`; `factories/sudo-agent/bin/up.sh:926`; `factories/sudo-letta/DESIGN.md:81` | VERIFIED |
| The agent container is `privileged: true` | `factories/sudo-letta/bin/up.sh:388`; `factories/sudo-agent/bin/up.sh:936` | VERIFIED |
| The watch sidecar runs the same image with an explicit `command`, mounts no docker socket, and has no privileged securityContext | `factories/sudo-letta/bin/up.sh:419-431`; `factories/sudo-letta/DESIGN.md:89` | VERIFIED |
| Hermes watch sidecar explicitly sets `runAsUser: 10000` and `runAsNonRoot: true` | `factories/sudo-agent/bin/up.sh:1040-1041` | VERIFIED |
| Letta watch sidecar sets no securityContext at all and therefore runs as the image's own user | `factories/sudo-letta/bin/up.sh:419-431` (no securityContext key present) | INFERRED — the numeric uid is not stated in the files read |
| Doc claim that the watch sidecar runs as uid 10000 and does *not* carry the docker gid | `docs/KNOWN-ISSUES.md:60-64` | VERIFIED for Hermes only (`factories/sudo-agent/bin/up.sh:1019`); it is stated as a residual papercut, not a defect |
| Three probes on the agent container: `startupProbe`, `readinessProbe`, `livenessProbe`, all `tcpSocket` on the MCP port | `factories/sudo-letta/bin/up.sh:401-418`; `factories/sudo-agent/bin/up.sh:1013-1025` | VERIFIED |
| Three probes on the watch container: all `httpGet /healthz` on the watch port | `factories/sudo-letta/bin/up.sh:440-456`; `factories/sudo-agent/bin/up.sh:1066-1080` | VERIFIED |
| PVC is `<deploy>-data`, 10Gi, ReadWriteOnce | `factories/sudo-letta/bin/up.sh:335-346` | VERIFIED |
| Two Services per agent: `<deploy>-mcp` (8000 -> MCP port) and `<deploy>-watch` (8000 -> watch port) | `factories/sudo-letta/bin/up.sh:492-526` | VERIFIED |
| Hermes agents additionally get a third Service for the `api_server` | `factories/sudo-agent/bin/up.sh:1209-1216` | VERIFIED |

## 4. Queue

| CLAIM | VERIFIED WHERE | STATUS |
|---|---|---|
| Letta queue backing is Deployment `sudo-letta-redis`, `hostNetwork`, bound to `127.0.0.1:6379`, persistence disabled | `factories/sudo-letta/bin/redis.yaml:10-39` | VERIFIED |
| Letta `up.sh` applies that Redis before applying the agent and aborts the deploy if the apply fails | `factories/sudo-letta/bin/up.sh:606-611` | VERIFIED |
| Hermes queue backing is Deployment `sudo-agent-redis` on the node loopback, default port 6380, overridable with `SUDO_AGENT_REDIS_PORT` | `factories/sudo-agent/bin/redis-up.sh:62-66`, `190-210` | VERIFIED |
| Hermes Redis is PVC-backed with AOF `appendfsync everysec`; only losing the PVC loses the queue | `factories/sudo-agent/bin/redis-up.sh:39-41`, `136-146`, `195-208` | VERIFIED |
| Hermes Redis refuses to deploy when the node port is held by a process it does not own, naming the fix | `factories/sudo-agent/bin/redis-up.sh:96-130` | VERIFIED |
| Port ownership is split by fleet: Letta owns 6379, Hermes owns 6380; the port is node-global so exactly one process per port | `factories/sudo-agent/bin/redis-up.sh:26-37`; `factories/sudo-agent/DESIGN.md:85-89` | VERIFIED |
| The Hermes queue must be reached by loopback, never by Service name, because a hostNetwork pod gets the node resolver | `factories/sudo-agent/bin/redis-up.sh:13-22`; `factories/sudo-agent/DESIGN.md:64-72` | VERIFIED |
| Letta key namespace is `sudo-letta:q:<POD_NAME or MCP_PORT>`, with `:items` and `:res:<id>` | `factories/sudo-letta/bin/mcp_server.py:81-89` | VERIFIED |
| Hermes key namespace is `sudo-agent:q:<AGENT_NAME or POD_NAME or MCP_PORT>`, with `:items`, `:inflight`, `:res:<id>` | `factories/sudo-agent/bin/mcp_server.py:118-129` | VERIFIED |
| Hermes claims a message atomically: one WATCH/MULTI transaction removes it from `:items` and pushes it to `:inflight`, retrying on `WatchError` | `factories/sudo-agent/bin/mcp_server.py:211-246` | VERIFIED |
| Hermes requeues items abandoned in `:inflight` by a crash, preserving order, at-least-once | `factories/sudo-agent/bin/mcp_server.py:248-259` | VERIFIED |
| Letta's drain worker has no atomic claim: it lists, picks, runs, then `LREM`s afterwards — the item stays visible as pending while it runs | `factories/sudo-letta/bin/mcp_server.py:227-251` (removal after execution at ~247) | VERIFIED — asymmetry is real; do not document "the claim is atomic" as a fleet-wide property |
| Ordering rule implemented identically on both sides: first message first, then drain that sender fully, then the most-recent other sender, FIFO within a sender | `factories/sudo-letta/bin/mcp_server.py:190-208`; `factories/sudo-agent/bin/mcp_server.py:190-208` | VERIFIED |
| The same four-part ordering rule is stated verbatim in the design docs | `factories/sudo-agent/DESIGN.md:246-250`; `factories/sudo-letta/DESIGN.md:140-145`; `docs/SPEC.md:198-204` → `:213-219` | VERIFIED · SNAPSHOT-ONLY |
| Exactly one drain worker per pod feeds the agent one prompt at a time | `factories/sudo-agent/bin/mcp_server.py:278-304`; `factories/sudo-letta/bin/mcp_server.py:227-251` | VERIFIED |
| Results are kept in Redis with a 7-day TTL for inbox-mode pickup | `factories/sudo-letta/bin/mcp_server.py:211-224`; `factories/sudo-agent/bin/mcp_server.py:262-275` | VERIFIED |
| Hermes is stateless per invocation (`hermes -z`), so there is no conversation resume on that side | `factories/sudo-agent/DESIGN.md:198`; `factories/sudo-agent/README.md:120-121` | VERIFIED |
| Letta resumes the persisted conversation unless `new_chat` is set | `factories/sudo-letta/DESIGN.md:58-61` | VERIFIED |
| The tool default mode is `inbox`, not `direct` | `factories/sudo-agent/bin/mcp_server.py:318-321`; `factories/sudo-letta/bin/mcp_server.py:271-276` | **STALE** in the docs — both READMEs and both design docs present `direct` as the default (`factories/sudo-agent/README.md:108-110`, `factories/sudo-agent/DESIGN.md:195-196`, `factories/sudo-letta/README.md:196-198`, `factories/sudo-letta/DESIGN.md:126-130`); the code default is `inbox` |
| Letta has no fallback to direct spawning — queue is the only path to the agent, and it exits loudly when Redis is unreachable | `factories/sudo-letta/DESIGN.md:150-154` | UNVERIFIED — the fail-fast startup ping was not read |

## 5. Comm layer

| CLAIM | VERIFIED WHERE | STATUS |
|---|---|---|
| Exactly three comm tools ship: `list-siblings`, `message-agent`, `check-agent` | `factories/sudo-agent/comm/README.md:21-28`; `docs/SPEC.md:108` → `:121` | VERIFIED · SNAPSHOT-ONLY |
| Hermes gate is a CLI prelude that exits 69 (`EX_UNAVAILABLE`) with `BLOCKED: load the <skill> skill first, then retry.` before building any transport | `factories/sudo-agent/comm/tools/comm_gate.py:44-46`, `90-104` | VERIFIED |
| Hermes gate state is `<HERMES_HOME>/comm-gate/state.json` keyed by `HERMES_SESSION_ID`, and is fail-open when that variable is unset | `factories/sudo-agent/comm/tools/comm_gate.py:20-35`, `61` | VERIFIED |
| Letta gate is an in-memory Map keyed by conversation id, with the same BLOCKED contract | `factories/sudo-letta/mods/list-siblings/mods/gate.mjs:6-14`, `18-19`, `36-37`, `74` | VERIFIED |
| The Letta gate never persists, so a new conversation is never unblocked by an old one | `factories/sudo-letta/mods/list-siblings/mods/gate.mjs:12-14` | VERIFIED |
| The host bridge is `docker run --rm --privileged --pid=host --net=host -v /:/host <image> nsenter -t 1 -m -u -i -n -p -- env KUBECONFIG=<path> <argv>` | `factories/sudo-agent/comm/tools/real_transport.py:13-15`, `152-167` | VERIFIED |
| The roster comes from `kubectl get services -n default` executed on the host through that bridge | `factories/sudo-agent/comm/tools/list_siblings.py:15`, `104` | VERIFIED |
| The roster is not fleet- or project-scoped: the command filters by namespace only, so any Service in `default` is a candidate sibling | `factories/sudo-agent/comm/tools/list_siblings.py:104` (no selector, label or fleet filter) | VERIFIED for the command; INFERRED that every `sudo-*` Service in the namespace appears |
| `message-agent` reaches a sibling through its `-mcp` surface; `check-agent` reads the sibling's `-watch` trail | `factories/sudo-agent/comm/README.md:24-27`; `docs/SPEC.md:148-160` → `:145-150` | VERIFIED · SNAPSHOT-ONLY — the table at `:145-150` still names the pre-merge pair (`check-what-agent-is-doing`, `check-agent-logs`); `:121` records the merge into `check-agent` |
| Known gap: the gate is per-conversation, so compaction can leave a tool callable after its skill text has left context | `docs/KNOWN-ISSUES.md:5-15` | VERIFIED (recorded defect) |
| Known gap: on Hermes the comm tools are plain CLIs, so a prompt naming the tool hits "does not exist" instead of the gate's BLOCKED | `docs/KNOWN-ISSUES.md:17-27` | VERIFIED (recorded defect) |
| Per-agent scoping of the mesh is a stated *future* direction, not an as-built property | `docs/NEXT.md:45-49`, `75-79`; `docs/SPEC.md:5-12` → `:16-23` | VERIFIED · SNAPSHOT-ONLY |

## 6. Identity

| CLAIM | VERIFIED WHERE | STATUS |
|---|---|---|
| Letta loads only **git-committed** memory; an untracked MemFS is silently ignored and the agent wakes blank | `docs/ARCHITECTURE.md:73-78`; `docs/OPERATIONS.md:271-278` | VERIFIED · SNAPSHOT-ONLY — the original receipt, `docs/MARC_CAESAR_STATUS.md:9-12`, was deleted in `07d5d77` (instance identity out of the repo); the claim is restated in full in ARCHITECTURE |
| The Letta seed path is `git init` + `git add -A` + `git commit` before the agent starts | `docs/ARCHITECTURE.md:264-268`; `factories/sudo-letta/bin/mcp_entrypoint.sh:58-59` | VERIFIED |
| A committed glimor must stay `.git`-free or the outer repo records it as a gitlink | — | **ABSENT** · SNAPSHOT-ONLY — the rule was carried only by `docs/MARC_CAESAR_STATUS.md:51-52`, deleted in `07d5d77`; no current doc restates the gitlink constraint |
| Hermes identity lives at `/opt/data/SOUL.md`, with the shared snippet baked into the image at `/opt/comm/PERSONA-SNIPPET.md` | `factories/sudo-agent/bin/mcp_entrypoint.sh:95`; `docs/SPEC.md:183` → `:196` | VERIFIED · SNAPSHOT-ONLY |
| Letta identity lives at `<memfs>/system/persona.md`, with the snippet persisted to `/home/node/.letta/fleet-comm-snippet.md` by `up.sh` | `factories/sudo-letta/bin/mcp_entrypoint.sh:50-57`; `docs/SPEC.md:184` → `:197` | VERIFIED · SNAPSHOT-ONLY |
| The fleet-awareness block sits between fixed BEGIN/END markers and is replaced in place on every boot, inserting if absent | `factories/sudo-agent/bin/mcp_entrypoint.sh:80-81`; `factories/sudo-letta/bin/mcp_entrypoint.sh:35-36`; `docs/SPEC.md:181-186` → `:194-199` | VERIFIED · SNAPSHOT-ONLY |
| Nothing outside the markers is touched | `docs/SPEC.md:186` → `:199`; `factories/sudo-agent/bin/mcp_entrypoint.sh:87-92` (awk replace-in-place) | VERIFIED · SNAPSHOT-ONLY |
| Skills are seeded on the FIRST boot only (the agent may edit them); the persona block is re-applied every boot | `factories/sudo-agent/comm/README.md:44-47`; `docs/SPEC.md:186` → `:199` | VERIFIED · SNAPSHOT-ONLY |
| On a fresh no-glimor pod `SOUL.md` does not exist yet, so a background watcher applies the block when the gateway creates it | `factories/sudo-agent/bin/mcp_entrypoint.sh:129-148` | VERIFIED |
| Identity seeding is skip-once: the initContainer skips via a `.glimor-seeded` marker on restart | `docs/ARCHITECTURE.md:48`, `:268` | VERIFIED |
| Both identity files matter — `human.md` carries the counterpart pointer, so renaming only `persona.md` regresses the live answer | `docs/ARCHITECTURE.md:36`, `:59-60` | INFERRED · SNAPSHOT-ONLY — `human.md` is named as part of the identity shape, but the counterpart-pointer consequence is no longer stated in the tree (its receipt, `docs/MARC_CAESAR_STATUS.md:53-54`, was deleted in `07d5d77`) |

## 7. Secrets

Variable names only; no values appear in this appendix.

| CLAIM | VERIFIED WHERE | STATUS |
|---|---|---|
| Letta injects `API_KEY` and `LETTA_API_KEY` via `secretKeyRef` to Secret `<deploy>-api-key`, key `api-key` | `factories/sudo-letta/bin/up.sh:177-186` | VERIFIED |
| Letta injects `HCLOUD_TOKEN` via the same Secret, guarded so an absent token omits both the env var and the Secret key | `factories/sudo-letta/bin/up.sh:256-266`, `268-273`, `331-333` | VERIFIED |
| Letta inlines `LLM_PROVIDER`, `LLM_BASE_URL`, `LETTA_MODEL` and the optional web-search keys as literal values | `factories/sudo-letta/bin/up.sh:175-201` | VERIFIED |
| Hermes injects `DEEPSEEK_API_KEY` (key `deepseek-api-key`) and `LLM_API_KEY` (key `llm-api-key`) via `secretKeyRef` to `<deploy>-api-key` | `factories/sudo-agent/bin/up.sh:938-950` | VERIFIED |
| Hermes injects `API_SERVER_KEY` via `secretKeyRef` to the separate Secret `<deploy>-api-server-key` | `factories/sudo-agent/bin/up.sh:956-960` | VERIFIED |
| Hermes inlines `API_SERVER_HOST`, `API_SERVER_PORT`, `HERMES_YOLO_MODE`, `MCP_PORT`, `AGENT_NAME`, `REDIS_URL` as literal values | `factories/sudo-agent/bin/up.sh:961-975` | VERIFIED |
| `SUDO_PASSWORD` is a literal value written into the Deployment env, not a `secretKeyRef` | `factories/sudo-agent/bin/up.sh:965-966` | VERIFIED — worth keeping visible in the docs: the only credential not behind a Secret on that side |
| The agent shell password is generated as 16 random alphanumerics on first deploy and persisted to the factory env file | `factories/sudo-agent/bin/up.sh:418-427` | VERIFIED |
| `setup.sh` refuses to proceed if the supplied key equals a hardcoded known trial key | `setup.sh:175-196` (repo root) | VERIFIED — value deliberately not reproduced here |
| The repo is public, so committed glimors are scrubbed of secrets, hostnames and personal names | `README.md:164-173`; `SOURCE-OF-TRUTH.md:48-50` | VERIFIED · SNAPSHOT-ONLY — the public-repo warning in README plus the scrubbing rule in SOURCE-OF-TRUTH (the original `docs/MARC_CAESAR_STATUS.md:26-29` receipt was deleted in `07d5d77`) |
| The fleet `.env` and each factory's `.env` / `deployments/` are gitignored, so generated manifests and keys stay untracked | `.gitignore:1`, `:23-28` | VERIFIED |
| The repo-root `.gitignore` exists and covers the fleet `.env` | `.gitignore:1` | VERIFIED — the root `.gitignore` is tracked at the tip and line 1 is `.env`; the earlier ABSENT verdict described the handed-over copy (see the merge note in OPEN) |

## 8. Known-defect claims

`FACTS.md` was not present, so its D1–D6 could not be enumerated. The defect
claims the available material *does* make are listed below under the numbering the
source files use. Rows are the claim as written, with its evidence.

| CLAIM | VERIFIED WHERE | STATUS |
|---|---|---|
| KI-1: the load-skill-first gate guarantees "loaded at least once this conversation", not "still in context", so a compacted agent can call from a half-remembered invocation | `docs/KNOWN-ISSUES.md:5-15` | VERIFIED (known, unresolved) |
| KI-2: Hermes comm tools are CLI-only, so the gate's BLOCKED path is unreachable by prompt; the Letta side is symmetric because its tools are native mod tools | `docs/KNOWN-ISSUES.md:17-27` | VERIFIED (known, unresolved) |
| KI-3: Hermes pods running `hermes` without the docker group was resolved by arming the socket gid before the first privilege drop | `docs/KNOWN-ISSUES.md:29-33`, `49-58` | VERIFIED (resolved) |
| KI-3 residual: the watch sidecar overrides the image entrypoint and does not carry the docker gid, so anything docker-ish added there must arm it itself | `docs/KNOWN-ISSUES.md:60-64` | VERIFIED |
| PC-1: the remote control-plane host was unreachable from the build host, so every check against it is unverified | `docs/KNOWN-ISSUES.md:71-79` | VERIFIED as a claim; the underlying reachability is UNVERIFIED (not re-tested here) |
| PC-2: the heartbeat floor in the running image is 10s, not the 1s the docs describe; a redeploy resets it | `docs/KNOWN-ISSUES.md:81-92` | VERIFIED (known, unresolved) |
| PC-3: an unattended re-bootstrap would fail because the invite was consumed; the script branches to a sign-in instead | `docs/KNOWN-ISSUES.md:94-102` | VERIFIED (resolved by design) |
| PC-4: the advertised reverse-proxy auth layer is absent from the local image | `docs/KNOWN-ISSUES.md:104-113` | VERIFIED as a claim; partially UNVERIFIED (its host was unreachable) |
| PC-5: a NodePort exposes the control plane with no TLS and no edge auth; API routes rely on the app's own auth only | `docs/KNOWN-ISSUES.md:115-124` | VERIFIED as a claim (endpoint values not reproduced here) |
| PC-6: the health endpoint reports the database backup as missing | `docs/KNOWN-ISSUES.md:126-133` | VERIFIED as a claim |
| Defect narrative in the ports section: an agent whose hash landed in the NodePort range failed every heartbeat while neighbours worked | `factories/sudo-letta/bin/up.sh:48-53`; `docs/PAPERCLIP.md:99-107` | VERIFIED (recorded as the reason for the 22000 window) |
| Defect narrative in the queue section: pointing the queue at the Redis Service name silently never resolved | `factories/sudo-agent/bin/redis-up.sh:13-19`; `factories/sudo-agent/DESIGN.md:64-72` | VERIFIED (recorded as the reason for the loopback topology) |

## 9. OPEN

Stated as open, not guessed.

> **Merge note (lead, 2026-10-27).** Two rows above were resolved after this
> appendix was written, by reading the live checkout directly rather than the
> handed-over copy. Everything else in the OPEN table stands as written — those
> claims are genuinely unverified here and should not be asserted until someone
> reads the code path or the running pod.


| CLAIM | VERIFIED WHERE | STATUS |
|---|---|---|
| The content of `FACTS.md`, and therefore the identity of its D1–D6 defects | RESOLVED by the lead at merge time: `FACTS.md` was written concurrently and is now present in the work directory; D1–D6 were each re-verified by the lead against the live checkout and the cluster. Section 8 is correct as written. | VERIFIED (lead) |
| The existence and content of `PAPERCLIP-INTEGRATION-STATUS.md` | absent; `docs/PAPERCLIP.md` is the nearest equivalent and was read instead | UNVERIFIED |
| Whether the repo-root `.gitignore` and root `down.sh` exist in the real repo | RESOLVED by the lead at merge time: both exist and are tracked in the live checkout. The handed-over copy omitted them. | VERIFIED (lead) |
| The numeric uid of the Letta watch sidecar | `factories/sudo-letta/bin/up.sh:419-431` sets none; the image's `USER` was not read | UNVERIFIED — stated as INFERRED above, needs one Dockerfile read |
| Whether Letta's startup fail-fast ping on Redis exists as the design doc describes | `factories/sudo-letta/DESIGN.md:150-154` | UNVERIFIED — code path not read |
| Whether the per-conversation gate gap (KI-1) has since been fixed; the doc still records it as open | `docs/KNOWN-ISSUES.md:5-15` | UNVERIFIED — no test run, doc treated as current |
| Whether the Paperclip 10s heartbeat floor (PC-2) is still 10s in the running image | `docs/KNOWN-ISSUES.md:81-92` | UNVERIFIED — requires a live cluster read, out of scope for a documentation intake |
| Whether the remote control-plane findings (PC-1, PC-4) still hold | `docs/KNOWN-ISSUES.md:71-79`, `104-113` | UNVERIFIED — their host was unreachable when the findings were written |
| The live cluster's actual port assignments for any named agent | derivations only: `factories/sudo-letta/bin/up.sh:57`, `63`; `factories/sudo-agent/bin/api_server_ports.py:85-89` | UNVERIFIED — no cluster read performed; the formulas are verified, the deployed values are not |
| The count of agents/PVCs in the fleet (~94 agents cited, 42 PVCs cited during a backup) | `docs/SPEC.md:218-220` → `:233-235`; `docs/IMPROVEMENTS.md:84`; `factories/sudo-agent/bin/api_server_ports.py:31` | UNVERIFIED · SNAPSHOT-ONLY — historical point-in-time figures, not re-measured; the two numbers come from IMPROVEMENTS (`:84`, 42 PVCs) and `api_server_ports.py` (`:31`, ~94 agents), and SPEC's Session log section no longer names a tracked log file |
| Which of the four web-search provider keys an agent actually has configured | `factories/sudo-letta/bin/up.sh:122-126` | UNVERIFIED — runtime state, deliberately never logged |
