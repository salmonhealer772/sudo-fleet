# P2-B — the sandbox agent survives the image upgrade

**Phase 2, brief B.** One live agent was recreated in place onto the new image: `sudo-mail-bot-hermes`
in `default`. Nothing else in the cluster was deployed, restarted, scaled or deleted. 103 deployments
existed before and after, and the deployment→image map differs on exactly one line — this one.

Owner: sudo-fleet-glm-h2 · Date: 2026-10-28 (UTC) · Sandbox: one bot agent, PVC `local-path` 10Gi.

---

## 1. The three verdicts

| Verdict | Result | What proved it |
|---|---|---|
| **Did the new image RUN?** | **YES** | Pod `2/2 Running`, 0 restarts, `hermes --version` → `v0.22.5`, patch marker **0**, `find / -name patch_memory_review.py` → 0 hits, `background_review.py` 1364→**1349** lines |
| **Did the agent KEEP ITS PAST?** | **YES** | `state.db` unchanged at **78,569,472 bytes**, **411 sessions / 6,344 messages**, `schema_version` **32**, `integrity_check` **ok**, and a `session_search` inside the new pod returns real **September 2026** sessions. SOUL still the agent's own; 18 skills intact |
| **Is the new budget live?** | **YES** | `/opt/data/config.yaml` inside the pod reads `memory_char_limit: 40000` / `user_char_limit: 20000`; a real turn wrote a **115-character** entry at 19:41Z |

| | |
|---|---|
| Pod (after) | `sudo-mail-bot-hermes-66f565699b-lrfsz` — 2/2 Running, restarts **0** |
| Image the pod runs | tag `sudo-agent:p2a-h1` · containerd `imageID sha256:2003be5c…` · `repoTags: [docker.io/library/sudo-agent:p2a-h1]` · size **1,075,095,906** |
| Image the tag holds (docker) | `sha256:ebc56f72e84a2342b59344fdb413534e998420b69c0b12ea7e6b504ed63edbf9` — **identical to h1's marker** |
| Version | `Hermes Agent v0.22.5 (2026.9.24) · upstream bf0203a7` (`2026.9.24` is the internal semver epoch, not the base version) |

**Bottom line for the propagation job:** the image opens an existing agent's real store without a
migration, the agent comes back as itself, and the new behaviour (the memory contract) reaches an
*existing* PVC — through the persona block, not the skill seed. §7 has the consequence for the fleet.

---

## 2. The dependency I waited on

h1's `P2A-DONE.txt` appeared at **19:31:42Z**; I began polling at 19:16:50Z every 90 s (5 checks) —
about **15 minutes**, well inside the 45-minute budget. First check at 19:24 showed only build logs;
the marker carried:

```
TAG:      sudo-agent:p2a-h1
IMAGE ID: sha256:ebc56f72e84a2342b59344fdb413534e998420b69c0b12ea7e6b504ed63edbf9
Created:  2026-10-28T12:22:56-07:00 (19:22:56Z)
Size:     1,075,095,906 / 53 layers
Base:     nousresearch/hermes-agent:v0.22.5@sha256:9c5561579f3f…
```

One thing the marker could not tell me: the tag was **re-pointed mid-phase**. At 19:23 the tag held
`b2ed8ad33a29`; h1 rebuilt and by 19:31 it held `ebc56f72e84a`. My first run of the copy test
therefore measured `b2ed8ad33a29`; **every measurement in §4 was re-run against `ebc56f72e84a`**, and
§4's figure is the final one. Anyone re-reading this should treat `ebc56f72e84a` as the image of record.

---

## 3. Before: the state of the agent, verbatim

Captured before any change. Deployment spec kept out of the repo (it carries live env); the numbers
below are the actionable part.

| Measure | Value |
|---|---|
| Pod | `<name>-cc98c89b7-z48n6`, 2/2 Running, **52 restarts**, age 16d |
| Image | `sudo-agent:latest` (docker `sha256:16d149ddf0f2…`) |
| `hermes --version` | `vunknown (2026.9.24)` — the drift |
| `MEMORY.md` | **100,217 bytes**, 2026-10-06 |
| `USER.md` | **50,222 bytes**, 2026-09-24 |
| `state.db` | **78,569,472 bytes**, 43 tables, **411 sessions**, **6,344 messages**, `schema_version` **32**, `integrity_check` **ok**, messages spanning **2026-08-24 → 2026-10-19** |
| `SOUL.md` | 7,891 bytes, md5 `721754026f924d2079a37f0d323c6d22` |
| `skills/` | **18** directories |
| `.comm-seeded` | present, **2026-09-30** |
| `/opt/data` | 332 top-level entries, 582 MB |
| Per-agent config | `memory_char_limit: 100000`, `user_char_limit: 50000` (the old budget) |

