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

Finding: `svc/paperclip-node` (NodePort 3100:31310) exposes the app on the
node's LAN address at that port, with no TLS and no proxy auth in front.
`/api/health` is open; the API endpoints are guarded only by the app's own auth.
(The concrete address was removed from this public document on 2026-10-27; it is
an instance fact, recorded in the original finding outside the repository.)

Evidence: `curl /api/health` → 200; `curl /api/companies` (no auth) → 403;
`curl /api/companies` (Bearer bogus) → 401.

Unresolved: yes.

### PC-6. No recent database backup — LOW — unresolved

Finding: the health endpoint reports `database_backup_missing`.

Evidence: `/api/health` →
`"databaseBackup":{"enabled":true,"status":"warning",...}`.

Unresolved: yes.

## Documentation pass — 2026-10-27

Findings recorded while auditing the docs against the code. Each entry follows
the existing shape: severity / finding / evidence / unresolved. None of these
were fixed by that pass — it was documentation-only, and several of them are
architecture questions, not typos.

### D1. ~~`bin/k8s-up.sh` cannot complete: the identity packages it seeds from were deleted~~ — RESOLVED in code (`07d5d77`); the pages that still said otherwise were corrected 2026-10-28

Finding (recorded 2026-10-27): Command 2 deployed `Marc` and `Caesar` by
passing `--from-glimor "$FLEET_HOME/deployments/Marc"` (and `.../Caesar`) to
each factory's `up.sh`, then waited on pods labelled `agent=marc` /
`agent=caesar`. Both directories had been deleted, and because a named-but-missing
seed is deliberately fail-loud, the deploy aborted at the first `up.sh` call —
on every boot, since `bin/k8s-auto-up.sh` re-runs it.

