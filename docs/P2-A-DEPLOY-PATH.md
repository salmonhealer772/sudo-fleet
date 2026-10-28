# P2-A — the deploy path builds the pinned base

Owner: `sudo-fleet-glm-h1` · Phase 2 · 2026-10-28 (UTC) · branch `main`
Files changed: `factories/sudo-agent/bin/up.sh`, `factories/sudo-agent/setup.sh`,
`bin/k8s-auto-up.sh` (one line, see §7)

## Verdicts

| Part | Verdict | One-line reason |
|---|---|---|
| **1 — base image path** | **PASS** | `up.sh` no longer builds, tags or imports any `hermes-agent:latest`. Its one remaining build (`_ensure_image_built`) runs the factory Dockerfile, whose `FROM nousresearch/hermes-agent:v0.22.5` docker resolves by itself. Two base-manufacturing code paths deleted, one import deleted. |
| **2 — one-command install path** | **PASS** | The install path (`factories/sudo-agent/setup.sh`, which root `setup.sh` calls) already shared the pinned Dockerfile, so it never shipped a wrong *version* — but it built a second, unpinned `hermes-agent:latest` base first and could only tag its output `sudo-agent:latest`. Both are fixed: base prefetch deleted, tag overridable via `SUDO_AGENT_IMAGE`. **Measured equal**: both paths, building one identical tree, exported the identical image manifest `sha256:b96404e8…`. |
| **3 — the image boots** | **PASS** | `sudo-agent:p2a-h1` runs standalone: reports `Hermes Agent v0.22.5`, patch marker `0`, all five baked paths present, `fastmcp`/`redis`/`ddgs` import. |

**Can this repo now produce a working agent?** Yes for the path this brief owns: a
clone → `bash setup.sh` → `cd bin && bash k8s-up.sh` now builds *one* image, from
*one* pin, in exactly one way, and that image boots and reports v0.22.5 with no
memory patch. What is still missing for a stranger is documentation of the pin and
the runtime checks — that is h5's and h4's briefs, not this one.

---

## 1. Why the local tag existed, and why it could go

Phase 1's F1 says the qualified reference pulls with no local tag. Re-verified here
before deleting anything:

```
$ docker manifest inspect nousresearch/hermes-agent:v0.22.5
{
   "schemaVersion": 2,
   "mediaType": "application/vnd.docker.distribution.manifest.list.v2+json",
   "manifests": [
      { "digest": "sha256:fd822bae0a61…", "platform": { "architecture": "amd64", "os": "linux" } },
      { "digest": "sha256:41f1cfdd2486…", "platform": { "architecture": "arm64", "os": "linux" } }
   ]
}
```

A real multi-arch manifest list, exit 0, no local tag involved. The local
`hermes-agent:latest` only ever worked because the *old* Dockerfile said bare
`FROM hermes-agent:latest`; nothing in the repo references that tag as a runtime
image, and no deployment has ever run it (checked: the cluster's deployment→image
map contains no `hermes-agent` reference, and `k3s ctr images ls` has one stale
copy from the old import). Nothing consumes it, so nothing was left needing it.

## 2. What changed (exact diff)

