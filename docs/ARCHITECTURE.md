# sudo-fleet — Architecture As Built

Describes the system the repository actually emits, so a maintainer who has never seen it can reason about
behaviour and failure. Derived from `factories/sudo-letta/bin/up.sh`, `factories/sudo-agent/bin/up.sh`,
`bin/k8s-up.sh`, `bin/k8s-auto-up.sh`, `setup.sh`, the two `DESIGN.md` files and the two `watch_sidecar.py`
files. No live cluster was consulted: every statement below is a property of the code.

## 1. What the repository installs, and the two commands

One disposable "room" on a single Linux box: Docker and single-node k3s; two locally-built images
(`sudo-agent:latest`, built on `hermes-agent:latest`, and `sudo-letta:latest`); a per-agent Kubernetes surface
(Secret, PVC, Deployment with two containers, one or two Services, one to three ConfigMaps) generated into
`factories/<factory>/deployments/<name>.yaml` by each factory's `up.sh`; one shared queue-Redis Deployment per
factory; an optional Paperclip control plane; and a systemd oneshot unit that brings it all back after a reboot.
Agent state lives on per-agent PVCs; nothing agent-specific is baked into an image except the MCP server, the
observer daemon and the comm plugins.

**Command 1 — bootstrap** (`setup.sh`). Prompts for exactly three values, writes `$FLEET_HOME/.env` (mode 600,
gitignored), derives the rest (`DEEPSEEK_API_KEY`, `API_KEY`, `LLM_PROVIDER`), installs Docker and k3s, enables
`docker.service` and `k3s.service`, builds both factory images non-interactively, and installs and enables
`sudo-fleet-boot.service` → `bin/k8s-auto-up.sh`.

