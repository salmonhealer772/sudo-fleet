# h1 — P1-A report: pin the base, remove the memory patch

Agent: sudo-fleet-glm-h1
Brief: P1-A (Dockerfile, patch_memory_review.py, the up.sh references)
Date: 2026-10-28 (UTC)
Commits pushed: **37b863b** — `pin base to v0.22.5 and remove the memory patch`; then
`fix(factory): qualify the pinned base image` (correction after h4's build — §5).
Status: **DONE** — pinned to the fully qualified `nousresearch/hermes-agent:v0.22.5`,
patch gone from every functional reference, line-556 rationale intact, up.sh parses,
the base reference builds (probe in §5), pushed to origin/main, fleet untouched.

Working copies of what I produced:
`/tmp/oct27/hermes-upgrade-research/phase1-out/h1/{Dockerfile,up.sh}` plus this report.
Committed into the repo at `factories/sudo-agent/{Dockerfile,bin/up.sh}` and `docs/h1-P1-A-REPORT.md`.

---

## 1. What changed

### 1.1 Base image pinned (Dockerfile)

```dockerfile
# PINNED BASE — deliberately a version tag, not :latest. The unpinned tag
# silently drifted a month behind (agents still reported 2026.9.24 while
# v0.22.5 had shipped) and nobody noticed until the memory patch broke.
# Bump this line on purpose; do not go back to :latest.
# v0.22.5 is a multi-arch manifest (linux/amd64 + linux/arm64) and this node is
# arm64, so the plain tag is the right one — never an arch-suffixed tag.
# The repository is spelled out in full: a bare `hermes-agent:v0.22.5` resolves
# to docker.io/library/hermes-agent, which does not exist, so a build dies at
# step 1 unless someone has hand-made a local tag. Only this reference pulls.
FROM nousresearch/hermes-agent:v0.22.5
```

The first delivered version carried the brief's bare `hermes-agent:v0.22.5` and
failed to build; §5 records the correction and why only the qualified form resolves.

Registry check done from this pod (not taken on faith):

```
$ curl -s https://hub.docker.com/v2/repositories/nousresearch/hermes-agent/tags/v0.22.5
v0.22.5 2026-10-23T05:28:49.471467Z
[('amd64', 'linux'), ('arm64', 'linux')]
```

Plain `v0.22.5`, no arch suffix, both architectures present.

### 1.2 Memory patch deleted

* `factories/sudo-agent/patch_memory_review.py` — deleted (`git rm`, 67 lines).
* Dockerfile lines 76–77 (the `COPY` and the `RUN python3 /tmp/patch_memory_review.py`) replaced with a two-line tombstone comment. The comment deliberately does **not** name the file, so a future `grep` for the vanished filename finds only the line-556 rationale:

```dockerfile
# REMOVED: the build-time memory patch that used to be copied and run here.
# Hermes saves memory natively now; the patch wrote raw user text and broke on base bumps.
```

### 1.3 up.sh — three references treated three different ways

| line | was | now |
|---|---|---|
| 556 (comment) | `An image-only fix (e.g. a patch_memory_review.py change)` | `An image-only fix (e.g. the old patch_memory_review.py change)` — **kept**, past tense, explanation untouched. Still on line 556. |
| 1402 (loop) | `for f in "$REPO_DIR/Dockerfile" "$REPO_DIR/patch_memory_review.py"; do` | `for f in "$REPO_DIR/Dockerfile"; do` |
| 1408 (warning) | `...predates ...Dockerfile or patch_memory_review.py; rebuild if you changed them` | `...predates ...Dockerfile; rebuild if you changed it` |

The guard itself is unchanged: the fatal check is still the MCP source-digest comparison against the built image, and the Dockerfile-mtime note is still advisory-only. Nothing about what `_assert_image_fresh` blocks or rolls changed.

### 1.4 Four consequential edits beyond the literal brief (disclosed, not silent)

Leaving these would have put false statements in the files I own:

1. Dockerfile header lines 1–3 said the image "patches background review to programmatically save every user message to memory". Rewritten to say the pin is deliberate and the patch is gone.
2. Dockerfile `LABEL ... description="... save-everything memory"` → `"... native memory"`. Metadata only; nothing reads it.
3. up.sh lines 1399–1400 said "the Dockerfile / memory patcher are not readable from the image, so fall back to a timestamp note for those two" — after 1402 the loop covers one file. Reworded to "the Dockerfile … for it". Same edit class as 1408: it named a file that no longer exists.
4. `factories/sudo-agent/setup.sh` line 42 asserted "sudo-agent is `FROM
   hermes-agent:latest`, so the base is built first" — the §5 correction made that
   false. Comment only, rewording it to say the FROM is the pinned registry image and
   that the local base is still built/imported by up.sh. The build/import logic itself
   is untouched — that is F2, still open.

---

## 2. Proof (actual output)

Run on the host checkout `/opt/0-0/sudo-fleet`, after the commit landed.

```
=== a) FROM ===
12:FROM hermes-agent:v0.22.5

