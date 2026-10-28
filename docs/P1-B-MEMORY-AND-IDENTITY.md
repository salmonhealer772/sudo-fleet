# P1-B — memory budget and the memory instruction (h2)

Date: 2026-10-28 · Scope: `factories/sudo-agent/config.yaml` (tracked template) and
`factories/sudo-agent/config/<name>.SOUL.md` (per-agent identity). No live fleet was touched:
no deploy, no restart, no scale, no exec, no image tag rebuilt.

## What changed, in one table

| File | Change |
|---|---|
| `factories/sudo-agent/config.yaml` | `memory` block: `memory_char_limit` 100000→**40000**, `user_char_limit` 50000→**20000**. Comment block added above it: why the budget is large, the entry-size guardrail, and the MEMORY INSTRUCTION. Other four keys untouched. |
| `factories/sudo-agent/config/sudo-fleet-glm-h1.SOUL.md` | New section **`## What goes in memory`** (13 lines) inserted after `## How you work`, before `## Your reach`. Nothing else in the identity changed — verified by diff, insertion only. |

The four memory keys that must not move were checked by re-parsing the YAML, not by eye:
`memory_enabled: true`, `user_profile_enabled: true`, `write_approval: false`,
`nudge_interval: 1`. Six keys in, six keys out.

---

## (a) The new memory block verbatim, including the comment above it

Lines 36–55 of `factories/sudo-agent/config.yaml`:

```
# ── Memory ──────────────────────────────────────────────────────────────────
# The budget is large because the writer is the model choosing facts, not a patch
# dumping whole messages. Watch ENTRY SIZE, not total characters: healthy is 100-300
# characters per entry, and if entries average thousands again the writer is wrong
# and no limit will save it. Do NOT raise these back to 100000/50000 — that is the
# pair that filled (99,861 chars, 34 entries averaging 2,850) and silently stopped
# accepting writes. Fix the writer instead.
#
# MEMORY INSTRUCTION — what this store is FOR, not how big it may grow:
#   SAVE      durable facts about the environment, team conventions, a procedure
#             that took real effort to work out, corrections the operator made.
#   DO NOT SAVE  task text, a brief someone sent you, another agent's message, or
#             conversational filler. Transcripts live in session_search, not here.
memory:
  memory_char_limit: 40000
  user_char_limit: 20000
  memory_enabled: true
  user_profile_enabled: true
  write_approval: false
  nudge_interval: 1
```

## (b) and (c) the two numbers

```
$ grep -c "memory_char_limit: 40000" config-template.yaml
1
$ grep -c "user_char_limit: 20000" config-template.yaml
1
```

Parsed (host `python3` + PyYAML, so this is the file as Hermes will read it, not as grep sees it):

```
YAML OK; top keys: 9
{
  "memory_char_limit": 40000,
  "memory_enabled": true,
  "nudge_interval": 1,
  "user_char_limit": 20000,
  "user_profile_enabled": true,
  "write_approval": false
}
```

## (d) The SOUL section, full text — 13 lines

```
## What goes in memory

Your `MEMORY.md` and `USER.md` are small, hand-kept stores, not a log. Write an entry only when it
will still be true — and still be useful — in a month:

- **Save:** durable facts about this box and the repo, conventions the team works by, a procedure
  that took real effort to work out, and any correction the operator made to you.
- **Do not save:** the text of a task, a brief someone sent you, another agent's message, or
  conversational filler. Those are already in the transcript, which `session_search` reads.

One entry is one fact: a sentence or two, 100-300 characters. If your entries run to thousands of
characters you are filing messages, not facts, and the store will fill and stop accepting writes.
```

Second person, matching the rest of the SOUL; it names the store, the two lists, and the entry-size
rule that the config comment also carries.

## (e) Reach — and one policy collision you need to rule on

`factories/sudo-agent/config/` on this checkout:

```
$ cd factories/sudo-agent/config && ls *.SOUL.md
sudo-fleet-glm-h1.SOUL.md
sudo-fleet-glm-h2.SOUL.md
sudo-fleet-glm-h3.SOUL.md
sudo-fleet-glm-h4.SOUL.md
sudo-fleet-glm-h5.SOUL.md

$ ls | wc -l
84
$ ls *.yaml | wc -l
66
```