**Command 2 — stand the fleet up** (`bin/k8s-up.sh`). Checks the kubeconfig, waits for the node Ready, sources
`.env`, re-seeds the two factory `.env` files (`sudo` strips the caller's exported environment), deploys Marc
(Letta planner) and Caesar (Hermes engineer) through each factory's `up.sh --from-glimor`, waits for both pods
Ready, verifies both PVCs and four Services, then brings up Paperclip and auto-hires.

**The identity tree — `deployments/`.** `bin/k8s-up.sh` sets `GLIMORS_DIR="$FLEET_HOME/deployments"`; that
directory is the seed source for `--from-glimor`. It is tracked, and it currently holds two packages,
`deployments/ONalwase/` and `deployments/Talker/`, both `kind: letta`. A package of this shape is a directory
carrying `kind`, `name`, `meta.yaml`, `allowlist.txt`, an agent-kind directory (`letta/` or `hermes/`), and — on
the Letta side — an agent record plus a committed MemFS `memory/` with `system/persona.md` and
`system/human.md`. Those are live agent identities, committed to the factory repository.

That is the second thing this tree is. `SOURCE-OF-TRUTH.md` says workload content (personas, memory, the work
itself) belongs in a separate product repository and that this repo owns only how agents are deployed. Both
statements are visible to a reader at once. The tension is real, it is not resolved here, and the doc set
records it as a known issue (D5 in [`KNOWN-ISSUES.md`](KNOWN-ISSUES.md)) rather than resolving it by deleting
committed identities.

> **NOTE — Command 2 currently cannot complete (D1).** `k8s-up.sh` seeds Marc from `$GLIMORS_DIR/Marc` and
> Caesar from `$GLIMORS_DIR/Caesar`. `deployments/` exists, but it holds only `ONalwase/` and `Talker/` — both
> Letta. Commit `98caf2b` ("chore: remove marc and caesar deployments (replaced by the AO talker agent)")
> deleted `deployments/Marc/` and `deployments/Caesar/`, so both paths `k8s-up.sh` names are dangling. The seed
> source the README documents as tracked is gone.
>
> Intended mechanism: each factory validates the glimor before emitting anything (`letta/settings.json` for
> Letta, `hermes/SOUL.md` for Hermes) and, when valid, emits an `initContainer seed-glimor` that copies the
> glimor into the PVC before the agent process starts, guarded by a `.glimor-seeded` marker so a restart
> preserves the fork's runtime changes. A missing or invalid glimor fails that initContainer and the deploy
> aborts loudly — the intent is "never a blank agent".
>
> Actual behaviour on a fresh clone: the path test fails, `up.sh` prints `✗ --from-glimor …: missing letta/ or
> letta/settings.json` (Hermes: `missing hermes/ or hermes/SOUL.md`) and exits 1 **before** it writes a manifest
> or calls `kubectl apply`. `k8s-up.sh` wraps the call in `_retry 3` — three attempts, 1 s and 2 s backoff —
> then dies at step 3/4 with "sudo-letta up.sh --marc --from-glimor failed". No Deployment, PVC or Service is
> created for Marc; Caesar is never reached; the PVC/Service verification and the Paperclip step never run.
> Command 1 is unaffected — the cluster and images exist, the seeded identities do not. `k8s-auto-up.sh` re-runs
> the same script on every boot, so the failure repeats on a schedule nobody is watching.

## 2. The two factories and the two agent kinds

| | `factories/sudo-agent` | `factories/sudo-letta` |
|---|---|---|
| Harness | Hermes Agent | Letta Code (pinned `0.33.2`) |
| Invocation | `hermes -z`, one-shot, **stateless per invocation** | `letta` CLI, **resumes** the conversation |
| MCP tool | `hermes_prompt(prompt, json, mode, source)` | `letta_prompt(prompt, stream, json, new_chat, mode, source)` |
| Durable state | PVC `/opt/data` (SOUL.md, `config.yaml`, `state.db`, memory, skills) | PVC `/home/node/.letta` (settings, agent records, MemFS) |
| Memory | files injected at session start | MemFS, a git-backed memory filesystem |
| Agent port | `MCP_PORT` 8000..29999 | `MCP_PORT` 8000..29999 |
| Extra | `API_SERVER_PORT` 61000..65535 | `WATCH_PORT` only |
| Services | `-mcp`, `-watch`, `-api` | `-mcp`, `-watch` |

**Hermes is stateless per invocation.** Each prompt is a fresh `hermes -z` process; there is no conversation to
resume, and `--stream` / `--new-chat` are CLI-parity no-ops at the MCP door. Identity therefore lives entirely
in files on the PVC — the agent's continuity is the filesystem, not the process. Queued prompts cannot corrupt
one another, but nothing carries context forward either, and a lost prompt leaves no trace.

**Letta is stateful.** `letta` resumes the agent record and conversation named in `settings.json` /
`settings.local.json`, and its memory is a git-tracked filesystem under `lc-local-backend/memfs/*/memory`.
**Only committed memory loads.** A write not committed before the next read is silently absent — not stale,
absent — which is why every factory-side seed and the fleet-comm write end with a `git add -A` + `git commit`.
The sharper failure is the mirror: an agent that edits memory without committing appears to have forgotten the
edit on the next boot, with no error anywhere, while the bytes stay on the PVC.

## 3. Per-agent shape as emitted

```
Deployment sudo-<name>  (replicas 1, strategy Recreate, hostNetwork true, shareProcessNamespace true)
├─ container sudo-agent | sudo-letta   privileged: true
│    tcpSocket :MCP_PORT   startup 5s×30   readiness 5s×3   liveness 20s×3
├─ container watch   unprivileged (Hermes runAsUser 10000 + runAsNonRoot; Letta image USER node)
│    httpGet /healthz :WATCH_PORT   startup 3s×10   readiness 5s×3   liveness 15s×3
├─ volumes  data          PVC <deploy>-data (10Gi, ReadWriteOnce)
│           docker-sock   hostPath /var/run/docker.sock (type: Socket)
│           watch-config  ConfigMap <deploy>-watch-config
│           config        hostPath config/<name>.yaml (Hermes only, type: File)
│           seed          hostPath <glimor dir>  (only when seeding)
│           watch-plugin, comm-gate-plugin  ConfigMaps (Hermes only)
└─ Services <deploy>-mcp   ClusterIP 8000 → MCP_PORT
            <deploy>-watch ClusterIP 8000 → WATCH_PORT
            <deploy>-api   ClusterIP 8000 → API_SERVER_PORT (Hermes only)
```

`strategy: Recreate` is not a preference. Under `hostNetwork` the pod binds a fixed per-agent port in the
**node's** namespace and, on Hermes, takes `/opt/data/gateway.lock` on the PVC. A `RollingUpdate` would start
the new pod beside the old one, which can neither bind the port nor take the lock, and the rollout would hang
with a crash-looping pod. Each roll is therefore a hard gap with no overlap. Per agent the file emits one or two
Secrets (`<deploy>-api-key`, and `<deploy>-api-server-key` on Hermes), one PVC, one Deployment, one or two
Services and one to three ConfigMaps.

`hostNetwork: true` has three consequences the rest of this document depends on: every listener is a
**node-global** port; `127.0.0.1` in a pod is the **node's** loopback; and with the default `ClusterFirst`
dnsPolicy the pod gets the **node's resolver, not cluster DNS**, so a Service *name* does not resolve inside an
agent pod — a Service is reachable by ClusterIP only. Hermes emits `dnsPolicy: ClusterFirstWithHostNet` **only**
when `PERSONA_NAME` is set, so a generic Hermes agent and every Letta agent have no cluster DNS. The agent
container is privileged with the Docker socket mounted and the watch sidecar is not, so the boundary between
agents is the container runtime, not a security domain.

## 4. The port scheme, and why it is derived from the name

Each pod joins the node's network namespace, so a port is a **node-global** resource: two agents cannot share
one, and a fixed port would allow exactly one agent per node. Uniqueness must come from the only thing already
unique per agent — its name. Both factories compute the two service ports identically:

```
MCP_PORT   = 8000 + ( cksum(name)           % 22000 )    # 8000..29999
WATCH_PORT = 8000 + ( cksum("<name>-watch") % 22000 )    # 8000..29999
if WATCH_PORT == MCP_PORT: WATCH_PORT = MCP_PORT + 1      # collision guard
```

Hashing `<name>-watch` keeps the sidecar off the agent's port; the `+1` bump covers both hashes landing
together. The Hermes `api_server` port is **not** derived here: `bin/api_server_ports.py` maps the name with
SHA-256 into `PORT_BASE = 61000`, `PORT_COUNT = 4536` (61000..65535), writes it into `platforms.api_server.port`
in `config/<name>.yaml` with a surgical text edit (comments preserved, result re-parsed with a real YAML
parser), and returns it so config, `API_SERVER_PORT` and the `-api` Service always agree. Collisions are
resolved by linear probing the ring in sorted-name order and the result is written to the file, so a sweep is
idempotent; `guard` fails a deploy when a config resolves to `8642` or duplicates another config's port.

| Range | Owner | Consequence for a hostNetwork listener |
|---|---|---|
| 8000..29999 | `MCP_PORT`, `WATCH_PORT` | the working window |
| 30000..32767 | k3s NodePort range | **silently unreachable from other pods**: kube-proxy's KUBE-NODEPORTS handling intercepts and drops the packet, so clients time out |
| 32768..60999 | Linux ephemeral (`ip_local_port_range`) | outbound connections can already hold the port |
| 40000..59999 | Hermes offline-fallback Redis (`40000 + MCP_PORT*7 % 20000`) | must not also be an agent port |
| 61000..65535 | Hermes `api_server` | above all of the above by construction |

Failure modes. `cksum` is a 32-bit CRC over the name, so two names can land on one of 22000 slots, and **nothing
detects a cross-agent MCP/WATCH port collision** — the second pod starts, fails to bind, and crash-loops,
permanently, because the collision is a function of the name. The `api_server` block is separate because it does
resolve collisions and has a guard. Because ports derive from the name, a rename moves every port of that agent,
breaking anything that pinned a node port instead of a Service.

## 5. The prompt distributor

Every pod's MCP door is fronted by a Redis-backed queue with exactly **one** drain worker. The reason is state,
not throughput: an agent is one mutable thing — one gateway holding a host lock (Hermes), one resumable
conversation over one git-backed memory tree (Letta). Concurrent prompts would be processes racing that state,
so N rapid prompts must become N *queued* runs.

| | Hermes | Letta |
|---|---|---|
| Redis | `sudo-agent-redis`, node loopback `127.0.0.1:6380` | `sudo-letta-redis`, node loopback `127.0.0.1:6379` |
| Durability | PVC `sudo-agent-redis-data`, AOF `appendfsync everysec`, `Recreate` | `--save "" --appendonly no`, no PVC |
| Namespace | `sudo-agent:q:<agent>:items / :inflight / :res:<id>` | `QUEUE_NAME` from the agent's pod/port |
| Claim | `WATCH`/`MULTI`: `lrem` from `:items` + `rpush` to `:inflight`, one transaction | `lrange` → pick → run → `lrem` after the result is stored |

Both bind the node loopback on purpose: a hostNetwork pod cannot resolve a Service name, so a Service-name URL
never resolved and the queue silently fell through to a per-pod fallback. `127.0.0.1` in any agent pod *is* the
node.

**Ordering rule, verbatim from both factories:**

```
a. first message in = processed first
b. then drain ALL remaining messages from that same source before anyone else
c. when empty, move to the NEXT MOST RECENT source and drain it fully
d. FIFO within a source
```

A *source* is the MCP client/session that enqueued. The first client is served to exhaustion, then the most
recently active remaining client, then everyone else. `mode="direct"` enqueues and waits for the reply with no
timeout; `mode="inbox"` returns a `msg-<12hex>` id and the result is read back later from a record kept with a
7-day TTL. What a queued run *means* differs by kind: a Hermes run is a fresh process whose only memory of the
previous run is what the PVC carries, while a Letta run resumes the same conversation, so two queued messages
are two turns of one dialogue.

Failure modes. The claims are not equally strong. Hermes' `WATCH`/`MULTI` pair guarantees exactly one worker
holds an item, and anything abandoned in `:inflight` is moved back to the front of `:items` on the worker's next
connect (at-least-once). The Letta worker takes an item from `lrange`, runs it, and removes it only afterwards,
so exclusivity rests on one worker thread in one replica; a crash mid-run re-runs the prompt. The Letta Redis
keeps nothing on disk, so a restart drops everything still pending. If Redis is unreachable the MCP server fails
loudly rather than spawning the CLI directly — there is intentionally no bypass path.

## 6. The observability sidecar

The second container only ever reads. Three jobs: watch processes through the shared PID namespace
(`shareProcessNamespace: true`; PID 1 is the pause container, excluded), capture the conversation, serve an HTTP
tap.

| | Hermes | Letta |
|---|---|---|
| Capture source | `/opt/data/state.db` (completed rows only) **plus** the `sudo-watch-stream` plugin's `stream.jsonl` | `lc-local-backend/conversations/*/messages.jsonl`, byte-offset watermarks in `state.json` |
| Writes | `<PVC>/watch/events.jsonl`, `transcript.txt`, `stream.jsonl` | `<PVC>/watch/events.jsonl`, `transcript.txt` |
| Trigger | DB poll (2 s) + plugin hooks (per token) | file tail (2 s) |

The Hermes split matters: Hermes writes a `messages` row only when a message is *complete*, so a DB-only
observer cannot show a turn while it streams. The plugin registers on the native hooks
(`on_stream_start/delta/end`, `pre/post_api_request`, `pre/post_tool_call`) and writes the whole runtime —
per-token `delta` chunks, the sanitised request body, full tool arguments and results. After `kubectl apply`,
`up.sh` asks Hermes' own plugin manager how many callbacks are registered for all seven hooks; any zero aborts
the deploy.

**Event schema** — one JSON object per line in `events.jsonl`, common keys `{"ts": <epoch>, "conversation":
<id>, "event": <type>}`. Types: `user` {text, reminder}, `thinking` {text}, `assistant` {text}, `tool_call`
{name, args}, `tool_result` {text, truncated, full_bytes}, `session` {id, cwd}, `process_state` {state,
processes}. Hermes' `stream.jsonl` carries the finer runtime tape alongside it: `turn_start`, `input_context`,
`delta` {kind: text|reasoning}, `activity`, `tool_call`, `tool_result`, `log`, `completion` and `stream_end`,
the last marked `synthesized: true` with `delta_count: 0` when a turn never streamed.

**HTTP routes** (stdlib `http.server`, `Connection: close`, unframed bytes, one write+flush per event):

```
GET /healthz        -> 200           (also the sidecar's probe target)
GET /status         -> JSON snapshot (uptime, agent_container_up, active, events_logged,
                        last_event_ts, watch_port, stream stats)
GET /ps             -> JSON list of non-self processes
GET /events?n=N     -> last N event lines, verbatim JSONL
GET /stream         -> live tail
GET /events-stream  -> backlog + live tail of NEW events (Hermes; the preserved original /stream)
```

The sidecar mounts the **same PVC** as the agent, which is what makes the tape travel with the agent: recreate
the pod, or move the claim, and the history is there. The corollary is that `events.jsonl` holds full prompts,
reasoning and tool results, so the PVC is the sensitive object in the system. `transcript.txt` is the narrower
artifact: real prompts and replies only, no backfill, starting at deploy time.

Failure modes. History cannot be invented: no backfill, so a pod created today has an empty tape for yesterday,
and a shrunk or rotated source file resets its watermark. The Hermes plugin's writer is bounded (20000) and
drops the oldest rather than blocking the agent, so bursts are lossy by design. `/stream` replies 404 until the
plugin has written a turn — an empty 200 would be indistinguishable from a dead agent.

## 7. The secrets path

Two carriers, and the split is not uniform across the factories.

| Factory | Value | Carrier |
|---|---|---|
| Hermes | `DEEPSEEK_API_KEY`, `LLM_API_KEY` | `secretKeyRef` → Secret `<deploy>-api-key` |
| Hermes | `API_SERVER_KEY` | `secretKeyRef` → Secret `<deploy>-api-server-key` |
| Hermes | `SUDO_PASSWORD`, `HERMES_YOLO_MODE`, `API_SERVER_HOST`, `API_SERVER_PORT`, `MCP_PORT`, `AGENT_NAME`, `REDIS_URL` | **literal `value:` in the Deployment** |
| Letta | `API_KEY`, `LETTA_API_KEY` | `secretKeyRef` → Secret `<deploy>-api-key` |
| Letta | `HCLOUD_TOKEN` | `secretKeyRef`, key `hcloud-token`; omitted entirely when unset |
| Letta | `LLM_PROVIDER`, `LLM_BASE_URL`, `LETTA_MODEL`, `EXA_`/`TAVILY_`/`PARALLEL_`/`PERPLEXITY_API_KEY` (when set), `DICTATION_*` (when set, single-quoted), `USER`, `HOME`, `LETTA_HOME`, `MCP_PORT` | **literal `value:` in the Deployment** |

Values come from the fleet `.env` (mode 600, gitignored); the generated manifest lands in
`factories/<factory>/deployments/<name>.yaml` (also gitignored). No secret is committed, no value is reproduced
here.

The difference between the carriers is narrower than it looks: a `secretKeyRef` keeps the value out of the
Deployment spec and out of `kubectl get deploy -o yaml`; it does **not** hide it from anyone who can read
Secrets in the namespace. A literal is visible to anyone who can read the Deployment, and `SUDO_PASSWORD` —
root-equivalent inside the container — travels as a literal, so the Deployment object is itself sensitive. A
`secretKeyRef` resolves only when a pod is created, so editing `.env` alone leaves the running pod on the old
value. An unset optional token omits the variable rather than emitting an empty one, so the agent fails on its
own check instead of using a blank credential.

## 8. The identity path, per kind

**Letta.** A glimor is a directory containing `letta/`; `up.sh` validates `letta/settings.json` and emits
`initContainer seed-glimor`, which copies `/seed/letta/.` into `/home/node/.letta`, rewrites `settings.json` and
`settings.local.json` so the resume target is the seeded pinned/`memfs` agent record and conversation `default`,
then runs `git init -b main` + `git add -A` + `git commit` **inside the MemFS memory directory**, and chowns to
1000. A `.glimor-seeded` marker makes it idempotent, so a restart preserves the fork's runtime changes. Identity
is three things on one PVC: the settings naming the agent, the agent record, the committed memory tree. The two
packages committed under `deployments/` (§1) are this shape, which is why they are identities and not templates.

**Hermes.** Identity is `/opt/data` on the PVC: `SOUL.md`, the per-agent `config.yaml` (a `hostPath` file, not
the PVC), `state.db`, memory files, skills. A glimor contains `hermes/` and must carry `hermes/SOUL.md`; when
one is given it owns the whole seed and the repo SOUL seed is **not** emitted, because exactly one initContainer
may ever write `SOUL.md`. Without a glimor, a tracked `config/<name>.SOUL.md` is seeded, but only when
`/opt/data/SOUL.md` is absent or still byte-identical to the stock template (md5 `1aec3b72…`), so a diverged
agent is never overwritten. Comm skills are seeded once behind `/opt/data/.comm-seeded`.

**The fleet-comm block.** Both kinds carry the shared comm awareness as a factory-managed block bounded by `<!--
FLEET-COMM-AWARENESS-BEGIN -->` and `<!-- FLEET-COMM-AWARENESS-END -->`. One source,
`factories/sudo-agent/comm/PERSONA-SNIPPET.md`, byte-identical for both factories. Every boot the harness
replaces everything **between** the markers in place, or appends the block when either marker is missing, and
touches nothing outside them — so hand-written content after `END` survives every redeploy, while anything put
*inside* the block is overwritten. On Hermes this runs in `mcp_entrypoint.sh` against `/opt/data/SOUL.md`. On
Letta, `up.sh` copies the snippet into the pod, persists it there so a plain restart can re-apply it, writes the
block into `<memfs>/system/persona.md`, and commits the MemFS — an uncommitted write would not load.

Failure modes. A missing snippet is fatal on the Letta path (deploy aborts) and a silent no-op on the Hermes
path (`_apply_fleet_block` returns when either file is absent), so the same fault fails differently per factory.
If the markers are deleted the block is appended rather than replaced, and repeated deletion accumulates copies.
On Letta an agent with no MemFS yet is a warning: the block lands on the next deploy.

## 9. End-to-end lifecycle of one agent

1. **Create.** `bash bin/up.sh --<name>`; `--from-glimor <dir>` and `--persona <slug>` are optional. Credentials
   come from `.env`, which `k8s-up.sh` re-seeds first because `sudo` strips the exported environment.
2. **Seed config.** Hermes copies the tracked `config.yaml` to `config/<name>.yaml` on first deploy and then
   leaves it alone, so agents diverge; the `api_server` port is assigned into that file and provider, base URL
   and model are converged from `.env`. Letta keeps credentials in `.sudo-letta/.env`.
3. **Derive ports** — `MCP_PORT` and `WATCH_PORT` from `cksum`; Hermes also `API_SERVER_PORT` from
   `api_server_ports.py`.
4. **Write the manifest** to `factories/<factory>/deployments/<name>.yaml`: one gitignored file per agent, and
   the artifact later re-applied.
5. **Import images.** They exist only in the local Docker daemon and the k3s containerd store; there is no
   registry. `up.sh` imports them (`docker save | k3s ctr image import -`, `ctr` fallback, retries) and treats
   an image still absent from containerd as **fatal** — the pods pin `:latest` with `IfNotPresent`, so a silent
   import failure becomes `ImagePullBackOff`.
6. **Apply.** `kubectl apply -f <yaml> --validate=false`, failing loudly. Hermes stamps content digests into the
   pod annotations (`watch-scripts-sha`, `image-sha`), because a same-tag image rebuild or a ConfigMap edit does
   not otherwise roll a pod.
7. **Wait, and prove.** Hermes waits on `kubectl rollout status` (300 s default), then probes the stream and
   comm-gate hooks in-pod and aborts on any zero. Letta waits on the pod for 60 s and `|| true`, then runs its
   post-Ready configuration (provider connect, model pin, mods, skills, fleet-comm) by `kubectl exec` — a pod
   that never becomes Ready still exits 0 and is reported deployed.
8. **Seed identity** — glimor or SOUL initContainer before the agent starts, then the fleet-comm block per §8.
9. **Hire.** Both factories call `bin/paperclip-hire.sh` when the control plane is installed; non-fatal, and
   `bin/paperclip-adopt.sh` reconciles later.
10. **Reach.** `http://<deploy>-mcp:8000/mcp`, `-watch:8000/status` for in-cluster clients; agent pods must use
    the per-agent node port directly, having no cluster DNS. From here liveness restarts a hung listener and
    readiness keeps a not-yet-serving pod out of Service rotation.
11. **Recover on boot.** `sudo-fleet-boot.service` → `bin/k8s-auto-up.sh`: wait for k3s Ready (up to ~10 min,
    warning rather than failing), re-import any missing image, re-run `k8s-up.sh`, write a proof file under
    `durable-boot-proof/`. Every step degrades to a warning, so a broken fleet still reports a clean boot.
12. **Stop.** `bin/down.sh --<name>` leaves the PVC, and re-running `up.sh` reattaches to it — a deleted agent
    can be revived, a deleted PVC cannot.

## 10. Load-bearing assumptions

- **Docker socket reachable from the agent container.** Both factories mount `/var/run/docker.sock` (Letta also
  grants the socket's group id via `supplementalGroups`, read off the host at deploy time). Without it the comm
  host bridge and container work inside the agent fail; the gid is per node, so a hardcoded value would break
  silently elsewhere.
- **k3s and the agents on one host.** Services, PVCs, `hostNetwork` and the loopback Redis all assume a single
  node; a second node breaks the queue path and the port arithmetic.
- **Ports are node-global and finite.** Every listener is a function of the name in a fixed window; collisions
  have no detection path, and the NodePort range silently swallows a listener placed inside it.
- **Letta memory must be git-committed to load.** Every seed path commits; a write that is never committed
  yields an agent that appears to forget.
- **One drain worker per pod, one replica per agent.** The Letta claim is not atomic, so a second worker would
  double-run prompts; `replicas: 1` is part of the queue's correctness.
- **One Redis per factory on node loopback.** 6379 and 6380 are node-global; a second process on either is a
  hard failure, and the Hermes fleet is the one that would move if they merged.
- **Images come from the local containerd store.** No registry, no pull-through: losing the store means
  `ImagePullBackOff` until `setup.sh` or the boot unit re-imports.
- **The Hermes per-agent config is a `hostPath` file outside the PVC.** If it is missing the pod stalls in
  `CreateContainerConfigError`; if it points at a frozen upstream tree, the running agent disagrees with the
  repo the operator fixed.
- **The PVC is the security boundary for history.** `events.jsonl` is a full transcript of prompts, reasoning
  and tool results.
- **`setup.sh` is idempotent, not a repair tool.** It enables units and builds images; it does not reconcile a
  running cluster, and `k8s-auto-up.sh` assumes `kubectl`, `docker`, `ctr` and `/etc/rancher/k3s/k3s.yaml`
  exist, without which it warns and exits 0.