=== b) patch file ===
ls: cannot access 'factories/sudo-agent/patch_memory_review.py': No such file or directory

=== c) refs in factory root (excluding vendored glimors copies) ===
factories/sudo-agent/README.md:158:  `Dockerfile` or `patch_memory_review.py` means the **image** must be rebuilt
factories/sudo-agent/bin/up.sh:556:# running pod on the OLD image. An image-only fix (e.g. the old patch_memory_review.py

=== d) bash -n ===
bash -n: OK (exit 0)
```

(c) on the staged tree, which is what the brief specifies — `grep -rn patch_memory_review phase1-out/h1/`:

```
up.sh:556  (the retained rationale comment)
```

No hit in `Dockerfile`, none in any functional up.sh line. The `README.md:158` hit is outside my brief's files — see finding F3.

```
=== e) commit + remote ===
37b863b pin base to v0.22.5 and remove the memory patch
37b863b2a309749f0860314867e86c6cc6884573
37b863b2a309749f0860314867e86c6cc6884573	refs/heads/main     <- origin/main, so it is on GitHub

=== show stat ===
 3 files changed, 19 insertions(+), 81 deletions(-)
 delete mode 100644 factories/sudo-agent/patch_memory_review.py
```

Hashes of what is now in the repo (identical to the staged copies):

```
4e9b190e6ad7eb870e536c996f56db78  factories/sudo-agent/Dockerfile
4caf72a9ba77aa0d1ce4d4882c046629  factories/sudo-agent/bin/up.sh
```

**f) I deployed nothing and touched no running agent.** No `docker build`, no `docker tag`, no `kubectl`, no pod exec in this session. The only docker use was `docker run --rm alpine` helper containers for file reads/writes and `docker image inspect` / `docker images` reads. The image the fleet references is untouched:

```
sudo-agent:latest  ID=sha256:16d149ddf0f2...  Created=2026-10-18T23:12:48-07:00  (9 days ago)
hermes-agent:latest ID=sha256:e215c3268860...  Created=2026-10-18T23:11:14-07:00  (9 days ago)
```

---

## 3. Findings for the lead (things I did not fix, and why)

**F1 — RESOLVED in §5: the brief's bare tag cannot be resolved from a registry; the line now uses the F27 reference.**
The brief says `FROM hermes-agent:v0.22.5`; `00-FACTS.md` F27 records the resolved reference as `nousresearch/hermes-agent:v0.22.5`. I followed the brief (docs contradicting the brief → do the brief, report the disagreement), but the two are not equivalent operationally: with a bare name, docker looks for `docker.io/library/hermes-agent:v0.22.5`, which does not exist, so the build fails with a pull error rather than a Dockerfile error. Before building, the base must exist locally:

```
docker pull nousresearch/hermes-agent:v0.22.5
docker tag  nousresearch/hermes-agent:v0.22.5 hermes-agent:v0.22.5
```

I have messaged h4 with exactly this (msg id `msg-b36e1dc1526d`, inbox). **Decision for you:** either accept the pre-tag step as part of the factory workflow, or change the line to the fully qualified `FROM nousresearch/hermes-agent:v0.22.5`, which pulls on its own and is what F27 actually verified. I first followed the brief literally and escalated this instead of editing the target
line; after h4's build failed at step 1 (and F27 independently records the qualified
reference) I changed it — see §5.

**F2 — up.sh's build-on-missing path still builds `hermes-agent:latest` from git HEAD, so the committed repo cannot reproduce the pinned base end to end.**
`_build_hermes_base` (up.sh ~1302–1314) does `git clone --depth 1` + `docker build -t hermes-agent:latest`, and `_ensure_image_built` special-cases `hermes-agent:latest`; `_import_image hermes-agent:latest` still imports that tag. That is the same unpinned-drift mechanism this brief removes from the Dockerfile, just moved into the deploy script. Fixing it means changing what up.sh builds and imports — a behaviour change well outside "fix the three patch mentions" — so I left it. It needs its own brief.

**F3 — `factories/sudo-agent/README.md:158` still says the image must be rebuilt if you change `Dockerfile` or `patch_memory_review.py`.**
Stale doc line, not a functional reference, and not in my brief's file list, so I did not edit it. Suggested replacement: `` `Dockerfile` means the **image** must be rebuilt ``.

**F4 — Vendored copies still carry the patch.** `factories/sudo-agent/glimors/**/sudo-agent-work/sudo-agent/{Dockerfile,README.md,kube-scripts/up.sh}` are per-agent work checkouts from earlier runs, not the factory. They still contain `patch_memory_review.py` references and one copy of the script. Out of scope; listed so nobody is surprised by a repo-wide grep.

**F5 — The brief's example push command has two defects, both worked around.**
(a) It uses `/host/tmp/...` *inside* `nsenter -t 1 -m ...`; in the host mount namespace `/host` does not exist (that mount only exists in the helper container), so `cp` fails with "cannot stat". The working path is `/tmp/oct27/hermes-upgrade-research/...`.
(b) It uses `git add -A`, which on this checkout would have swept ~16 unrelated untracked files (`bin/talk-ALL*.sh`, logs, other agents' reports) into my commit. I staged only the three paths I own.

**F6 — Notification ordering.** When I pushed, origin/main was at `affa96b`; my commit `37b863b` went in cleanly. h2's commit `13784dc` landed on top afterwards, so my commit is now `HEAD~1` on main. No rebase conflict, no force-push, history linear.

---

## 4. Definition of done, checked

| requirement | evidence |
|---|---|
| Dockerfile pinned to v0.22.5 | `15:FROM nousresearch/hermes-agent:v0.22.5` (F27 reference) |
| comment explains the pin | Dockerfile lines 6–11 |
| patch file deleted | `ls` → No such file; commit stat shows `delete mode 100644` |
| Dockerfile no longer copies/runs it | grep of Dockerfile for `patch_memory_review` → no hits |
| up.sh loop no longer lists it | line 1402 → `for f in "$REPO_DIR/Dockerfile"; do` |
| up.sh warning no longer names it | line 1408 reworded |
| line-556 rationale survives | `up.sh:556` still carries the explanation, example in past tense |
| guard behaviour unchanged | only the advisory mtime loop touched; fatal digest check untouched |
| up.sh parses | `bash -n` exit 0 |
| pushed to GitHub | `git ls-remote origin main` = `37b863b...` |
| live fleet untouched | no build/tag/kubectl/exec; `sudo-agent:latest` still the 2026-10-18 image |

---

## 5. Correction, 2026-10-28 — the FROM line is now fully qualified (resolves F1)

h4 built the delivered `phase1-out/h1/Dockerfile` and it failed at step 1:

```
Step 1/20 : FROM hermes-agent:v0.22.5
pull access denied for hermes-agent, repository does not exist or may require docker login
BUILD_EXIT=1
```

I re-verified the cause on the same daemon rather than taking it on h4's word:

```
$ docker manifest inspect hermes-agent:v0.22.5
denied: requested access to the resource is denied
unauthorized: authentication required        <- docker.io/library/hermes-agent: no such repo

