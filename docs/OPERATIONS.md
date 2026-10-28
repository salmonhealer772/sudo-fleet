# Operating a sudo-fleet instance

Deploy, inspect, debug, recover. An operator manual for a fleet built from this repository, not an
architecture document: it assumes the layout in `docs/ARCHITECTURE.md`.

`<name>` is an agent name without the `sudo-` prefix (the scripts add it). `<ns>` is the workload
namespace — `default` for a stock install, because the repo's scripts never pass `-n`. Every `kubectl`
call needs `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`.

## 1. Prerequisites and what the bootstrap writes outside the repo folder

A bare Linux box (or WSL2 distro, or Lima VM) with systemd, curl, git, `jq` and root or sudo — no docker,
no k3s. `jq` is a real prerequisite, not a nicety: `bin/talk.sh` (§3.1) hard-requires it, and
`bin/verify-change.sh` parses `kubectl` output with it but warns and degrades to grep/unknown without it.
On apt boxes Command 1 installs it (step 2, "Bootstrap: Docker + jq"); on a non-apt box step 2 stops with
the manual install line, so install `jq` first. Command 1 is `git clone <repo-url> && cd sudo-fleet && bash setup.sh`: it prompts
for one LLM API key, an LLM base URL (blank means the provider default) and an optional web-search key;
writes `.env` at the repo root with mode 600; derives the rest; installs docker and k3s; builds both
factory images; installs the boot unit. It deploys no agent.

Everything fleet-related stays inside the repo folder — the factory trees, `.env`, generated
`deployments/<name>.yaml`, `durable-boot-proof/`. What it writes elsewhere is system tooling, and these
are the paths that break when the checkout moves:

| Path | Written by | Why it matters later |
|---|---|---|
| `/usr/bin/docker`, `docker.service`, `containerd.service`, `/var/lib/docker`, `/var/lib/containerd` | docker installer (apt fallback) | the images the pods pin live here and in the k3s store |
| invoking user added to the `docker` group | `setup.sh` | needs a new shell; the group is root-equivalent |
| `/usr/local/bin/k3s` (+ `kubectl`/`crictl`/`ctr` symlinks), `k3s.service`, `/var/lib/rancher/k3s/`, `/var/lib/kubelet` | k3s installer (binary fallback) | the host `kubectl` is a symlink to it; all cluster state and every PVC |
| `/etc/rancher/k3s/k3s.yaml` | k3s, then `chmod 644` by `setup.sh` | cluster-admin credential, readable by every local user by design |
| `sudo-fleet-boot.service` | `setup.sh` | boot-time bring-up — see 5.4 |
| `/etc/wsl.conf` | `setup.sh`, WSL2 only | `[boot] systemd=true`, without which nothing starts |
| `/etc/hosts` | possibly docker or k3s | rare; the repo does not write it |

`setup.sh` enables k3s and docker rather than merely starting them, so the cluster returns after a
reboot with no manual command; on WSL2 it prints the step it cannot do (starting the distro). Two
caveats: the kubeconfig is world-readable — that is what lets the non-root scripts reach the cluster —
so any local account is effectively cluster-admin; and the docker group is root-equivalent, because
agent containers mount the docker socket.

## 2. Deploying an agent

### 2.1 Two commands, and the starter pair

`bash setup.sh`, then `cd bin && bash k8s-up.sh`. The second stands up the starter pair — `planner`
(a Letta planner) and `engineer` (a Hermes engineer), overridable with `PLANNER_NAME` / `ENGINEER_NAME` —
and needs no identity package: each factory call gets `--from-glimor <dir>` only when
`deployments/<Name>/` exists, so a fresh clone deploys two clean agents with no seed. A seed that *is*
named and is missing or invalid aborts that factory's `up.sh` before `kubectl apply`, rather than
producing a half-seeded pod. `bin/k8s-auto-up.sh` re-runs the same script on every boot, so the boot
unit's output is worth reading after the first install. Deploying individual agents through the factory
scripts is the path in 2.2.

### 2.2 The command, per kind