```
diff --git a/bin/k8s-auto-up.sh b/bin/k8s-auto-up.sh
index 509cdfa..e50d682 100755
--- a/bin/k8s-auto-up.sh
+++ b/bin/k8s-auto-up.sh
@@ -90,7 +90,11 @@ mkdir -p "$LOG_DIR" 2>/dev/null || true
     docker save "$img" | k3s ctr image import - \
       || docker save "$img" | ctr -n k8s.io image import -
   }
-  for _img in hermes-agent:latest sudo-agent:latest sudo-letta:latest; do
+  # Only images pods actually RUN. A local `hermes-agent:latest` used to be in
+  # this list to serve the factory's old bare `FROM hermes-agent:latest`; the
+  # pin is qualified now, so no deployment references it and re-importing it (or
+  # warning that it is missing, every boot, forever) is noise at best.
+  for _img in sudo-agent:latest sudo-letta:latest; do
     if _image_present "$_img"; then
       ok "$_img already in containerd"
       continue
diff --git a/factories/sudo-agent/bin/up.sh b/factories/sudo-agent/bin/up.sh
index d937521..faf7925 100755
--- a/factories/sudo-agent/bin/up.sh
+++ b/factories/sudo-agent/bin/up.sh
@@ -553,8 +553,9 @@ echo "→ watch scripts digest: ${WATCH_SCRIPTS_SHA:0:12}"
 # IfNotPresent, so a REBUILT image under the same tag does NOT roll the
 # Deployment on its own: kubectl apply sees the tag and the watch-scripts
 # digest both unchanged and reports "deployment ... unchanged", leaving the
-# running pod on the OLD image. An image-only fix (e.g. the old patch_memory_review.py
-# change) would silently never reach the pod. Pin the docker image's
+# running pod on the OLD image. An image-only fix (e.g. the base bump, or a
+# change to the tools baked under /opt/comm-tools) would silently never reach
+# the pod. Pin the docker image's
 # content-addressable ID as a pod-template annotation so kubectl apply
 # recreates the pod exactly when the image content changes.
 IMAGE_SHA="$(docker image inspect sudo-agent:latest --format '{{.Id}}' 2>/dev/null)"
@@ -1302,29 +1303,25 @@ _import_once() {
 # used to hard-fail ("nothing to import. Build it first: bash setup.sh") and
 # leave the operator to go re-run a setup step mid-deploy. Build the image HERE
 # instead, and fail ONLY if the build itself fails.
-_build_hermes_base() {
-  local tmp
-  tmp="$(mktemp -d)" || return 1
-  _retry 3 "git clone hermes-agent" git clone --depth 1 https://github.com/NousResearch/hermes-agent.git "$tmp" \
-    || { rm -rf "$tmp"; return 1; }
-  _retry 3 "docker build hermes-agent" docker build -t hermes-agent:latest "$tmp" \
-    || { rm -rf "$tmp"; return 1; }
-  rm -rf "$tmp"
-  return 0
-}
-
-# _ensure_image_built IMG — build IMG when it is missing. hermes-agent:latest is
-# the sudo-agent BASE image, cloned + built exactly as setup.sh does it; every
-# other image builds from THIS factory's Dockerfile into the repo as context.
+#
+# THERE IS NO SEPARATE BASE BUILD, and it must not come back. The sudo-agent
+# Dockerfile's FROM is the qualified, pinned `nousresearch/hermes-agent:v<ver>`
+# reference, which docker PULLS BY ITSELF during the build below (verified with
+# `docker manifest inspect` on that reference: a real multi-arch manifest list,
+# so no local tag is required first). The old local `hermes-agent:latest` tag
+# only ever worked because the Dockerfile said a bare `FROM hermes-agent:latest`;
+# keeping the clone+build here manufactured a SECOND base — unpinned, tracking
+# upstream's default branch — so the deploy path could drift off the pin without
+# the Dockerfile changing at all. One build path, one pin: the Dockerfile's.
+
+# _ensure_image_built IMG — build IMG from THIS factory's Dockerfile (the repo
+# is the build context) when it is missing. The pinned base is pulled by that
+# build; nothing is built or tagged on the side.
 _ensure_image_built() {
   local img="$1"
   docker image inspect "$img" >/dev/null 2>&1 && return 0
   echo "→ docker image $img is missing locally — building it now..." >&2
-  if [[ "$img" == "hermes-agent:latest" ]]; then
-    _build_hermes_base || return 1
-  else
-    _retry 3 "docker build $img" docker build -t "$img" -f "$REPO_DIR/Dockerfile" "$REPO_DIR" || return 1
-  fi
+  _retry 3 "docker build $img" docker build -t "$img" -f "$REPO_DIR/Dockerfile" "$REPO_DIR" || return 1
   docker image inspect "$img" >/dev/null 2>&1
 }
 
@@ -1411,7 +1408,11 @@ _assert_image_fresh() {
 
 echo "→ Importing images..."
 _assert_image_fresh
-_import_image hermes-agent:latest
+# Only the image the pods RUN is imported. A local `hermes-agent:latest` import
+# used to sit here to serve the old bare FROM; with the pin qualified the base is
+# pulled by the build and no pod ever references it, so importing it was 4.5 GB
+# of containerd churn (and a build of upstream main on any host missing the tag)
+# for an image nothing runs.
 _import_image sudo-agent:latest
 
 # ── Apply ──
diff --git a/factories/sudo-agent/setup.sh b/factories/sudo-agent/setup.sh
index 4f63322..ee3e060 100755
--- a/factories/sudo-agent/setup.sh
+++ b/factories/sudo-agent/setup.sh
@@ -38,31 +38,31 @@ _retry() {
   return 1
 }
 
-# Build the two images if they are absent. Order matters: sudo-agent used to be
-# `FROM hermes-agent:latest`, so the base was built first. Its FROM is now the
-# pinned `nousresearch/hermes-agent:v0.22.5`, which docker pulls itself, but the
-# local base below is still built and imported by up.sh. The sudo-agent
-# Dockerfile then (a) symlinks the base's off-PATH uv onto /usr/local/bin so
-# its `uv pip install` steps resolve, and (b) bakes the comm tools into
-# /opt/comm-tools/ at the IMAGE level (never shadowed by the /opt/data PVC —
-# that PVC only receives the comm skills + persona on first boot, see
-# mcp_entrypoint.sh). Each build retries transient network failures; if one
-# still fails after retries, abort — a missing image is fatal downstream.
-if ! docker image inspect hermes-agent:latest &>/dev/null; then
-  echo "→ Building base Hermes Agent image (3-5 min)..."
-  TMP_DIR=$(mktemp -d) || { echo "Failed to create temp dir"; exit 1; }
-  _retry 3 "git clone hermes-agent" git clone --depth 1 https://github.com/NousResearch/hermes-agent.git "$TMP_DIR" \
-    || { echo "Git clone failed. Check internet."; exit 1; }
-  _retry 3 "docker build hermes-agent" docker build -t hermes-agent:latest "$TMP_DIR" \
-    || { echo "Docker build failed."; exit 1; }
-  rm -rf "$TMP_DIR"
-  echo "✓ Base image built"
-fi
+# Build the sudo-agent image. There is NO separate base-image step: the
+# Dockerfile's FROM is the qualified, pinned `nousresearch/hermes-agent:v0.22.5`,
+# which docker pulls by itself during this build. A prefetch step used to sit
+# here that cloned upstream's default branch and built `hermes-agent:latest` by
+# hand — a SECOND, UNPINNED base with nothing left to use it, i.e. exactly the
+# silent drift the pin exists to prevent, plus a 3-5 minute build of an image no
+# pod runs. One build path, one pin: the Dockerfile's.
+# The sudo-agent Dockerfile (a) symlinks the base's off-PATH uv onto
+# /usr/local/bin so its `uv pip install` steps resolve, and (b) bakes the comm
+# tools into /opt/comm-tools/ at the IMAGE level (never shadowed by the /opt/data
+# PVC — that PVC only receives the comm skills + persona on first boot, see
+# mcp_entrypoint.sh). The build retries transient network failures; if it still
+# fails after retries, abort — a missing image is fatal downstream.
+
+# The tag is overridable ONLY so the build can be verified without re-pointing
+# `sudo-agent:latest` on a host that already runs agents against it (they run it
+# with imagePullPolicy: IfNotPresent, so a re-pointed tag silently changes what
+# the NEXT pod recreation runs, days later, untested). The default is what
+# bin/up.sh expects and what every documented install produces.
+AGENT_IMAGE="${SUDO_AGENT_IMAGE:-sudo-agent:latest}"
 
-echo "→ Building sudo-agent image..."
-_retry 3 "docker build sudo-agent" docker build -t sudo-agent:latest -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR" \
+echo "→ Building sudo-agent image ($AGENT_IMAGE)..."
+_retry 3 "docker build $AGENT_IMAGE" docker build -t "$AGENT_IMAGE" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR" \
   || { echo "Sudo-agent build failed."; exit 1; }
-echo "✓ sudo-agent image built"
+echo "✓ $AGENT_IMAGE image built"
 
 # --- Prompt for DeepSeek API key (env-first: never prompt if a key is available) ---
 ENV_FILE="$SCRIPT_DIR/.env"
```

