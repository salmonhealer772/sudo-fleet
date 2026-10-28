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

## A second place still carrying the old numbers — needs an owner

`git grep` across tracked files after my commit:

```
$ git grep -n "memory_char_limit\|user_char_limit" -- .
factories/sudo-agent/config.yaml:50:  memory_char_limit: 40000
factories/sudo-agent/config.yaml:51:  user_char_limit: 20000
factories/sudo-agent/setup.sh:225:  memory_char_limit: 100000
factories/sudo-agent/setup.sh:226:  user_char_limit: 50000
(+ the same strings inside docs/P1-B-MEMORY-AND-IDENTITY.md, which is this report)
```

`setup.sh:67` sets `CONFIG_FILE="$SCRIPT_DIR/config.yaml"` and `setup.sh:217` writes that file from a
heredoc **only when it does not exist**. Because `config.yaml` is tracked, a normal clone has it and
the branch never fires — so this is a landmine, not a live bug: delete or move the template and
`setup.sh` recreates it with 100000/50000 and my change is silently gone. It is the same class of
flaw as the one this brief exists to fix, and it is a two-line change:

```diff
--- a/factories/sudo-agent/setup.sh
+++ b/factories/sudo-agent/setup.sh
@@ -222,8 +222,8 @@
 memory:
-  memory_char_limit: 100000
-  user_char_limit: 50000
+  memory_char_limit: 40000
+  user_char_limit: 20000
   memory_enabled: true
```

**I did not make it.** `setup.sh` is not in P1-B's owned paths (the plan gives h1 the Dockerfile,
the patch and `up.sh`; nobody holds `setup.sh`), and the file-partition rule is explicit that
touching an unowned file means going back to the planner. So it goes back to you: either fold those
two lines into the final commit, or hand them to h1. Flagged to h1 as well.

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