```bash
cd factories/sudo-agent && sudo bash bin/up.sh --alice    # Hermes engineer
cd factories/sudo-letta && sudo bash bin/up.sh --bob      # Letta planner
```

`up.sh` prepends `sudo-` itself: `--alice` produces deployment `sudo-alice`, not `alice`. Derived
objects: Deployment `sudo-<name>`; PVC `sudo-<name>-data`; Service `sudo-<name>-mcp` (port 8000 →
per-agent MCP port); Service `sudo-<name>-watch` (port 8000 → per-agent watch port); Service
`sudo-<name>-api` (Hermes only); manifest `factories/<factory>/deployments/<name>.yaml`.

Labels are always both — `app=sudo-agent` (or `app=sudo-letta`) and `agent=<name>` — and every selector
in the repo uses them. `kubectl get pods -l agent=<name>` finds one agent; `agent=` is unique across
kinds, `app=` is not.

`--from-glimor <dir>` seeds the whole home tree through an initContainer before the process starts (a
missing or invalid directory fails the pod in Init, by design); `--persona <slug>` applies a persona
block, Hermes only. The Hermes `up.sh` provisions the shared queue Redis first and aborts if that
fails: a pod without queue backing accepts prompts and never answers.

### 2.3 What the command prints back

```
→ api_server port <port> assigned to config/<name>.yaml
→ watch scripts digest: <12 hex> · sudo-agent image digest: <12 hex>
→ YAML written: deployments/<name>.yaml
→ Shared queue Redis ready: sudo-agent-redis at redis://127.0.0.1:6380/0
→ Deploying...  <kubectl apply output: created / unchanged>
→ Waiting for sudo-<name> rollout (then proving the stream hooks)...
   sudo-watch-stream hooks: on_stream_start=1 ... pre_tool_call=1
   sudo-comm-gate hooks: on_skill_lifecycle=1
✓ sudo-<name> deployed
  Talk:  kubectl exec -it deploy/sudo-<name> -- hermes
  Watch: http://sudo-<name>-watch:8000/status  (also /ps /events /stream /healthz)
  Stop:  bash bin/down.sh --<name>
```

The two digests are content hashes pinned as pod-template annotations — the mechanism that makes a
same-tag rebuild or a changed sidecar script actually recreate the pod. The two hook probes are the
deploy's proof that the observability and comm-gate plugins registered inside the running process; a
deploy that stops before them did not finish, whatever `apply` said. The Letta deploy has the same
shape with `letta` in the Talk line, plus a `letta connect` and model-set step inside the pod — a
`⚠ Letta connect failed` there is a live model-wiring problem: the pod is up and cannot think.

### 2.4 Why a spec change needs a re-run, not a restart