The Dockerfile was **not** changed: `FROM nousresearch/hermes-agent:v0.22.5`
(line 15) was already the pin that Phase 1 validated. Both code paths now honour it
instead of routing around it.

`bash -n` — GNU bash, the real one on the host (`5.3.9(1)-release`), not busybox
ash, which reports a false error around `up.sh:598` because it lacks `<<<`:

```
$ bash -n factories/sudo-agent/bin/up.sh     -> (no output) exit 0
$ bash -n factories/sudo-agent/setup.sh      -> (no output) exit 0
$ bash -n bin/k8s-auto-up.sh                 -> (no output) exit 0
```

The `IMAGE_SHA` guard (`up.sh:551-566`) is untouched except for the one comment
clause that named the deleted `patch_memory_review.py`; the guard itself, its exit
path and its message are byte-identical.

## 3. Part 1 proof — the deploy path resolves the pinned base

The test is not "the Dockerfile is pinned", it is "the code that runs during a
deploy builds from it". So the build below was executed by **`up.sh`'s own
`_ensure_image_built`**, extracted verbatim from the file on disk, against a
throwaway tag — the same function `_assert_image_fresh` and `_import_image` call
during a deploy:

```
=== every image build in up.sh (must be exactly ONE, from the Dockerfile) ===
1324:  _retry 3 "docker build $img" docker build -t "$img" -f "$REPO_DIR/Dockerfile" "$REPO_DIR" || return 1
=== the base reference that build will use (Dockerfile FROM) ===
15:FROM nousresearch/hermes-agent:v0.22.5

=== running _ensure_image_built sudo-agent:p2a-h1 ===
→ docker image sudo-agent:p2a-h1 is missing locally — building it now...
#1 [internal] load build definition from Dockerfile
#2 [internal] load metadata for docker.io/nousresearch/hermes-agent:v0.22.5
#5 [ 1/17] FROM docker.io/nousresearch/hermes-agent:v0.22.5@sha256:9c5561579f3ffdf333401797094ac3a743738d6c25d40f4331c7bf77b694238d
#22 naming to docker.io/library/sudo-agent:p2a-h1 done
BUILD_RC=0
```