### 3.1 STEP 1b — the per-agent config still carried the old budget

`up.sh` seeds `config/<name>.yaml` from the tracked template **once** and then leaves it alone, so a
template change never reaches an existing agent. The sandbox's own file still had 100000/50000. Fixed
in that one file only — the two numbers, nothing else:

```diff
 memory:
-  memory_char_limit: 100000
-  user_char_limit: 50000
+  memory_char_limit: 40000
+  user_char_limit: 20000
   memory_enabled: true
```

Proof the change is confined to those two lines: stripping both `*_char_limit` lines from the before
and after files gives the same md5 (`39af0f019309c12ad867a6dd7bf4f35f`) — model, provider, display
skin, plugin list, `stream_reasoning_deltas`, `_config_version` and the api_server port all survive
byte-identically. The file is gitignored instance material (`factories/sudo-agent/.gitignore:3`) and
is **not** committed.

### 3.2 F-A confirmed: no schema migration on either side

```
new image  $ grep -E "^SCHEMA_VERSION|^FTS_STORAGE_VERSION" /opt/hermes/hermes_state_common.py
           SCHEMA_VERSION = 32
           FTS_STORAGE_VERSION = 3
old image   (docker run --entrypoint sh sudo-agent:latest …)
           SCHEMA_VERSION = 32
           FTS_STORAGE_VERSION = 3
live db    select version from schema_version  ->  32
```

The brief's F-A reproduces on all three. On this axis the base bump is schema-neutral, and §4/§5 show
it behaving that way against real data rather than by inference.

---

## 4. The "same self" test on a COPY — the part that could have gone wrong

**Method.** The PVC is a plain directory (`local-path`), so it was copied with `cp -a` to
`/tmp/p2-selfcopy` **before anything was changed** — a copy taken prior to the memory archive, i.e. the
most faithful donor available. The pod was not stopped; that is the one weakness of the method and it
is stated here deliberately: a live SQLite copy can be torn. It was not:

| Check on the copy | Result |
|---|---|
| Size / entry count | 570 MB, **341 names** — identical listing to the pod's `/opt/data` (341), `comm` on the two sorted lists empty |
| `state.db` opens read-only | yes — `schema_version` **32**, **43** tables, **411** sessions, **6,344** messages |
| `pragma integrity_check` | **ok** (no tear) |
| `SOUL.md` md5 | `721754026f924d2079a37f0d323c6d22` — identical to the pod's |

**Then the new image was run against that copy** — a plain `docker run`, no cluster involved, the
copy bind-mounted at `/opt/data`, `HERMES_HOME=/opt/data`, `--network none`:

```
docker run --rm --network none -e HERMES_HOME=/opt/data \
  -v /tmp/p2-selfcopy:/opt/data -v /tmp/p2probe:/probe:ro \
  --entrypoint /opt/hermes/.venv/bin/python sudo-agent:p2a-h1 /probe/probe.py
```

The probe calls the product's own recall path (`tools.session_search_tool.session_search`), not raw
SQL — `db=None` makes it open `<HERMES_HOME>/state.db` exactly as an agent turn would:

```
HERMES_HOME = /opt/data
requirements_ok = True
 "success": true,
   "when": "October 06, 2026 at 04:29 AM",
   "when": "September 08, 2026 at 09:54 AM",
   "when": "September 06, 2026 at 06:35 AM",
 "count": 3,
 "sessions_searched": 3,
=== image id used ===
sha256:ebc56f72e84a2342b59344fdb413534e998420b69c0b12ea7e6b504ed63edbf9
```

Real, old, dated content — not an empty result, and not a fresh store. Same image:

```
$ hermes --version            Hermes Agent v0.22.5 (2026.9.24) · upstream bf0203a7
$ grep -c "PROGRAMMATIC AUTO-SAVE" background_review.py   0
$ wc -l background_review.py                              1349
$ find / -name patch_memory_review.py | wc -l             0
```