$ docker manifest inspect nousresearch/hermes-agent:v0.22.5
"mediaType": "application/vnd.docker.distribution.manifest.list.v2+json"
  2 platforms: linux/amd64, linux/arm64

$ curl -s -o /dev/null -w '%{http_code}' https://hub.docker.com/v2/repositories/nousresearch/hermes-agent/tags/v0.22.5
200

$ docker images | grep hermes-agent
hermes-agent:latest                e215c3268860   <- LOCAL tag, built by up.sh _build_hermes_base
hermes-agent:v0.22.5               9c5561579f3f   <- alias h4 made by hand to stay unblocked
nousresearch/hermes-agent:v0.22.5  9c5561579f3f
```

Nothing in the factory ever creates a local `hermes-agent:v0.22.5` (`up.sh` only
special-cases `hermes-agent:latest`), so the bare pin could never resolve on a clean
host. That is F1 above, now proven by a real build instead of predicted, and
`00-FACTS.md` F27 records the resolved reference as `nousresearch/hermes-agent:v0.22.5`
(F28: amd64 + arm64).

Why I changed it: in the first pass I followed the brief literally and escalated
rather than editing the target line (§3 F1). The contradiction is now settled by a
failing build, not by opinion — the literal brief line cannot produce the artifact the
brief asks for, and F27, written by the lead after the brief, names the reference that
does. The line now uses F27's reference.

Changed in both places; the staged copy and the repo are byte-identical
(md5 `4e9b190e6ad7eb870e536c996f56db78`):

```
-FROM hermes-agent:v0.22.5
+# The repository is spelled out in full: a bare `hermes-agent:v0.22.5` resolves
+# to docker.io/library/hermes-agent, which does not exist, so a build dies at
+# step 1 unless someone has hand-made a local tag. Only this reference pulls.
+FROM nousresearch/hermes-agent:v0.22.5
```

Proof of the fixed line — a real one-step build, not a config read:

```
$ docker build -t h1-fromprobe:throwaway <dir whose Dockerfile is FROM nousresearch/hermes-agent:v0.22.5>
#5 naming to docker.io/library/h1-fromprobe:throwaway done
#5 DONE 0.3s                                  <- step 1 resolved and built
$ docker rmi h1-fromprobe:throwaway           <- probe tag removed afterwards