`hermes-agent` now appears in `up.sh` only in comments — the three live references
(`_build_hermes_base`, the `[[ "$img" == "hermes-agent:latest" ]]` branch, and
`_import_image hermes-agent:latest`) are gone:

```
$ grep -n "hermes-agent" factories/sudo-agent/bin/up.sh | grep -v '^[0-9]*:#'
(nothing)
```

## 4. Part 3 proof — the image boots (same image h2 deploys)

`sudo-agent:p2a-h1` — built by the deploy path from the checkout at 19:22Z,
including `comm/` as it stood at that moment.

**(b) version**

```
$ docker run --rm sudo-agent:p2a-h1 hermes --version
Hermes Agent v0.22.5 (2026.9.24) · upstream bf0203a7
Install directory: /opt/hermes
Install method: docker
Python: 3.14.9
OpenAI SDK: 2.24.0
```

The `(2026.9.24)` is Hermes's internal semver epoch, not the base version. The old
image reported `vunknown`, which is how the drift went unnoticed.

**(c) the memory patch is gone** (space form — the hyphenated form returns 0 on the
old patched image too, so it proves nothing):

```
$ docker run --rm --entrypoint sh sudo-agent:p2a-h1 -c 'grep -c "PROGRAMMATIC AUTO-SAVE" /opt/hermes/agent/background_review.py; wc -l < /opt/hermes/agent/background_review.py'
0
1349
```

`patch_memory_review.py` is not in the image (`find / -name patch_memory_review.py`
→ empty).

**(d) image identity**

```
$ docker image inspect sudo-agent:p2a-h1 --format '{{.Id}} {{.Created}} {{.Size}} {{len .RootFS.Layers}}'
sha256:ebc56f72e84a2342b59344fdb413534e998420b69c0b12ea7e6b504ed63edbf9
2026-10-28T12:22:56-07:00   1075095906   53
```

Underlying image manifest (stable across rebuilds of the same tree, unlike the
manifest-list digest above): `sha256:b96404e88b8a6f93d759a4327c2eff6d6b1bdf74dcddd9d3c918aa363fa57260`.
Base: `nousresearch/hermes-agent:v0.22.5@sha256:9c5561579f3f…`, 37 of the 53 layers.

**(f) it boots and every expected path is present**

```
$ docker run --rm --entrypoint sh sudo-agent:p2a-h1 -c 'for p in /opt/comm /opt/comm-tools /opt/comm-skills /opt/meta-data /opt/hermes-mcp; do ... done'
PRESENT  /opt/comm
PRESENT  /opt/comm-tools
PRESENT  /opt/comm-skills
PRESENT  /opt/meta-data
PRESENT  /opt/hermes-mcp
/opt/comm-tools: README.md __pycache__ check_agent.py comm_gate.py comm_tools.py list_siblings.py message_agent.py real_transport.py
/opt/hermes-mcp: hermes_prompt.py mcp_entrypoint.sh mcp_server.py
/opt/meta-data:  SOUL-BINDING.md
/opt/watch-sidecar: ABSENT (expected - ConfigMap mount, not baked)
```

`/opt/watch-sidecar` **is supposed to be absent**: Phase 1's F3 established the
watch sidecar ships as a ConfigMap mount (`up.sh` around the watch-sidecar volume),
not as a baked path. Its absence is the correct result, and adding it to the image
would be the bug.

Python packages resolve (measured with the venv, which is uv-managed — `pip` is not
installed in it, and `pip show` reads everything as NOT INSTALLED in this image):

```
$ docker run --rm --entrypoint sh sudo-agent:p2a-h1 -c 'python3 -c "import fastmcp, redis, ddgs; print(fastmcp.__version__)"'
4.0.9
$ ... /opt/hermes/.venv/bin/python -c 'import importlib.metadata as m; ...'
fastmcp 4.0.9    redis 8.1.0    ddgs 9.16.1
```

`fastmcp` matches the reviewed pin `fastmcp==4.0.9` exactly.

## 5. Part 2 proof — the one-command install path

**Verdict, one line:** the install path produces **the same image** as `bin/up.sh`
(both exported image manifest `sha256:b96404e88b8a…` from one identical tree), and
after this change it no longer manufactures an unpinned `hermes-agent:latest` base
or force-tag its output `sudo-agent:latest`.