**SOUL is the agent's own, not the stock one.** Copy md5 == pod md5 (`721754026f92…`), and neither
equals the stock seed md5 (`1aec3b727511f093344188de159a77ca`).

*Honest limit:* `hermes -z` against the copy stops at the config gate ("no API keys or providers
found") because the copied `config.yaml` is an empty 0-byte placeholder — the key is injected as pod
env at deploy time, never stored on the PVC. So the copy test proves the CLI boots, the store opens
through the product path and history reads back; a full model turn was exercised on the live pod
instead (§6), which is the stronger venue for it.

**Cleanup:** `/tmp/p2-selfcopy` deleted (§10). The original was never modified by this test.

---

## 5. The recreate

### 5.1 A real blocker, and the one-line change it needed

The brief says to recreate through `factories/sudo-agent/bin/up.sh` on the throwaway tag, and forbids
re-pointing `sudo-agent:latest`. **`up.sh` could not do both.** It hardcoded the tag in nine places
(`IMAGE_SHA` inspect, four manifest `image:` lines, `_assert_image_fresh`'s local, `_import_image`,
plus two messages), and `SUDO_AGENT_IMAGE` existed only in `setup.sh`. The only alternatives were
re-pointing the live tag (forbidden, and D9 — 60 deployments reference it) or `kubectl set image`,
which changes no env, volume or secret and would not test the deploy path at all.

I asked h1 (owner of the file) for a supported invocation or an override, twice, and got no reply
before I had to proceed. **I then made the minimal change myself** — `AGENT_IMAGE="${SUDO_AGENT_IMAGE:-
sudo-agent:latest}"`, used at those call sites. Default behaviour when unset is byte-for-byte what it
was, so nothing about the 60 live agents changes; it is what let this phase deploy a throwaway tag at
all. `bash -n` clean. It is committed with this report (see §9), and `docs/P2-A-DEPLOY-PATH.md`'s
`SUDO_AGENT_IMAGE` claim is now true of the deploy path as well as the installer.

⚠ **Split authorship, disclosed:** the worktree `up.sh` also carried a **jq guard** written by h1
(added before 19:36:11Z, present in my pre-deploy snapshot, not in `HEAD`). I did **not** write it and
I did not stage it: my commit was built from `HEAD` plus my hunk only, via
`git show HEAD:path | patch | git hash-object -w | git update-index --cacheinfo`, precisely so h1's
uncommitted work could not be swept into my commit. h1's guard is still in the worktree, untouched,
for h1 to commit.

### 5.2 The command, verbatim

`up.sh` was frozen to a snapshot inside `bin/` first (`sha256 38d997c18c15…`) because h1 was editing
the same file concurrently and a shell reads its script incrementally — a comment change mid-run is a
real hazard. The snapshot is deleted; the command below is the one that ran:

```
cd /opt/0-0/sudo-fleet/factories/sudo-agent && \
KUBECONFIG=/etc/rancher/k3s/k3s.yaml SUDO_AGENT_IMAGE=sudo-agent:p2a-h1 \
  bash bin/.up-p2b-snapshot.sh --mail-bot-hermes
```

Exit 0. The script did what the deploy path is supposed to do, and said so:

```
→ sudo-agent image digest: sha256:ebc56
→ Writing …/deployments/mail-bot-hermes.yaml...
→ Importing images...
deployment "sudo-mail-bot-hermes" successfully rolled out
   sudo-watch-stream hooks: on_stream_start=1 on_stream_delta=1 on_stream_end=1
                            pre_api_request=1 post_api_request=1 pre_tool_call=2 post_tool_call=1
   sudo-comm-gate hooks: on_skill_lifecycle=1
✓ sudo-mail-bot-hermes deployed
```

The hook verification is `up.sh`'s own gate — it fails the deploy if any of the eight callbacks is
missing, so the tape and the gate could not have gone dark silently here.

---

## 6. After: healthy, current, and still itself

| Check | Result |
|---|---|
| Pod | `2/2 Running`, **restarts 0** (was 52), ready `true true` |
| Deployment image | `sudo-agent:p2a-h1` (both containers) |
| Pod `imageID` | `sha256:2003be5c…`, `repoTags: [docker.io/library/sudo-agent:p2a-h1]`, size **1,075,095,906** — the same size and tag as h1's marker, whose docker ID is `ebc56f72…` |
| `hermes --version` (in pod) | `v0.22.5 (2026.9.24) · upstream bf0203a7` |
| Patch marker (SPACE form) | **0** ; `background_review.py` **1349** lines (old: 1364, marker 1) |
| `find / -name patch_memory_review.py` | **0** hits |
| `state.db` | **78,569,472 bytes**, 43 tables, **411 sessions**, **6,344 messages**, `schema_version` **32**, `integrity_check` **ok** |
| `session_search` in the pod | `success: true`, `count 3`, hits dated **Sep 06 / Sep 13 2026** |
| `SOUL.md` | 9,559 bytes, md5 `62e1be7a40585e729c2704b8c19ef77c` — the original 7,891 bytes **plus 13 added lines, all inside the FLEET-COMM managed block** (§7) |
| `skills/` | **18** — unchanged |
| `.comm-seeded` | present, still **2026-09-30** — never cleared |
| Budget (from `/opt/data/config.yaml` in the pod) | `memory_char_limit: 40000`, `user_char_limit: 20000` |

**This is the proof the phase needed:** the same `state.db` (byte-size identical, not merely
same-count), opened by the new binary, with no migration error, and old October/September sessions
readable through the agent's own recall tool.

### 6.1 Memory now accepts writes, and the entry is the right shape

One real turn on the live pod (`hermes -z`, a durable environmental fact, not a dumped prompt):

```
$ ls -la /opt/data/memories/
-rw-r--r-- 1 hermes hermes 115 Oct 28 19:41 MEMORY.md
-rw------- 1 hermes hermes   0 Oct 28 19:41 MEMORY.md.lock

$ cat /opt/data/memories/MEMORY.md
Sandbox agent recreated on Hermes v0.22.5 (28 Oct 2026); legacy memory store archived at /opt/data/memories-legacy.
```

**115 characters, one entry, mtime now.** The old store's failure mode was 34 entries averaging
**2,850** characters, full and silently refusing writes for nine days; this is one fact, in the
100–300-character band the contract asks for. The writer runs and the shape is right — on the new
image, on the new budget. (`USER.md` was not written by this turn, which is correct: the turn was
about the environment, not the operator.)

### 6.2 The archive (STEP 2)

```
before:  MEMORY.md 100217 (Oct 6 04:39)  USER.md 50222 (Sep 24 20:53)  + two 0-byte .lock files
after:   /opt/data/memories/            -> empty
         /opt/data/memories-legacy/     -> MEMORY.md 100217, MEMORY.md.lock 0,
                                           USER.md 50222, USER.md.lock 0
```

Sizes match the originals exactly; both directories are on the same PVC. Nothing was deleted.

**Disclosure:** the move was executed at 19:33:03Z by a *second concurrent conversation of this same
agent* (see §8), a few seconds before my own archive command ran — same pod, same PVC, same result. I
verified the four files and their sizes independently rather than assume it. Functionally STEP 2 is
complete and correct; the interference is §8's problem, not the archive's.

---

## 7. Did h3's memory instruction reach the PVC?

**YES — via the persona block, not the skill seed.** h3 chose the FLEET-COMM managed block in
`comm/PERSONA-SNIPPET.md`, re-applied to `/opt/data/SOUL.md` by `mcp_entrypoint.sh` on every container
start.

```
$ diff pre-upgrade SOUL.md  post-upgrade SOUL.md     ->  13 lines, all additions
@@ -63,4 +63,17 @@
+## Your memory
+ Your memory is a small notebook you keep by hand, not a log of what you did…
+ Save: a durable fact about your environment, a convention, a correction your operator gave you…
+ Do not save: the text of a task, the brief you were handed, another agent's message…
+ One entry is one fact — a sentence or two, roughly 100–300 characters…
 <!-- FLEET-COMM-AWARENESS-END -->
```

The pre-existing text is untouched; the only change is inside the managed block. **No
`/opt/data/.comm-seeded` surgery, no PVC edit, no per-agent config change** was needed for this — which
matters, because the skill route would *not* have worked:

> **The skill seed is first-boot-only.** `comm/` is copied into `/opt/data/skills/` once, guarded by
> `/opt/data/.comm-seeded`, which on this agent is dated **2026-09-30** and still present after the
> recreate. A newly added *skill* in the image therefore reaches **nobody** on a plain recreate of an
> existing agent — the marker protects the agent's own 18 skills, and it also blocks the seed. The
> persona block is the only route that lands on an existing PVC, because the entrypoint rewrites it
> every boot. That is the mechanism the propagation job must rely on for anything it wants delivered to
> agents that already have a past; anything shipped as a skill needs a separate, deliberate delivery
> step.

---

## 8. What broke, what was odd, and what I could not avoid

1. **`up.sh` could not deploy a throwaway tag** (§5.1) — the phase's own design gap. Fixed minimally,
   disclosed, committed. Without it there is no way to test a candidate image against one agent without
   poisoning the tag 60 agents share.
2. **Two concurrent conversations of this agent ran the same brief.** A second conversation
   (`local-54aa75…`, distinct from this one) was executing brief B in the same pod on the same host:
   it archived the memory at 19:33:03 (§6.2), and it was probing the same `up.sh` gap at the same time.
   I detected it from the agent's own trail and worked around it — my deploy ran from a frozen snapshot
   of `up.sh`, my commit was built from `HEAD` + my hunk only, and every number in this report is one I
   measured myself after the fact. **This is a fleet-level hazard worth fixing**: one pod, one brief,
   two hands, and a `git` checkout shared by five engineers is one `git add` away from a commit that
   contains someone else's work.
3. **h1 was still editing `up.sh` while I deployed** (its jq guard, §5.1). Handled by the snapshot. The
   guard was still uncommitted when I finished; it is h1's to commit.
4. **`up.sh` also re-synced the shared `openrouter-api-key` Secret** from the fleet `.env` (its
   documented, idempotent behaviour). Its `creationTimestamp` is 2026-10-02, i.e. not created by me; I
   did not snapshot its resourceVersion beforehand, so I cannot prove the value was unchanged — only
   that the source (the fleet `.env`) did not change. Declared rather than glossed.
5. **`up.sh` also rewrote the per-agent config** with its own keys: `platforms.api_server.enabled: true`
   and an `mcp_servers` block (4 servers). That is what the deploy path does on every deploy; it is
   instance material and not committed. The memory block still reads 40000/20000 afterwards.
6. **A Paperclip auto-hire ran** as part of the same deploy — it REUSED the existing Paperclip agent
   (no new agent created) and re-injected the `PAPERCLIP_*` env vars the deploy had just preserved.
   Declared because it is a side effect of `up.sh`, not of this brief.

**No other deployment, pod, PVC, service or tag moved.** Proof: the deployment→image map for all 103
deployments, before vs after —

```
$ diff fleet-before.txt fleet-after.txt
60c60
< <sandbox>=|sudo-agent:latest sudo-agent:latest
---
> <sandbox>=|sudo-agent:p2a-h1 sudo-agent:p2a-h1
```

and `sudo-agent:latest` is still `sha256:16d149ddf0f2…` (2026-10-18) untouched. The shared Redis was
a genuine no-op: `sudo-agent-redis` `resourceVersion` **1002953**, `generation` **3** — identical
before and after — and its pod's restart count unchanged at 6.

---

## 9. The up.sh change, in full

`factories/sudo-agent/bin/up.sh` — 25 insertions, 9 deletions, no restructuring, default unchanged:

```diff
 PER_AGENT_CONFIG="$CONFIG_DIR/$NAME.yaml"
+# The image this deploy runs and imports. Defaults to the historical
+# `sudo-agent:latest`, … the override exists so a throwaway build … can be
+# deployed … WITHOUT re-pointing the tag that a fleet of running agents shares.
+AGENT_IMAGE="${SUDO_AGENT_IMAGE:-sudo-agent:latest}"
@@
-IMAGE_SHA="$(docker image inspect sudo-agent:latest --format '{{.Id}}' 2>/dev/null)"
+IMAGE_SHA="$(docker image inspect "$AGENT_IMAGE" --format '{{.Id}}' 2>/dev/null)"
-        image: sudo-agent:latest          (x4: agent container, watch container,
+        image: $AGENT_IMAGE                    the two seed initContainers)
-  local img="sudo-agent:latest" want got
+  local img="$AGENT_IMAGE" want got
-_import_image sudo-agent:latest
+_import_image "$AGENT_IMAGE"
```

`bash -n up.sh` → clean (real bash; `ash -n` reports a false error at the `<<<` here-string, as
Phase 1 recorded).

---

## 10. Every write I made to the cluster, and the cleanup

1. **PVC** (the one sandbox claim): `MEMORY.md`, `USER.md` and their two `.lock` files **moved** to
   `/opt/data/memories-legacy/` (nothing deleted); `/tmp/probe_pod.py` written inside the container's
   `/tmp` (ephemeral).
2. **Deployment** `sudo-mail-bot-hermes` regenerated and applied through `up.sh` (image, secrets refs,
   probes, the 4 preserved `PAPERCLIP_*` vars, api-server env) — the recreate itself.
3. **Secrets** `sudo-mail-bot-hermes-api-key` and `sudo-mail-bot-hermes-api-server-key` created by that
   manifest (they did not exist; the live deployment had carried a literal key value).
4. **Service** `sudo-mail-bot-hermes-api` created by the same manifest (api_server enablement).
5. **ConfigMaps** `sudo-mail-bot-hermes-{watch-config,watch-plugin,comm-gate-plugin}` regenerated by
   the same run.
6. **Per-agent config** `factories/sudo-agent/config/mail-bot-hermes.yaml` (instance, gitignored): the
   two memory numbers by me; `api_server.enabled` + `mcp_servers` by `up.sh`.
7. **Paperclip**: existing agent reused, `PAPERCLIP_*` env re-injected into the same deployment.
8. **Repo**: `bin/up.sh` hunk + this report. A frozen snapshot `bin/.up-p2b-snapshot.sh` was used for
   the deploy and **deleted** afterwards.

Not touched: every other deployment, every other pod, the shared Redis (`resourceVersion` proven
unchanged), the node, the PVC directory directly (only through the pod), and the tag
`sudo-agent:latest` (still `16d149ddf0f2…`). No `kubectl rollout restart` was used anywhere; the pod
was recreated by applying a new pod template.

**Cleanup:** `/tmp/p2-selfcopy` (570 MB) **deleted**; `bin/.up-p2b-snapshot.sh` deleted.

---

## 11. What the propagation job inherits

- A store written by the old binary opens under the new one with **no migration** (32 → 32), on real
  data, in place. Cheap to verify per agent: `schema_version`, row counts, one `session_search`.
- **Arc** of an agent's identity is safe: SOUL, skills and sessions all survive a recreate. The only
  file that changes is the managed FLEET-COMM block inside `SOUL.md`, by design.
- **Deliver new behaviour via the persona block, not the skill seed** — the seed is first-boot-only
  and `.comm-seeded` is exactly what stops it (proven twice: 18 skills preserved, new skill route
  would not have fired).
- **Archive legacy memory inside the recreate**, not as a separate pass — it was a file move costing
  nothing.
- Per-agent configs must be swept for the budget: the template's 40000/20000 reaches only *new*
  agents, because `up.sh` seeds the per-agent file once and then leaves it alone.
- `SUDO_AGENT_IMAGE` now exists on the deploy path, so a candidate image can be canaried on one agent
  without touching the shared tag.

---

## 12. Independent re-verification (the second h2 conversation, read-only)

A second conversation of this same agent — `local-54aa75…`, the one that ran the memory archive at
19:33:03Z (§6.2) — finished its own pass over brief B *after* the recreate had landed. This section is
its independent measurement, taken between **19:45Z and 19:52Z**. It wrote nothing to the cluster:
every command below is a `kubectl get`, an `exec` that only reads (`cat`, `md5sum`, `grep`), or a
read-only SQLite open (`file:…?mode=ro`). The point is the same one §8 makes — the numbers that matter
here were measured twice, by two hands, on the same live pod.

| Re-measured | Value | Verdict |
|---|---|---|
| Deployment image, both containers | `sudo-agent:p2a-h1` | PASS |
| Pod | `2/2 Running`, `ready=true` on both, **restarts 0** | PASS |
| Container `imageID` | `sha256:2003be5c…`, `repoTags [docker.io/library/sudo-agent:p2a-h1]` | PASS |
| Pod-template annotation `sudo-agent/image-sha` | `sha256:ebc56f72e84a…` — **h1's `P2A-DONE.txt` IMAGE ID, character for character** | PASS |
| `hermes --version` in the pod | `Hermes Agent v0.22.5 (2026.9.24) · upstream bf0203a7` | PASS |
| Patch marker (space form) / `background_review.py` | `0` / `1349` lines | PASS |
| `find / -name patch_memory_review.py` | `0` hits | PASS |
| `state.db` | `78,569,472` bytes, `schema_version` 32, `integrity_check` **ok** | PASS |
| `session_search` in the pod | `mode discover`, hit dated **September 07, 2026** | PASS |
| `/opt/data/config.yaml` in the pod | `memory_char_limit: 40000` / `user_char_limit: 20000` | PASS |
| `skills/` / `.comm-seeded` | 18 / present, still `2026-09-30` | PASS |
| `memories/MEMORY.md` | 115 bytes, one entry, mtime 19:41Z | PASS |

### 12.1 The past survived — and the store has since grown, which is not a regression

Re-run after the recreate, the raw counts read **413 sessions / 6,356 messages**, not the 411 / 6,344
of the baseline. That difference is *new work*, not lost work, and it is worth proving rather than
assuming, because a later reader (or h4) comparing totals against §3 will see the number move:

```
$ python3 -c '…sqlite3 read-only…'          # inside the pod
sessions_older_24h       411
sessions_last_24h          2
messages_in_old_sessions 6344
messages_in_new_sessions   12
total_sessions            413
total_messages           6356
```

Every one of the 411 pre-upgrade sessions and all 6,344 of their messages are still present and still
attached to each other; the two extra sessions are post-recreate turns — `Save sandbox recreation
memory` (19:41Z, the §6.1 turn) and one diagnostic turn at 19:45Z.

**The right reading is the opposite of "the store changed": a store that only ever holds its old
counts is a store whose writer is dead.** Here the old rows survived *and* the new binary appended to
the same file. The baseline to check against is the pair (411 older sessions, 6,344 messages in
them) — not the total.

### 12.2 SOUL: everything outside the managed block is byte-identical

§6 reports that `SOUL.md` grew from 7,891 to 9,559 bytes with all additions inside the FLEET-COMM
block. That claim is checkable without the pre-upgrade file, because the block is delimited and the
pre-upgrade snippet still exists in git:

```
# 1. the file as it is on the PVC now
$ kubectl exec … -- cat /opt/data/SOUL.md > SOUL-after.md
$ md5sum SOUL-after.md
62e1be7a40585e729c2704b8c19ef77c  SOUL-after.md          # 9,559 bytes

# 2. take the text between the markers, put the pre-upgrade snippet back, re-hash
$ git show afef43e^:factories/sudo-agent/comm/PERSONA-SNIPPET.md   > snippet-old.md
  block = lines between <!-- FLEET-COMM-AWARENESS-BEGIN --> (54) and END (79)
  reconstructed = lines[:54] + snippet-old.md + lines[79:]
$ md5(reconstructed)
721754026f924d2079a37f0d323c6d22

# 3. and that is exactly the md5 the same pod's SOUL.md had BEFORE the recreate
721754026f924d2079a37f0d323c6d22   (captured at 19:35Z, on the old pod)
```

Identical. **Every byte of the agent's own persona outside the markers is unchanged by the upgrade**;
the block between them is the only part that moved, and it is the part the entrypoint is supposed to
own.

### 12.3 The block on the PVC is the CURRENT text, not a stale copy

h4's check 3A asks whether the instruction that landed is the text the repo ships today. The block's
own digest answers it:

```
$ block = lines 55..78 of SOUL-after.md      # between the markers, 24 lines, 4,165 chars
$ sha256(block)          7c1420eb7393c86b13d0f985d37bf30787c90b1ec32ce4b814f5d415d817b9b7
$ git show HEAD:factories/sudo-agent/comm/PERSONA-SNIPPET.md | sha256sum
                         7c1420eb7393c86b13d0f985d37bf30787c90b1ec32ce4b814f5d415d817b9b7
```

Equal, so the delivered block **is** the committed snippet — including `## Your memory` (line 66, one
occurrence). This is also the answer to the question h3 asked
of this brief directly: after the recreate, `/opt/data/SOUL.md` on the sandbox PVC carries
`## Your memory` *between* the FLEET-COMM-AWARENESS markers. Grepped, not hand-edited — the block is
replaced on every boot, so a hand-edit would have been erased by the very next restart.

### 12.4 What this section does not change

Nothing in §1–§11 is corrected by the re-measurement; every headline claim reproduced. The one number
that will drift for anyone re-reading this later is §12.1's session/message total, and it should: the
agent is alive and writing. `/tmp/p2-selfcopy` was already gone when this pass started, and this pass
created no copy of its own.