$ grep -n '^FROM' factories/sudo-agent/Dockerfile
15:FROM nousresearch/hermes-agent:v0.22.5
$ diff -q phase1-out/h1/Dockerfile factories/sudo-agent/Dockerfile   -> identical
$ bash -n factories/sudo-agent/bin/up.sh                             -> OK (untouched by this fix)
$ docker image inspect sudo-agent:latest -> ID sha256:16d149ddf0f2..., Created 2026-10-18 (fleet image unchanged)
```

`up.sh` is unaffected by this correction: the only `patch_memory_review` hit left in it
is the line-556 rationale comment, line 1402's loop lists only `$REPO_DIR/Dockerfile`,
and line 1408 names no file.

Three notes for the lead:

* h4's local alias tag `hermes-agent:v0.22.5` is not needed once this commit is in. I
  left it in place — h4's build was in flight, and removing a tag h4 created is h4's
  call, not mine.
* F2 still stands and is now the remaining clean-host gap: `up.sh` still builds and
  imports `hermes-agent:latest` as the base whatever the Dockerfile's FROM says. That
  needs its own brief; this commit does not touch it.
* Commit 983834f (the setup.sh comment fix) also carries two lines I did **not** author:
  the uncommitted working-tree change `memory_char_limit: 100000 -> 40000`,
  `user_char_limit: 50000 -> 20000` in setup.sh's embedded config heredoc — the two-line
  fix h2 flagged in `docs/P1-B-MEMORY-AND-IDENTITY.md` (f). I ran
  `git add factories/sudo-agent/setup.sh` for my comment edit without diffing that file
  first, so the pending change went in with my commit. The bytes are correct (they match
  `config.yaml` and F23/F24), so I did not revert them; the commit boundary is wrong, not
  the content. Disclosed to the lead and to h2.