What the install path is: root `setup.sh` (command 1) does
`printf '%s\n' "$DEEPSEEK_API_KEY" | $SUDO bash "$AGENT_REPO/setup.sh"`, i.e. it lands
on `factories/sudo-agent/setup.sh`. That script had its own build, independent of
`bin/up.sh`, at line 63:

```
$ git show HEAD:factories/sudo-agent/setup.sh | sed -n '51,64p'
if ! docker image inspect hermes-agent:latest &>/dev/null; then
  echo "→ Building base Hermes Agent image (3-5 min)..."
  ...
  _retry 3 "docker build hermes-agent" docker build -t hermes-agent:latest "$TMP_DIR" \
    || { echo "Docker build failed."; exit 1; }
  ...
fi
echo "→ Building sudo-agent image..."
_retry 3 "docker build sudo-agent" docker build -t sudo-agent:latest -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR" \
```

Two defects, both fixed:

1. **Lines 51-60 — a second, unpinned base.** On any host without a local
   `hermes-agent:latest` it cloned upstream's *default branch* and built it: a
   3-5 minute build of an image no pod runs, and a base that tracks upstream rather
   than the pin. The `FROM` it produced was never used, because the Dockerfile's
   `FROM` is qualified.
2. **Line 63 — the tag was hardcoded.** The build could only ever land on
   `sudo-agent:latest`. That is the right tag for a user's first install, and it is
   a live hazard on any host that already runs agents against it
   (`imagePullPolicy: IfNotPresent` means a re-pointed tag silently changes what the
   *next* pod recreation runs). It is now `SUDO_AGENT_IMAGE`, defaulting to
   `sudo-agent:latest`, so the documented behaviour is unchanged and the build can
   be verified without touching the live tag.

Both paths were then built from **one fixed tree** (a byte-identical copy of the
factory, so the repo could not change under the test — another engineer was editing
`comm/` at the time), with `kubectl` deliberately off `PATH` so `setup.sh` could not
reach the live cluster's Redis block:

```
=== A: install path (real setup.sh) -> sudo-agent:p2a-eq-install ===
setup.sh rc=0
→ Building sudo-agent image (sudo-agent:p2a-eq-install)...
#22 naming to docker.io/library/sudo-agent:p2a-eq-install done
⚠ No reachable Kubernetes cluster (kubectl missing, or 'kubectl cluster-info' failed).

=== B: deploy path (real up.sh _ensure_image_built) -> sudo-agent:p2a-eq-deploy ===
build rc=0
#2 [internal] load metadata for docker.io/nousresearch/hermes-agent:v0.22.5
#22 naming to docker.io/library/sudo-agent:p2a-eq-deploy done

=== layer lists ===
IDENTICAL layer digest lists (53 layers) - same image content

=== baked content, file by file ===
--- sudo-agent:p2a-eq-install   --- sudo-agent:p2a-eq-deploy
/opt/comm        86ecacba…      /opt/comm        86ecacba…
/opt/comm-tools  bcc94957…      /opt/comm-tools  bcc94957…
/opt/comm-skills 141faedf…      /opt/comm-skills 141faedf…
/opt/meta-data   2bf28a8c…      /opt/meta-data   2bf28a8c…
/opt/hermes-mcp  c2eb00d2…      /opt/hermes-mcp  c2eb00d2…
hermes           v0.22.5        hermes           v0.22.5
patch-marker     0              patch-marker     0
```