Resolved by the code in commit `07d5d77` ("fix: repair Command 2, hash the trial
key, and keep instance identity out"). At HEAD:

- the defaults are `PLANNER_NAME=planner` / `ENGINEER_NAME=engineer`
  (`bin/k8s-up.sh:30-31`), producing `sudo-planner` / `sudo-engineer`
  (`:32-33`);
- `_seed_for` (`:37-41`) emits `--from-glimor <dir>` **only when that directory
  exists**, so an empty `deployments/` deploys two clean agents;
- the pair is waited on by label (`agent=planner`, `agent=engineer`); grep for
  `marc`/`caesar` in `bin/k8s-up.sh` and `bin/k8s-down.sh` returns nothing, so
  the fixed pair is gone from the deploy and the teardown.

Evidence at HEAD: `ls deployments/` → `README.md` only; `grep -n _seed_for
bin/k8s-up.sh` → `:37`; `git log --oneline -S _seed_for -- bin/k8s-up.sh` →
`07d5d77`.

Unresolved: no, in code. The residue was documentation: `ARCHITECTURE.md` §1,
`OPERATIONS.md` §2.1, `REPOSITORY-VS-INSTANCE.md` and `SPEC.md` each still told
the reader that Command 2 fails on a fresh clone. All four were corrected in
the same pass as this entry.

### D2. A boot unit installed by an older revision points at a path that does not exist — MEDIUM — unresolved

Finding: `setup.sh` writes `/etc/systemd/system/sudo-fleet-boot.service` whose
`ExecStart` runs `$FLEET_HOME/bin/k8s-auto-up.sh`, which is correct.

A unit installed on one instance by an earlier revision instead runs
`$FLEET_HOME/kube-scripts/k8s-auto-up.sh`. No `kube-scripts/` directory exists
in the fleet root. The unit reports itself enabled while never having run
successfully — boot recovery is silently absent.

Evidence: unit file `ExecStart` line on an affected host; `journalctl -u
sudo-fleet-boot.service` → no entries at all; `ls $FLEET_HOME/kube-scripts` →
no such directory.

Unresolved: yes, and it is instance drift rather than a repo defect: the repo's
`setup.sh` is correct. Re-running `setup.sh` regenerates the unit, but nothing
detects that an installed unit is stale. A future `setup.sh` could compare the
installed `ExecStart` against the one it would write and re-emit on mismatch.
NOT done here.

### D3. An agent cannot read the repository checkout from inside its pod — MEDIUM — by design, now documented

Finding: `/opt/0-0/...`-style host paths that hold the fleet checkout are not
visible inside a deployed agent pod. The agent's only persistent view is its own
PVC.

This is correct behaviour for a generic user of the repo — a host's directory
layout is an instance fact — but it silently breaks any workflow that assumes an
engineer can verify against the live checkout. Anything an agent must read has to
be handed to it: a bind mount, a `kubectl cp`, or a copy it fetches itself.

Evidence: `kubectl exec` into each deployed engineer, `ls <checkout>/factories`
→ no such file or directory, on all of them.

Unresolved: no for the contract; the documentation now states it. Any workflow
that dispatches repo work to an agent must hand over the files.

### D4. Some values reach a Deployment as literal env values, not `secretKeyRef` — HIGH — unresolved

Finding: LLM keys are injected through `secretKeyRef`. Two others are not: the
agent's `SUDO_PASSWORD` and the control-plane key plus its agent and company
identifiers are written as plain `env[].value` into the generated Deployment for
every Hermes engineer.

Consequences: anyone who can read a Deployment object in any namespace can read
those values in clear text, and they persist in the object's
`last-applied-configuration` annotation as well. The process is readable by
anything with `get deploy` permission, which is a far wider audience than
`get secret`.

Evidence: the generated Deployment for a deployed engineer; the `up.sh` block
that writes the `SUDO_PASSWORD` and `PAPERCLIP_*` entries emits `value:` rather
than `valueFrom`. No values are reproduced here — this repository is public.

Unresolved: yes. Moving them to a Secret is a code change, explicitly out of
scope for the documentation pass.

### D5. The repo is described as a pure factory while also carrying live identities — MEDIUM — unresolved

Finding: `SOURCE-OF-TRUTH.md` states that product content — personas, domain
skills, the work — belongs in a separate workload repository, and that this repo
owns only the deployment machinery.

At the same time, `deployments/` commits two complete agent identity packages,
including `persona.md`, `human.md`, and `settings.json`. A reader sees both
claims at once.

Evidence: `git ls-files deployments/` lists the identity files; `SOURCE-OF-TRUTH.md`
states the split.

Unresolved: yes, deliberately. The tension is now documented in
`SOURCE-OF-TRUTH.md` rather than quietly resolved by deleting the identities.

### D6. The sibling roster is cluster-wide, with no team or namespace scoping — MEDIUM — unresolved

Finding: the comm layer's `list-siblings` reads every `sudo-*-mcp` service pair
in the discovery namespace and returns them as peers. There is no label
selector, no namespace parameter, and no group concept.

On a busy instance this means one agent's roster contains every other agent in
the cluster, related or not, and a planner has no way to express "my team" in
the current contract. `docs/NEXT.md` already identifies namespace scoping as the
next direction; this entry records that the *current* contract does not have it,
so no document should imply it does.

Evidence: the roster tool shells out to a cluster-wide service listing and
filters only on a name substring; the mod's parser keeps every `sudo-`-prefixed
`-mcp`/`-watch` pair.

Unresolved: yes — it is the NEXT.md direction, not a defect to patch here.

### D7. The watch tap binds every interface with no authentication — MEDIUM — unresolved

Finding: each agent's `watch` sidecar serves its HTTP tap on `0.0.0.0` at the
agent's derived watch port. There is no token, no basic auth, and no network
policy in front of it. Because every agent pod runs with `hostNetwork: true`, the
tap is a node port, not a cluster-internal address.

The tap exposes `/status`, `/ps`, `/events` and `/stream` — process lists, every
prompt, every reply, all reasoning, and every tool call and result. `docs/SPEC.md`
and the factory README describe the tap as "in-cluster only"; under hostNetwork
that is not what the code does. On a single-NIC host it is reachable from the
host's network unless a firewall in front of the node blocks it.

Evidence: `srv = ThreadingHTTPServer(("0.0.0.0", int(CONFIG["watch_port"])),
TapHandler)` in the watch sidecar source, with no auth header check in the
handler. Confirmed independently by an engineer during the 2026-10-27
documentation pass, and in source review.

Unresolved: yes. Options are a bind to the loopback of the node, a shared token on
the tap, or a NetworkPolicy — all of them code or manifest changes, out of scope
for a documentation pass. Documented so that nobody relies on the "in-cluster
only" wording.

### D8. `setup.sh` carries a credential-shaped literal in the public repository — HIGH — unresolved

Finding: `setup.sh` defines `_TRIAL_KEY` — a real, key-shaped string — and a guard that refuses
to continue when the operator's supplied key equals it. The guard's intent is sound: stop someone
from bootstrapping on a shared trial key.

The mechanism leaks the key it is trying to forbid. The value is committed, so it is in every
clone, every fork, every mirror, and the full history of a **public** repository. A literal that
exists to be rejected is still a literal that is now public.

Evidence: the `_TRIAL_KEY` assignment and the comparison against it in `setup.sh`, present on
`origin/main` and introduced by commit `43c3974` ("replace inline API keys with Kubernetes
Secrets + trial key detection"). The value is deliberately not reproduced here.

Unresolved: yes. This needs a decision the maintainer has to make, because it is not reversible by
editing the file: rotating the key does not un-publish it, and scrubbing it from history rewrites
shared history on a repository others may have cloned. The cheapest correct fix is to remove the
literal, compare against a hash of the forbidden value instead, and treat the published key as
burned. Recorded here so the exposure is not lost with the working session.

Found by an engineer during the 2026-10-27 documentation pass, and confirmed by the lead against
`origin/main`.

### D9. `setup.sh` rebuilds and retags `sudo-agent:latest` on every run — MEDIUM — unresolved

Finding: the sudo-agent image build in `factories/sudo-agent/setup.sh` is
unconditional. The base image directly above it is inspect-guarded; the agent
build is not. Every run retags `sudo-agent:latest` from whatever tree that run is
executing — a re-run on a host that already has a good image, or a run from a
stale, partial, or foreign copy. The tree that gets built is the tree the script
was copied from, which is not necessarily the current checkout.

Consequence: the tag that running pods were started from now points at a
different image. Pods already running keep the image they started with — the
generated agent Deployments pin the tag with `imagePullPolicy: IfNotPresent` —
and the next pod to be created, recreated, or rolled starts on the new one. The
result is a silent version split, some deployments on the old image and some on
the new, with no error, no prompt, and no line of output that says a tag moved.

It also contradicts the rebuild trap the docs already carry: `docs/OPERATIONS.md`
section 4.6 and the `image-sha` pod annotation described in `docs/ARCHITECTURE.md`
exist because a same-tag rebuild is invisible to a controller that pins
`:latest`. The fleet relies on that explicit image identity at deploy time; an
unguarded retag rotates the identity out from under it.

The repo-root bootstrap inherits the behaviour. `setup.sh:453` pipes the key into
the factory tree's `setup.sh`, so a re-run of the README's Command 1 has the same
effect.

Evidence: `factories/sudo-agent/setup.sh:51` is the base-image guard,
`if ! docker image inspect hermes-agent:latest &>/dev/null; then`. Line 63 builds
and tags the agent image on every invocation, with its failure handler on `:64`.
Both are present at `c0d44f5` and unchanged at `41eba2b`:

`_retry 3 "docker build sudo-agent" docker build -t sudo-agent:latest -f`
`"$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR" \`
`  || { echo "Sudo-agent build failed."; exit 1; }`

Proven with a logging `docker` stub first on `PATH` — a stub whose `build`
subcommand logs its argv and exits 0 — on a host where both
`hermes-agent:latest` and `sudo-agent:latest` already report present. One run of
the script emitted `DOCKER_CALL: info`,
`DOCKER_CALL: image inspect hermes-agent:latest`,
`DOCKER_CALL: build -t sudo-agent:latest -f <tree>/Dockerfile <tree>`: the base
build was skipped as designed, the agent build was not.

Unresolved: yes. This is a behaviour change in the installer, not a docs fix, and
it must not be fixed by simply deleting the build — a tree without the image
still needs one. Two candidate fixes, neither chosen here: (a) guard the build on
`docker image inspect sudo-agent:latest` the way the base image is already
guarded — cheapest, but a Dockerfile change can then never be picked up without a
manual `docker rmi`; (b) build to a content-addressed or per-commit tag and have
the deploy path pin that tag — no silent overwrite, but it touches the deploy path
and the generated manifest. The choice is a maintainer decision, not a
documentation one. Nothing was rebuilt, retagged, or deployed while recording
this.

Found by engineer h1 (`sudo-fleet-glm-h1`, the `sudo-sudo-fleet-glm-h1`
deployment) on 2026-10-28, and confirmed by the lead at HEAD.