**Exactly five agents have a SOUL file in this checkout: `sudo-fleet-glm-h1` … `sudo-fleet-glm-h5`.**
The other Hermes agents have none, so `up.sh` seeds nothing for them (line 709: `elif [[ -f
"$SOUL_SRC" ]]`). The SOUL half of this brief therefore reaches **5 agents, not 60**.

Full command output is in `phase1-out/h2/config-listing.txt`.

Two things I did not do, deliberately:

1. **Applied the section to h1 only.** h2–h5 are byte-identical to h1 apart from three name lines
   (`diff` shows 3 changed lines), so the section drops in unchanged. I built all five and left the
   other four in `phase1-out/h2/souls/` rather than writing them, because (i) the brief named h1,
   (ii) h2's SOUL is my own persona, and (iii) who else gets an identity rewrite is your call.
   Placing them is a 4-line `cp`. Say the word and it is done.
2. **Did not `git add -f` the SOUL.** Two ignore rules cover it:
   `factories/sudo-agent/.gitignore:3` (`config/` — the whole per-agent config directory is
   untracked) and the root `.gitignore:26` (`factories/sudo-agent/config/*.SOUL.md`), and
   `check-ignore -v` confirms the nested rule is the one matching:
   `factories/sudo-agent/.gitignore:3:config/  factories/sudo-agent/config/sudo-fleet-glm-h1.SOUL.md`.
   `docs/REPOSITORY-VS-INSTANCE.md` says in terms that personas and saved identities are *instance*
   material and that "a public repository that carries live agent identities leaks their owners".
   So the edited SOUL is placed at its live seed path on the host checkout
   (`factories/sudo-agent/config/sudo-fleet-glm-h1.SOUL.md`, md5 `cabda732f731782aaef8718b4a08ee71`,
   13 lines longer than before) and is **not** in the commit. It is delivered in `phase1-out/h2/`.
   If you want SOULs to be repo material you own `.gitignore` (01-PHASE-1-PLAN, "lead | me | the
   `.gitignore`/COMPONENTS updates") — that is a policy change I am not making behind your back.

Consequence worth staring at: **the only part of this brief that is reproducible from a fresh clone
is the config comment.** A clone gets the budget and the instruction-to-maintainers; it does not get
an agent that has been told what memory is for.

### Caveat on "the comment reaches every future agent"

A YAML comment is read by the person editing the config, not injected into the model's prompt. The
`memory:` comment is the deterrent that stops the next maintainer raising the limit to 100000 —
which is exactly what you asked for — but the thing that changes what an agent *writes* is the SOUL
section. Since only 5 of ~60 agents have a SOUL file, the "every future agent" reach is the config
default (40000/20000), not the instruction. If you want the instruction to reach all 60, the cheap
route is a shared skills/mod seed (the same mechanism that seeds their skills), not 60 persona files.

## Two mechanical findings Phase 2 needs

1. **Per-agent configs override the template.** `up.sh:96` seeds `config/<name>.yaml` from
   `config.yaml` **only on first deploy** (`if [[ ! -f "$PER_AGENT_CONFIG" ]]`). Every existing
   per-agent config already carries its own `memory:` block with 100000/50000
   (`factories/sudo-agent/config/sudo-fleet-glm-h1.yaml`, lines 6–12). So this change lands on
   **newly created** agents; the 60 running ones keep 100000 until their per-agent config is
   rewritten. Phase 2's sweep must rewrite those blocks, not assume the template did it.
2. **The SOUL seed is non-destructive.** `up.sh` writes `/opt/data/SOUL.md` only when it is absent
   or matches the stock md5 (`SOUL_STOCK_MD5=1aec3b727511f093344188de159a77ca`). A recreated pod on
   an **existing PVC** keeps its old SOUL and will not receive this section. New section reaches an
   agent only on a fresh volume, or when its `SOUL.md` is removed as part of Phase 2's recreation.

## The seed heredoc that carried the old numbers — closed in `983834f`

**What it was.** `setup.sh` does not only read the config, it can recreate it. `setup.sh:69` sets
`CONFIG_FILE="$SCRIPT_DIR/config.yaml"`; at `setup.sh:219` a guard `if [[ ! -f "$CONFIG_FILE" ]]` seeds
that file from a `cat > "$CONFIG_FILE" << 'CONFIGEOF'` heredoc, and the `memory:` pair inside it still
read `100000` / `50000` — the template I had just lowered and the seed that could recreate it
disagreed. `setup.sh` was in nobody's owned paths in P1-B, which is why this is a follow-up and not part
of `13784dc`.

**Closed.** The heredoc now reads `memory_char_limit: 40000` and `user_char_limit: 20000` — the
template's pair, two integers, no reformatting and no other edit in the file — as of commit
**`983834f59a3454e1a155ed79efbc004c23383d90`**. In that tree the pair sits at `setup.sh:227-228`, the
guard at `setup.sh:219`, the heredoc body `setup.sh:222-233`. That is h1's commit ("docs(factory):
setup.sh comment no longer claims the base is FROM hermes-agent:latest"), not a separate one of mine:
h1 edited a comment in the same file and ran `git add factories/sudo-agent/setup.sh` without diffing it
first, so h2's uncommitted working-tree change rode in with the comment edit. h1 caught that on review,
kept the bytes (they match `config.yaml`) and disclosed it in `761100a`. The content on `origin/main` is
right; only the commit boundary is not the one this follow-up drew, and it is recorded here so that
nobody later reads `983834f` as an h1 memory decision.

**Evidence: the branch was executed, not quoted.** Running `setup.sh` itself in a scratch copy is not
safe — `setup.sh:63-64` runs `docker build -t sudo-agent:latest` unconditionally, before it ever
reaches the seed, so a plain scratch run retags the live image. So the guard and heredoc were extracted
verbatim (`sed -n '219,234p' factories/sudo-agent/setup.sh`, verified byte-identical to the file) into a
driver in `/tmp/oct28/h2-seed-proof/`, outside the repo, with `CONFIG_FILE` pointed at a path that did
not exist:

```
BEFORE: absent -> guard TRUE  (<- ! -f)
AFTER : exists -> the heredoc created it

$ cat /tmp/oct28/h2-seed-proof/run1/config.yaml
terminal:
  backend: "local"
  sudo_password_env: "SUDO_PASSWORD"
memory:
  memory_char_limit: 40000
  user_char_limit: 20000
  memory_enabled: true
  user_profile_enabled: true
  write_approval: false
  nudge_interval: 1
```

Ten lines, and it parses — `yaml.safe_load` returns `memory_char_limit: 40000`,
`user_char_limit: 20000`, `memory_enabled: True`, `user_profile_enabled: True`,
`write_approval: False`, `nudge_interval: 1`. The same extraction from parent `a4e2483` emits
`100000`/`50000`, so the check discriminates instead of always passing. Nothing in the scratch directory
was committed.

**Re-proved end to end on the real script, second pass.** The extraction above proves the heredoc; this
pass runs `setup.sh` *itself* from a tracked-only copy of `origin/main`, so the guard, the heredoc and the
convergence that follows it all execute in the order a real first run hits them. `docker` and `kubectl`
stubs go first on `PATH` so the unconditional `docker build` at `setup.sh:63` cannot retag the live
`sudo-agent:latest`; `DEEPSEEK_API_KEY` is supplied so nothing prompts; stdin is closed.

```
$ git archive origin/main | tar -x -C /tmp/oct28/p1b-setup-seed/repo
$ cd /tmp/oct28/p1b-setup-seed/repo/factories/sudo-agent && rm -f config.yaml .env
$ PATH=/tmp/oct28/p1b-setup-seed/bin:$PATH DEEPSEEK_API_KEY=sk-proof-not-a-real-key \
    timeout 120 bash setup.sh </dev/null; echo RUN1_RC=$?
RUN1_RC=0

$ awk '/^memory:/{f=1} f&&/^[a-z_]+:/&&!/^memory:/{f=0} f' config.yaml
memory:
  memory_char_limit: 40000
  user_char_limit: 20000
  memory_enabled: true
  user_profile_enabled: true
  write_approval: false
  nudge_interval: 1

$ grep -c 'memory_char_limit: 40000' config.yaml ; grep -c '100000' config.yaml
1
0
$ grep -c 'user_char_limit: 20000' config.yaml ; grep -c '50000' config.yaml
1
0
```

`yaml.safe_load` parses the result. The file that survives is 14 lines / 319 bytes — the ten seed lines
plus the `model` / `base_url` / `provider` keys the convergence block adds after the seed — so quote the
`memory:` block above rather than a whole-file byte count.

**The guard, executed rather than argued.** Append a sentinel to the generated `config.yaml` and re-run
the identical command: the file comes back byte-identical, so `! -f` is false, the heredoc does not run,
and an existing file is never rewritten.

```
before: md5=ebf224a0e877abd746e4ed418bfce441 lines=15
RUN2_RC=0
after : md5=ebf224a0e877abd746e4ed418bfce441 lines=15
sentinel still present: 1
```

The same seed block lifted from `a4e2483` emits `memory_char_limit: 100000` / `user_char_limit: 50000`,
so a green run here is a real signal rather than a check that cannot fail.

**The hazard, stated accurately.** The branch fires only when `$CONFIG_FILE` is already absent.
`config.yaml` is tracked, so a clone has it, the guard is false, and the seed is dead code on a healthy
checkout — the numbers in it change nothing for anyone who has the template. It matters only if the
file is gone: the tracked `config.yaml` is deleted or moved (partial or filtered clone, a manual `rm`, a
refactor that renames the template), or `setup.sh` runs from a copy of the directory that never had it.
Then `setup.sh` silently recreates the file — and before this fix it would have recreated it with
`100000`/`50000` and undone P1-B with nothing in the history to show it, so it would have read as though
the template had never been fixed. That is the whole hazard; it was worth two integers.

**`git grep` after the fix** (tracked files):

```
$ git grep -n "memory_char_limit\|user_char_limit" -- factories/
factories/sudo-agent/config.yaml:50:  memory_char_limit: 40000
factories/sudo-agent/config.yaml:51:  user_char_limit: 20000
factories/sudo-agent/setup.sh:227:  memory_char_limit: 40000
factories/sudo-agent/setup.sh:228:  user_char_limit: 20000
```

Four hits, all `40000`/`20000`: template and seed agree. A whole-tree grep adds only this report and
`docs/h1-P1-A-REPORT.md`, both quoting the old pair in prose — `git grep -l "memory_char_limit:
100000" -- .` matches exactly those two files — so no tracked file still *sets* it. The per-agent
configs `git grep` cannot see (`config/` is untracked) are the part still open; they are counted in the
addendum below.


## (f) Commit

```
$ git rev-parse HEAD
13784dc21deac1ec136d29727a1079d90176397c
$ git rev-list --left-right --count origin/main...HEAD
0	0
$ git show origin/main:factories/sudo-agent/config.yaml | grep -n "char_limit"
50:  memory_char_limit: 40000
51:  user_char_limit: 20000
```

`37b863b..13784dc  main -> main`. h1's patch-removal commit (`37b863b`, "pin base to v0.22.5 and
remove the memory patch") is the parent of mine, so the sequencing this brief worried about — the
lowered budget landing while the patch that needed 100000 was still writing — resolved itself: the
patch is already gone from `main`. The two files are disjoint, no rebase was needed.

## (g) One line

An engineer now starts with a 40000/20000 budget and an explicit instruction to save durable facts
and procedures only — never the brief it was handed — so the store holds short chosen facts instead
of a re-filed inbox, and a full store stops hiding corrections the operator already gave it.

---

## PUSHED AS

| item | value |
|---|---|
| code commit (`config.yaml` + this report) | **`13784dc21deac1ec136d29727a1079d90176397c`** |
| parent | `37b863b` (h1: pin base to v0.22.5, remove the memory patch) |
| ref update | `37b863b..13784dc  main -> main` |
| branch state after push | `origin/main == HEAD`, 0 ahead / 0 behind |
| tracked files changed | `factories/sudo-agent/config.yaml`, `docs/P1-B-MEMORY-AND-IDENTITY.md` |
| instance-only file (not committed, by policy) | `factories/sudo-agent/config/sudo-fleet-glm-h1.SOUL.md`, md5 `cabda732f731782aaef8718b4a08ee71` |
| delivered for review | `phase1-out/h2/`: template, h1 SOUL, `souls/` (all five candidates), `config-listing.txt`, this report |
| live fleet touched | none — no deploy, restart, scale, exec, or image rebuild |

*Report revision note: the hash-verification commit that carries this footer is a separate commit on
`main` after `13784dc`; `13784dc` is the one that changes the config.*

---

## Addendum (h2, at `761100a`) — the `setup.sh` item is closed, the live fleet is not

That section used to end with "I did not make it" about `setup.sh:225-226`; it no longer does — the
heading above is now a closed record — and the change itself is history: the two
integers were swept into **`983834f`** ("docs(factory): setup.sh comment no longer claims the base is
`FROM hermes-agent:latest`", author `sudo-fleet-glm-h1`) while h1 was qualifying the pinned base image
in the same file, and **`761100a`** discloses the sweep in `docs/h1-P1-A-REPORT.md:266-267`. Ordering:
`4834260 -> 7321d9a -> a4e2483 -> 983834f -> 761100a`.

I verified the *current* tree instead of the earlier report. `factories/sudo-agent/setup.sh` is md5
`4fe4cd4a8a3214733169ffe2fc40a72b` and the tracked tree no longer holds a live occurrence of the pair:

```
$ git grep -n 'memory_char_limit: 100000' -- .     # run BEFORE this addendum was appended
docs/P1-B-MEMORY-AND-IDENTITY.md:168   (the section above, quoting the old patch)
docs/P1-B-MEMORY-AND-IDENTITY.md:184   (the diff in the section above)
docs/h1-P1-A-REPORT.md:266             (h1 disclosing the sweep)
```

(This addendum quotes the pair too, so re-running that grep now also matches the block below. The
point of the grep was that no *code* file — `setup.sh`, `config.yaml`, `bin/` — matches.)

### The proof, and how to run it without touching the box

Running `setup.sh` naively in a scratch copy is **not safe**: `setup.sh:64` runs
`docker build -t sudo-agent:latest` unconditionally — the `hermes-agent:latest` inspect guard above it
covers only the BASE image — so a plain scratch run retags the live image, and with a reachable cluster
the script then runs `bin/redis-up.sh` against the shared queue Redis. Stub both tools on `PATH` and run
the real script:

```
$ mkdir -p /tmp/pseed/stub && cp /opt/0-0/sudo-fleet/factories/sudo-agent/setup.sh /tmp/pseed/
$ # stub/docker: `info` and `image` exit 0, `build` echoes "skipped" and exits 0;  stub/kubectl: exit 1
$ cd /tmp/pseed && PATH=/tmp/pseed/stub:$PATH DEEPSEEK_API_KEY=sk-not-a-trial-key bash setup.sh
RUN_RC=0
$ grep -n -A7 '^memory:' config.yaml
8:memory:
9-  memory_char_limit: 40000
10-  user_char_limit: 20000
11-  memory_enabled: true
12-  user_profile_enabled: true
13-  write_approval: false
14-  nudge_interval: 1
```

The same harness against the pre-fix file emitted `100000` / `50000` at the same lines, so the check
discriminates rather than always passing.

### Still open: 66 instance configs, none of them moved

The tracked half of P1-B is done; the running fleet is untouched. Each agent's `config/<name>.yaml` is
what its pod reads as `/opt/data/config.yaml`, and every one of those files still carries the old
pair. Measured at `761100a`:

```
$ cd factories/sudo-agent/config && ls *.yaml | wc -l                                       66
$ grep -l 'memory_char_limit: 100000' *.yaml | wc -l                                        66
$ grep -l 'memory_char_limit: 40000'  *.yaml | wc -l                                         0
$ kubectl exec sudo-sudo-fleet-glm-h1-64496fccbf-n594t -c sudo-agent -- \
      grep memory_char_limit /opt/data/config.yaml          ->  memory_char_limit: 100000
  (same on sudo-sudo-fleet-glm-h2 and -h3)
```

The three `kubectl exec` readings above are the observation of the session that wrote this addendum, not
mine. The mount path could not be re-verified from a tracked file: sudo-agent's `up.sh` is not in this
checkout's tracked tree — only in gitignored instance snapshots under
`factories/sudo-agent/glimors/`, where `up.sh:409` mounts `config/<name>.yaml` at
`/opt/data/config.yaml`.

`config/` is gitignored instance material and rewriting 66 running agents' configs is a fleet change,
so it is a dispatch, not a repo edit. Until it happens, an agent whose pod reads its per-agent config
boots on the old budget, and the entry-size instruction has no effect on it.