A first pass appeared to differ on `/opt/comm` only; the cause was not the build
path — `comm/PERSONA-SNIPPET.md` changed in the checkout between the two runs
(2527 → 4195 bytes, another engineer's edit). The fixed-tree pass above removes
that race, which is why it is the evidence of record. The final `sudo-agent:p2a-h1`
was then rebuilt from the checkout as it stands and carries that same manifest
digest, i.e. the image h2 deploys is the image this test proved equal.

One honest limit: this proves the two paths agree **for the build**. It does not
prove the whole three-command install works on a bare box (k3s install, Letta
factory, key prompts) — that is not my brief and I did not run it, on this host or
any other, because running it means installing a cluster and deploying agents.

## 6. The fleet did not move

Captured before the first build and after the last one, same command, read-only:

```
kubectl get deploy -A -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.spec.template.spec.containers[*].image}{"\n"}{end}' | sort
```

```
before: 103 lines, 60 deployments referencing sudo-agent:latest
after:  103 lines, 60 deployments referencing sudo-agent:latest
$ diff before after
(empty)  -> FLEET UNCHANGED

$ docker image inspect sudo-agent:latest --format '{{.Id}} {{.Created}}'
sha256:16d149ddf0f2d8f9fcbf6bd94447d6790104660e98f7f32c9b46b120bd1b4bca
2026-10-18T23:12:48.943195417-07:00     (identical before and after)
```

Every build in this brief was tagged `sudo-agent:p2a-h1` or `sudo-agent:p2a-*`
helper tags that were deleted afterwards. `sudo-agent:latest` was never a build
target, was never imported, and no deployment, pod, replica count or containerd
image was touched. The throwaway tags left on the daemon are `sudo-agent:p2a-h1`
(the image h2 deploys) and h4's Phase 1 `sudo-agent:p1-build-h4d`.

**I deployed nothing, restarted nothing, scaled nothing, exec'd nothing, and
touched no running agent.**

## 7. What I changed that was not in my file list

`bin/k8s-auto-up.sh` — **one line**, and it is the blast radius of the removal
above, not scope creep. That script runs on every boot (durability unit) and loops
over `hermes-agent:latest sudo-agent:latest sudo-letta:latest` re-importing each
into containerd. With the base no longer built, a fresh install would print
`⚠ hermes-agent:latest missing from both containerd AND docker — rebuild with
setup.sh` on every single boot, forever, pointing at an image nothing runs. The
line now lists only the two images pods actually run. No other file in the repo
references `hermes-agent:latest` outside `glimors/` (vendored agent workspaces, not
the build path) and the doc prose h5 owns.

## 8. Deliberately not changed

- **`factories/sudo-agent/Dockerfile`** — untouched, byte-identical to what Phase 1
  validated (`4e9b190e6ad7…`). It was already correct; the code around it was not.
- **The `IMAGE_SHA` guard** — untouched apart from one stale comment clause. It is
  the mechanism that rolls a pod when the image *content* changes, and deleting or
  weakening it would recreate the "deploy that lies about what it shipped" defect.
- **`setup.sh`'s config.yaml heredoc** — left exactly as Phase 1 aligned it
  (`memory_char_limit: 40000`, `user_char_limit: 20000`). Verified by reading, not
  edited; `config.yaml` and `comm/` belong to another engineer this phase.
- **`setup.sh`'s Redis provisioning block** — untouched. It is why the Part 2 test
  ran with `kubectl` off `PATH`: on this host that block would have run the
  cluster's shared-Redis provisioning script, which is live-fleet territory.
- **The stale `hermes-agent:latest` copy in containerd** — left alone. It is unused,
  harmless, and removing it is a containerd mutation I was not asked to make.
- **Docs, either README, `config.yaml`, `comm/`, plugin directories** — other
  engineers hold them this phase.

## 9. Disagreements and follow-ups for the lead

1. **`02-PHASE-2-PLAN.md` describes a different Phase 2.** That document says Phase
   2 is "roll the image onto all 60 Hermes deployments, archive legacy memory per
   agent", with an owner map splitting 60 agents across h1-h5 and a canary sequence.
   This brief says Phase 2 is "make the repo able to produce a running, tested agent",
   and explicitly forbids touching any of those agents. I followed the brief. The
   plan document should be corrected or clearly marked as superseded, or the next
   reader will think this phase's output is missing.
2. **`factories/sudo-agent/README.md:158` still names `patch_memory_review.py`**
   (already flagged in Phase 1's h1 report as F3). That file no longer exists. Not
   mine this phase — it is doc prose.
3. **Image snapshot date matters.** `sudo-agent:p2a-h1` was built at 19:22Z from
   `comm/` as it stood then (`PERSONA-SNIPPET.md` sha256 `7c1420eb…`). If `comm/` or
   the plugins change after that, the image must be rebuilt before it is deployed —
   the rebuild is one command and changes nothing about the tag:
   `SUDO_AGENT_IMAGE=sudo-agent:p2a-h1 bash factories/sudo-agent/setup.sh` (with
   `kubectl` off `PATH` on a live fleet host) or the `_ensure_image_built` path
   `up.sh` uses.
4. **`docker build` emits a warning** on every build:
   `SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SUDO_PASSWORD")` at
   `Dockerfile:91`. The value is empty (`ENV SUDO_PASSWORD=""`), so it is not a leak,
   but a stranger's first build ends on a warning about secrets. Worth a look in a
   later pass; not worth touching a validated Dockerfile this phase.

## Addendum — the deploy path now honours SUDO_AGENT_IMAGE

Owner: `sudo-fleet-glm-h4` · Phase 2 · 2026-10-28 (UTC) · branch `main`
Code under report: `factories/sudo-agent/bin/up.sh` (on `main` as `a6abd1e`, corrected by
`70f207a`). This addendum is the verification for that change; no other file was touched.

### A1. The defect

The two halves of one build/deploy step disagreed. The **install** path honoured the
override: `factories/sudo-agent/setup.sh:60` is
`AGENT_IMAGE="${SUDO_AGENT_IMAGE:-sudo-agent:latest}"` and `setup.sh:63` is
`docker build -t "$AGENT_IMAGE" …`. The **deploy** path did not: `bin/up.sh` hardcoded
`sudo-agent:latest` in nine places, four of them `image:` lines in the generated manifest.
So `SUDO_AGENT_IMAGE=sudo-agent:candidate bash factories/sudo-agent/setup.sh` built and
tagged a candidate correctly, and the plain `bash factories/sudo-agent/bin/up.sh --<name>`
that followed deployed **`:latest`**, not the candidate. The only way to ship the candidate
was to re-point the shared tag that 59 live deployments reference — the one thing the
override exists to avoid.

### A2. The nine executable sites (pre-edit literal → post-edit variable)

Pre-edit column is `git show a6abd1e^:factories/sudo-agent/bin/up.sh`, post-edit is `HEAD`.

| # | Site | Pre-edit (`a6abd1e^`) | Post-edit (`HEAD`) | Why |
|---|---|---|---|---|
| 1 | resolution | *(absent)* | `:61` `AGENT_IMAGE="${SUDO_AGENT_IMAGE:-sudo-agent:latest}"` | one source of truth for every site below |
| 2 | image-content digest | `:571` `docker image inspect sudo-agent:latest --format '{{.Id}}'` | `:578` `… inspect "$AGENT_IMAGE" …` | the digest pinned into the `sudo-agent/image-sha` annotation must be the digest of the image actually deployed |
| 3 | that guard's error text | `:573`, `:575` quote the tag | `:580`, `:582` interpolate `$AGENT_IMAGE` | a failure message must name the image that was attempted, not a different one |
| 4 | `seed-glimor` initContainer | `:705` `image: sudo-agent:latest` | `:712` `image: $AGENT_IMAGE` | manifest heredoc is unquoted → expands |
| 5 | `seed-soul` initContainer | `:733` `image: sudo-agent:latest` | `:742` `image: @AGENT_IMAGE@`, substituted at `:756` | this heredoc is **quoted** (`<<'SEEDSOUL'`), so a bare `$AGENT_IMAGE` would reach the manifest literally; the placeholder is substituted once after |
| 6 | agent container | `:922` `image: sudo-agent:latest` | `:932` `image: $AGENT_IMAGE` | the container the deploy exists to run |
| 7 | `watch` sidecar | `:1026` `image: sudo-agent:latest` | `:1036` `image: $AGENT_IMAGE` | sidecar must run the same build as the agent |
| 8 | `_assert_image_fresh` | `:1378` `local img="sudo-agent:latest"` | `:1397` `local img="$AGENT_IMAGE"` | freshness/digest check must inspect the deployed image |
| 9 | `_import_image` | `:1426` `_import_image sudo-agent:latest` | `:1445` `_import_image "$AGENT_IMAGE"` | import into containerd what the pod will run |

After the change, `grep -n 'sudo-agent:latest' factories/sudo-agent/bin/up.sh` returns
exactly four lines, and all four are legitimate: `:57` and `:568` and `:1291` are comments
that name the *default*, and `:61` **is** the default itself
(`${SUDO_AGENT_IMAGE:-sudo-agent:latest}`). Zero occurrences remain in YAML template text
or in a `docker`/`kubectl` argument — the stub logs in A3 show the argv each one actually
receives.

Site 5 also has a backstop for the whole class: `_manifest_check` (`:1248`–`:1285`) refuses
to apply a generated manifest whose `image:` line still contains a literal `$`, so an
unexpanded variable aborts the deploy instead of shipping a pod that can never start.

### A3. The default is unchanged, byte for byte

`SUDO_AGENT_IMAGE` is a *build* variable that `up.sh` also honours, not a required deploy
parameter. With it unset, the deploy must behave exactly as before, and it does — measured,
not asserted.

Syntax:

```
$ bash -n factories/sudo-agent/bin/up.sh
SYNTAX-OK
```

Default behaviour, proven byte-for-byte: the same copy, the same stubbed `docker`/
`kubectl`/`k3s`, the same arguments, `SUDO_AGENT_IMAGE` unset in both runs — once with
`up.sh` as at `HEAD`, once with `up.sh` as at `a6abd1e^` (the pre-override file). The
generated manifest is the comparison, because that is the artifact the cluster receives:

```
$ sha256sum manifest-pre.yaml manifest-head.yaml
8d4c8d8c2e155affe918930faf48a4f78a5217ec4a471c27148ffce89515c7a1  manifest-pre.yaml   # up.sh @ a6abd1e^
8d4c8d8c2e155affe918930faf48a4f78a5217ec4a471c27148ffce89515c7a1  manifest-head.yaml  # up.sh @ HEAD
$ diff -u manifest-pre.yaml manifest-head.yaml
(empty)  -> BYTE-FOR-BYTE IDENTICAL
```

Image resolution, both branches, from the same harness (functions exercised against stub
`docker`/`kubectl` that log their argv; the run stops at the image-digest check, before
`_import_image` and long before `kubectl apply` — the stub logged `kubectl` argv exactly
once, a read-only `get deploy`, and zero `apply`):

```
SUDO_AGENT_IMAGE unset
  docker image inspect sudo-agent:latest --format {{.Id}}          <- argv seen by the stub
  rendered manifest:  image: sudo-agent:latest        (:98, :202)

SUDO_AGENT_IMAGE=sudo-agent:candidate-x
  docker image inspect sudo-agent:candidate-x --format {{.Id}}     <- argv seen by the stub
  rendered manifest:  image: sudo-agent:candidate-x    (:98, :202)
```

The fleet did not move. Read-only, same command before the work and after it:

```
kubectl get deploy --no-headers -o custom-columns=N:.metadata.name,I:.spec.template.spec.containers[0].image
  | awk '{print $2}' | sort | uniq -c
```

```
before                                     after
      1 iji-vm:latest                            1 iji-vm:latest
      5 node:22-bookworm                         5 node:22-bookworm
      2 redis:7-alpine                           2 redis:7-alpine
     59 sudo-agent:latest                       59 sudo-agent:latest
      1 sudo-agent:p2a-h1                        1 sudo-agent:p2a-h1
      1 sudo-gws:latest                          1 sudo-gws:latest
     23 sudo-letta:latest                       23 sudo-letta:latest

$ docker image inspect sudo-agent:latest --format '{{.Id}} {{.Created}}'
sha256:16d149ddf0f2d8f9fcbf6bd94447d6790104660e98f7f32c9b46b120bd1b4bca 2026-10-18T23:12:48.943195417-07:00
(identical before and after — 59 deployments, same image ID)
```

No image was built, tagged, retagged or imported; `sudo-agent:latest` was never a build
target; nothing was deployed, restarted, scaled or applied. The harness ran against a copy
of `factories/sudo-agent` under `/tmp`, with `redis-up.sh` (a live provisioner) stubbed to
a no-op **in that copy only** so the harness could not reach the cluster.

### A4. What is proven, and what is not

**Proven, at script level:** the override reaches every one of the nine sites; with it
unset the generated manifest is byte-identical to the pre-change script's; `bash -n` is
clean; the fleet and the tag's image ID are unchanged.

**Correcting the scope line I was briefed with.** This addendum was briefed to say the
generated pod manifest "omits the container `image:` field", so that `:932` never reaches
the cluster. That is not what the script does, and it is worth recording rather than
copying forward: the manifest heredoc at `up.sh:834` is `cat > "$YAML" <<YAMLEOF` — an
**unquoted** delimiter — so `$AGENT_IMAGE` is expanded at generation time, and the manifests
rendered in A3 carry `image: sudo-agent:latest` and `image: sudo-agent:candidate-x` at both
container sites. `_manifest_check` (`:1272`) exists precisely because any surviving literal
`$` on an `image:` line is fatal. The live object agrees: the pod template of a running
deployment reports `containers[].image: sudo-agent:latest` for both the agent and the watch
container. So the field is present, expanded, and is what selects the *tag*. What the
`sudo-agent/image-sha` pod-template annotation does is a different job: with
`imagePullPolicy: IfNotPresent`, a rebuild under the **same** tag does not roll the pod, so
the annotation is what makes an image-content change recreate it.

**Not proven — end to end at the cluster level.** The override is verified at the *script*
level only. No deploy was run against the live fleet: rendering a manifest is proven,
`kubectl apply` of a candidate image onto a real agent is not, and doing that against a live
deployment is out of scope this phase. The honest status is: script-level proof complete,
cluster-level proof absent by design.

### A5. Residual: `_ensure_image_built`

Checked, and it is **not** a residual. `_ensure_image_built` (`:1349`) takes the image name
as `$1` (`local img="$1"`) and builds `docker build -t "$img" -f "$REPO_DIR/Dockerfile"
"$REPO_DIR"`; both callers pass the resolved variable — `_import_image` at `:1445` and
`_assert_image_fresh` via `local img="$AGENT_IMAGE"` at `:1397`. It builds under
`$AGENT_IMAGE`, never unconditionally under `sudo-agent:latest`. The A3 stub log confirms it:
with the override set, the build-on-missing path would have run against
`sudo-agent:candidate-x`, and no `sudo-agent:latest` appears in that run's argv at all.

One consequence worth naming, not fixed: build-on-missing means a *mistyped* override
silently turns a deploy into a full image build and then deploys the accidental tag, rather
than failing on an unknown name. That behaviour is unchanged from before this work (it was
already true of the `:latest` default) and changing it would alter default behaviour, so it
is reported rather than implemented.