`up.sh` regenerates the manifest from its own template on every run and applies it; the live Deployment
is replaced, not merged, so `kubectl edit` or `kubectl set env` is drift the next `up.sh` overwrites
(operator-added env vars outside the template's known names are carried forward, the rest are not).

- `kubectl rollout restart` recreates the pod but does not regenerate the spec, so an env, volume,
  hostPath or resource change that exists only in the template is not picked up. Re-run `up.sh`.
- `kubectl apply` alone does not roll a Deployment for a ConfigMap edit or a rebuilt `:latest` image.
  That is why the digest annotations exist.

The strategy is `Recreate`, not RollingUpdate, because each pod is `hostNetwork: true` and binds a
node-global port, and the agent takes a lock on its PVC. The old pod must terminate before the new one
starts, so a change is a brief outage of that agent, not a surge — and a hanging rollout usually means
the new pod is waiting on a port the old one still holds.

## 3. Inspecting a running agent

### 3.1 Talking to it

```bash
bash bin/talk.sh --<name>
```

It finds the deployment in any namespace, decides the kind from the container name (`sudo-agent` or
`sudo-letta`), starts that kind's client, and prints `-> hermes agent sudo-<name> (pod <pod>, ns <ns>)`.
It needs a real terminal: as root on the node it enters the container's namespaces directly, which makes
the TUI behave; otherwise it falls back to `kubectl exec` with size, TERM and locale fixed up. If the
pod is scaled to zero or not Ready it prints the pod list instead of hanging.

### 3.2 A shell, and logs

```bash
bash factories/sudo-agent/bin/ssh.sh --<name>   # kubectl exec -it deploy/sudo-<name> -- bash
bash factories/sudo-letta/bin/ssh.sh --<name>   # drops to sudo -i, env preserved

kubectl logs -n <ns> deploy/sudo-<name> -c sudo-agent -f     # the agent
kubectl logs -n <ns> deploy/sudo-<name> -c sudo-letta -f     # Letta
kubectl logs -n <ns> deploy/sudo-<name> -c watch -f          # the observer
kubectl logs -n <ns> deploy/sudo-<name> -c sudo-agent --previous
```

Two containers per pod, so `kubectl logs` needs `-c`. The Letta shell preserves `LETTA_API_KEY`,
`API_KEY`, `LLM_PROVIDER` and `LETTA_HOME`, because everything useful there needs them. A shell sees
the PVC at `/opt/data` (Hermes) or `/home/node/.letta` (Letta) and does **not** see the repository
checkout — no pod has a path to the repo tree, so anything to be inspected in place must be copied in or
bind-mounted. For a pod that never got past Init: `kubectl logs -n <ns> <pod> -c seed-glimor`.

### 3.3 The watch sidecar and its routes

The `watch` container is an out-of-band observer: it reads the agent's SQLite store and `/proc` in the
shared PID namespace, writes onto the agent's PVC, and serves a small HTTP tap, never touching the agent
runtime. The tap listens in the node's network namespace (the pod is `hostNetwork: true`) on a per-agent
port, bound to `0.0.0.0`, with no authentication; a Service gives it a stable name inside the cluster.

```bash
PORT=$(kubectl get deploy -n <ns> sudo-<name> -o jsonpath='{.spec.template.spec.containers[?(@.name=="watch")].env[?(@.name=="WATCH_PORT")].value}')
curl -sS http://127.0.0.1:$PORT/healthz          # 200 OK
curl -sS http://127.0.0.1:$PORT/status           # JSON snapshot
curl -sS http://127.0.0.1:$PORT/ps               # JSON list of non-self processes
curl -sS "http://127.0.0.1:$PORT/events?n=100"   # last 100 event lines, JSONL
```

| Route | Returns | Use |
|---|---|---|
| `/healthz` | `200 OK` | the sidecar's own probes use it; a failure here is a sidecar problem, not an agent problem |
| `/status` | cursors, counters, last event, stream offset, plugin heartbeat | first read when the tap looks empty |
| `/ps` | the container's processes | proves the agent process exists and what it is doing |
| `/events?n=N`, `/events-stream` | last N lines of `events.jsonl`; then backlog plus live tail | the cheap historical read, then follow mode over the older tape |
| `/stream?n=N&kinds=…&since=<offset>` | the whole-runtime tape from `stream.jsonl` | tokens, reasoning, full tool args and results, activity beats, agent log |

`/stream` with no `kinds` serves everything; `kinds` is an opt-in filter (`reasoning`, `text`, or an
event name). `since=<byte offset>` resumes a live tail from an exact position instead of the end — the
current offset is in `/status`. Responses are plain unframed bytes with `Connection: close`, so `curl -N`
renders incrementally, and `/stream` returns 404 with an explanatory body until the stream plugin has
loaded and a turn has run: a real state, not an empty success. `bin/stream.sh --<name>` renders the same
feed for a terminal and is the practical daily driver (`--thinking`, `--answer`, `--no-logs`,
`--no-activity`, `--context`, `-t`, `--events`).

### 3.4 The event log on disk, and its sensitivity

| File (under `watch/`, on the agent PVC) | Contents |
|---|---|
| `events.jsonl` | one JSON event per line: `user`, `thinking`, `assistant`, `tool_call`, `tool_result`, `session`, `process_state` |
| `transcript.txt` | human-readable log of real operator prompts and agent replies only |
| `stream.jsonl` | whole-runtime tape: every reasoning and answer delta, pre-request input context, full tool args and results, housekeeping turns, agent log lines |
| `state.json` | cursors; restart resumes exactly, never backfills |

Read with `kubectl exec -n <ns> deploy/sudo-<name> -c watch -- tail -n 50 /opt/data/watch/events.jsonl`,
or `kubectl cp` the file out. They live on the PVC, so they survive pod deletion.

**The tapes are sensitive.** They hold full operator prompts, the model's reasoning, and the complete
arguments and results of every tool call — including whatever the agent read while working. Treat
`events.jsonl`, `stream.jsonl`, `transcript.txt` and the agent's `state.db` with the same care as the
conversation itself: do not paste raw lines into issues, chat or commit messages; quote only the event
type and timestamp. The tap serving them is unauthenticated on the node's interface, so anyone who can
reach that port can read the same content.

## 4. Debugging, in order of likelihood

```bash
kubectl get pods -n <ns> -l agent=<name> -o wide
kubectl describe pod -n <ns> <pod> | tail -30
```

### 4.1 Pod stuck in Init

**Symptom:** `Init:0/1`, `Init:Error` or `Init:CrashLoopBackOff`; `rollout status` hangs until timeout.
**Cause:** the seeding initContainer — a `--from-glimor` directory without its expected sub-tree
(`hermes/SOUL.md`, or `letta/settings.json`) is rejected rather than deployed blank, and a `hostPath`
config file missing on the node stalls it the same way, because a `hostPath` mount of type `File`
cannot be created.

```bash
kubectl logs -n <ns> <pod> -c seed-glimor
kubectl get deploy -n <ns> sudo-<name> -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{" "}{.hostPath.path}{"\n"}{end}'
```

### 4.2 A probe failing

**Symptom:** restarts climbing; `describe pod` shows `Liveness probe failed` or `Readiness probe
failed`; the pod is `Running` but never Ready, so its Services carry no endpoints.
**Cause:** the probes are protocol probes, not health checks — the agent container probes a TCP socket
on its derived MCP port, the sidecar a `GET /healthz` on its watch port. A failure means no listener on
that port: usually a port already held (4.4), or a first boot still starting.

```bash
kubectl describe pod -n <ns> <pod> | grep -A3 -E 'Liveness|Readiness|Startup'
kubectl get pod -n <ns> <pod> -o jsonpath='{range .status.containerStatuses[*]}{.name}{" restarts="}{.restartCount}{" ready="}{.ready}{"\n"}{end}'
```

Read the restart count per container, not the pod phase: a sidecar restarting says nothing about the agent.

### 4.3 The agent answers, but a comm tool fails

**Symptom:** `talk.sh` works and prompts get replies, but `list-siblings`, `message-agent` or
`check-agent` fail — a timeout, `docker permission denied`, or "could not reach the host".
**Cause:** every comm call leaves the cluster. Discovery shells out to `docker run … nsenter … kubectl
get services` through the docker socket mounted into the pod, which needs the socket mounted *and* the
calling process holding the socket's group. The agent process drops to an unprivileged user before that
group is armed unless the entrypoint arms it first, so a pod built before that fix answers prompts while
failing every comm call.

```bash
kubectl exec -n <ns> deploy/sudo-<name> -c sudo-agent -- id
kubectl logs -n <ns> deploy/sudo-<name> -c sudo-agent | grep -i docker-socket
```

A good result has the socket's gid in `groups=` and an entrypoint line reporting it armed. Related
non-bug: the roster is cluster-wide — every `sudo-*-mcp`/`-watch` pair in the discovery namespace, not a
team — so unexpected peers are the contract working as built.

### 4.4 Two hostNetwork pods colliding on a port

**Symptom:** a new pod crash-loops or never becomes Ready while an older neighbour is fine, often just
after adding an agent; logs mention an address in use, and the probe fails though the process starts.
**Cause:** every agent pod is `hostNetwork: true`, so ports are node-global. Each name derives a stable
port by hashing, so two names can collide, or an agent can land on a port something else holds (a Redis
on 6379/6380, a NodePort, an operator's service). The 8000–29999 window exists to stay clear of the
NodePort range 30000–32767, where a hostNetwork listener is silently blackholed by kube-proxy.

```bash
ss -tlnp | grep -E ':(8000|6379|6380)\b'
kubectl get deploy -n <ns> -o json | jq -r '.items[] | .metadata.name + " " + ([.spec.template.spec.containers[].env[]? | select(.name=="MCP_PORT" or .name=="WATCH_PORT" or .name=="API_SERVER_PORT") | .name + "=" + .value] | join(" "))'
```

Each derived port should appear once in the list and once in `ss`; duplicates in either are the bug.

### 4.5 A Letta agent wakes up blank

**Symptom:** the planner starts and answers, but has none of its identity, skills or persona — as if
newly created.
**Cause:** Letta's memory is a git-backed MemFS, and only **committed** memory loads. Files written into
the memory tree but never committed are silently ignored — no error, no warning, just a blank agent. The
same applies to a seed that copied files without committing, and to a pre-commit hook that rejected a
bare file under `skills/` and aborted the commit.

```bash
kubectl exec -n <ns> deploy/sudo-<name> -c sudo-letta -- bash -c \
 'd=$(ls -d /home/node/.letta/lc-local-backend/memfs/*/memory | head -1); git -C "$d" status --porcelain; git -C "$d" log --oneline -3'
```

A good result is empty `status --porcelain` and a recent commit naming the identity or skill seed;
untracked or modified entries are memory the agent cannot see.

### 4.6 The image does not match the source

**Symptom:** a fix is in the tree and in a rebuilt image, but the agent still behaves the old way, and
`kubectl apply` reports the deployment `unchanged`.
**Cause:** the pod pins a local `:latest` tag with `imagePullPolicy: IfNotPresent`, so a rebuilt image
under the same tag is invisible to Kubernetes. The manifest compensates with digest annotations, but
only when `up.sh` regenerates it — a manual apply of an old file, or a rebuild plus a restart, moves
nothing.

```bash
docker image inspect sudo-agent:latest --format '{{.Id}}'
kubectl get pod -n <ns> -l agent=<name> -o jsonpath='{.items[0].metadata.annotations.sudo-agent/image-sha}'
kubectl get pod -n <ns> -l agent=<name> -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
```

All three IDs should agree. `up.sh` also refuses to deploy when the image does not contain the current
entrypoint and MCP sources, and says so; trust that check over the tag.

### 4.7 The queue stops draining

**Symptom:** prompts are accepted — an inbox send returns a message id — but nothing is ever answered;
the agent is Ready and its log is quiet.
**Cause:** the prompt distributor. Each pod runs one drain worker claiming one item at a time from a
shared Redis on the node loopback (`redis://127.0.0.1:6380/0`, keys `sudo-agent:q:<agent>:*`). If Redis
is gone, its port is held by something else, or the worker died after claiming an item, prompts
accumulate and no run starts; an item left in flight by a killed worker blocks the queue until it expires
or the pod restarts.

```bash
kubectl get pods -n <ns> -l app=sudo-agent-redis
kubectl exec -n <ns> deploy/sudo-<name> -c sudo-agent -- \
  python3 -c "import redis,os;r=redis.from_url(os.environ['REDIS_URL']);print(r.ping());print(r.llen('sudo-agent:q:<name>:q'))"
```

The authoritative read is the `hermes_queue_status` tool on the agent's MCP endpoint: in-flight item,
pending queue, last 20 results. An in-flight entry with an empty pending queue is a run in progress, not
a leak — that distinction is the tool's whole value.

## 5. Recovery

### 5.1 Stop an agent, keep its state

```bash
bash factories/sudo-agent/bin/down.sh --<name>
bash factories/sudo-letta/bin/down.sh --<name>
```

Deletes the Deployment only. The PVC stays, so memory, transcripts and tapes are intact, and
`up.sh --<name>` returns the same agent on the same volume. Stopping is not purging. The repo-level
`bin/k8s-down.sh` wraps both factories for the two router agents the bootstrap seeds (their names are
baked into that script) and verifies no pod remains before reporting success — it refuses to claim a stop
while a pod is terminating. For an arbitrary agent, use the factory `down.sh`.

### 5.2 Purge state, and tear down the cluster

```bash
kubectl delete deploy -n <ns> sudo-<name>
kubectl delete pvc -n <ns> sudo-<name>-data      # destructive; no undo

bash bin/k8s-down.sh --purge                     # the seeded router pair
bash bin/k8s-down.sh --teardown-k3s              # then uninstall k3s
```

After a purge the next deploy starts from its seed source, or blank if there was none; the tapes and the
agent's memory go with the volume. `--teardown-k3s` stops the agents first, then runs
`/usr/local/bin/k3s-uninstall.sh`, removing the cluster, its datastore and every PVC on it. If that
script is missing it says so and leaves k3s in place rather than pretending. Docker images are not
removed; `setup.sh` is the way back.

### 5.3 What returns on reboot

systemd starts docker and k3s (both enabled at install); k3s restores what its datastore holds —
Deployments, Services, PVCs — and kubelet starts the pods. Volumes persist, and images
persist in the containerd store, so nothing needs pulling.

Queue durability differs by factory, and it is worth knowing before a restart. The Hermes
queue is configured with append-only persistence on a dedicated PVC, so its backlog survives
both agent and Redis pod recreation. The planner queue runs with persistence explicitly
disabled, so an in-flight planner prompt does not survive a Redis restart. Neither factory
claims exactly-once execution.

The boot
unit adds the repair steps: wait for the node to be Ready (up to about ten minutes, degrading to a warning
rather than failing), re-import any of the three locally built images missing from containerd, re-run the
idempotent bring-up, re-reconcile the control plane's agent registry, and write a proof file.

```bash
systemctl status sudo-fleet-boot.service
cat <repo>/durable-boot-proof/latest.txt
ls -t /logs/k8s-auto-up-*.log | head -1
```

`latest.txt` records the boot id, timestamp, node, whether k3s came Ready, whether both images were
present, and the pod list at that moment — the fastest answer to "did the box come back by itself". Two
caveats: the unit re-runs `k8s-up.sh`, so a repository whose second command fails (2.1) fails again on
every boot; and a boot does not repair drift introduced by hand.

### 5.4 The boot unit is a path, and paths rot

`setup.sh` writes `/etc/systemd/system/sudo-fleet-boot.service` with
`ExecStart=/usr/bin/env bash <repository folder>/bin/k8s-auto-up.sh`. `<repository folder>` is resolved
from the location of `setup.sh` at install time and baked in as an absolute path, so the unit is correct
when written and becomes wrong the moment the checkout moves, is re-cloned elsewhere, or was written by an
older revision pointing at a layout that no longer exists — for example a `kube-scripts/` directory that
is not in the current tree.

A stale unit is invisible until a reboot: it is `enabled`, `systemctl status` reports no error, and
`journalctl -u sudo-fleet-boot.service` is empty because it has never successfully executed. Everything
k3s restores still comes back; only the repair steps are missing, which is exactly the part an operator
relies on without checking. Re-running `setup.sh` is not by itself a repair: it regenerates the unit only
when its install step runs and finds `bin/k8s-auto-up.sh` under the tree it is run from.

```bash
systemctl cat sudo-fleet-boot.service          # ExecStart path must exist
systemctl is-enabled sudo-fleet-boot.service   # expect: enabled
journalctl -u sudo-fleet-boot.service -n 20    # empty = never ran
```

If the `ExecStart` path does not exist, regenerate the unit (run the install step from the current
checkout, or rewrite the unit), then `systemctl daemon-reload` and
`systemctl enable --now sudo-fleet-boot.service`. Confirm a real run, not an enabled state: the unit
appears in the journal and drops a fresh `durable-boot-proof/latest.txt`.

## 6. Verification discipline after a complex change

A complex change touches more than one moving part: an image plus its config, a service plus its
datastore, an agent plus its harness. `docs/CHANGE-PROTOCOL.md` proves four things in order, and
`bin/verify-change.sh` is its machine-runnable half.

| Check | The question | What proves it here |
|---|---|---|
| RUNTIME | serving, not just Running? | readiness gate passing, restart count 0, and the running artifact's identity read from the live pod — never inferred from the tag |
| CONFIG DRIFT | does live config match the repository? | deployed spec vs committed source; here that source is a heredoc inside `up.sh`, not a manifest file, so the diff is against the script |
| AUTH | what guards it right now? | an expected-fail: an unauthenticated request must return 401/403; a 2xx is a failure |
| EXPOSURE | every path in | Service types and ports, plus the node's own listening sockets — `hostNetwork` makes the node port the real surface |

```bash
bash bin/verify-change.sh --namespace <ns> --target sudo-<name> \
  --url http://127.0.0.1:<health-port>/healthz \
  --expect-fail-url http://127.0.0.1:<api-port>/v1/runs
```

One status per check plus a verdict; exit 0 PASS, 1 FAIL, 2 DEGRADED — and DEGRADED is not a pass: the
check ran and could not fully verify something, which is a finding. `--json` emits one object. The
routine after a complex change: run the four checks in order, recording one number per check in the
foreground into a file (never carry a number over from an earlier run); if two readings disagree, re-run
once, fresh, and keep the single confirmed value; write findings into `docs/KNOWN-ISSUES.md` as a dated
section in the existing shape — severity, finding, evidence, unresolved — with remediation as a separate
explicit step, never a side effect of verification; then re-run the deploy path on a fresh pod, because a
fix applied to a live pod and not represented in the image or the template is drift the next deploy
erases.

**A running pod proves none of the four.** Pods run with the wrong config, auth effectively off, a stale
image, and more open ports than intended, and every probe stays green. This stack makes that concrete:
the probes are protocol probes, so they prove a listener exists and nothing about what it serves; the
Deployment carries some values as secret references and others as literal environment values, so "it is
in a Secret" is not a safe assumption; and the observer tap is unauthenticated on a node port, so
exposure must be read off the host, not off the Service list.

## 7. Failure table

| Symptom | First command | Good result |
|---|---|---|
| Running but never Ready; Services have no endpoints | `kubectl describe pod -n <ns> <pod> \| grep -A3 -E 'Liveness\|Readiness\|Startup'` | probes passing; a failing probe names the port to check next |
| `Init:0/1`, `Init:Error`, rollout hangs | `kubectl logs -n <ns> <pod> -c seed-glimor` | seed copied, exit 0; an error names the missing file |
| Crash loop right after another agent was added | `ss -tlnp \| grep :<port>` | the port is bound exactly once, by this pod |
| `ImagePullBackOff` on a locally built image | `k3s ctr images ls -q \| grep sudo-agent` | the tag is present; absent means the boot re-import also failed |
| Behaviour unchanged after a code fix | `docker image inspect sudo-agent:latest --format '{{.Id}}'` vs the pod's `sudo-agent/image-sha` | both IDs identical |
| Agent replies, comm tools time out | `kubectl exec -n <ns> deploy/sudo-<name> -c sudo-agent -- id` | `groups=` includes the docker socket gid |
| Letta agent has no identity | `git -C <memfs>/memory status --porcelain` inside the pod | empty output and a recent commit |
| Prompt accepted, never answered | `kubectl get pods -n <ns> -l app=sudo-agent-redis` | Redis Running; pending count draining |
| `/stream` returns 404 | `curl -sS http://127.0.0.1:<watch-port>/status` | plugin heartbeat present; 404 means no plugin or no turn yet |
| Nothing runs after a reboot | `systemctl cat sudo-fleet-boot.service` | `ExecStart` points at a path that exists (5.4) |
| Cluster unreachable after a reboot | `systemctl is-enabled k3s docker` | both `enabled`, then `kubectl get nodes` shows Ready |
