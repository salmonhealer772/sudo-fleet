# P2-C — the memory contract: telling an agent what belongs in its memory

Phase 2, brief C. Date 2026-10-28. Author: an engineer on the five-hand team (h3, the
same hand that wrote the plugin-compatibility report in Phase 1).

**Scope of this change:** three tracked files under `factories/sudo-agent/` —
`comm/PERSONA-SNIPPET.md`, `comm/README.md`, `config.yaml`. No image was built, no tag was
re-pointed, and nothing on the cluster was read, exec'd, restarted, scaled or deployed.

---

## 1. The answer, first screen

**Mechanism chosen: B — the persona seed (`comm/PERSONA-SNIPPET.md`), applied to `SOUL.md`
as a factory-managed block on EVERY boot.** Mechanism A (a seeded skill under
`comm/skills/`) was rejected; the reasons are evidence, not preference (§4).

**What the instruction now says**, in four rules, in the agent's own voice:

1. Memory is a small hand-kept notebook, not a log — it is in front of you every session, so
   every entry costs attention forever.
2. Save: durable environment facts, team conventions, **a correction your operator gave you**
   (the highest-value thing you can keep), and the one-line fact that a skill exists when
   working its steps out took real effort — the steps live in the skill, memory keeps the
   pointer.
3. Do not save: the text of a task, the brief you were handed, another agent's message,
   conversational filler — those live in the transcript. **One entry is one fact, a sentence
   or two, roughly 100–300 characters.**
4. When the store is full a save does not land, nothing else in your loop notices, and an
   agent that ignores the refusal keeps working and **quietly stops learning**. Reissue the
   save as ONE batch that frees space and adds the fact.

The section is **1,657 characters** — deliberately an order of magnitude below the 3,000-char
instruction the brief warned about, and about 400 tokens in every turn's context.

**Reach — the honest number.** All **~60** Hermes agents receive it, on **their next restart
on an image built from this commit**: `0 of ~60` today (they run an image whose baked-in
snippet predates this change), `~60 of ~60` after the propagation job recreates them from the
new image. **There is no marker to clear and no PVC surgery**: the block is replaced between
fixed markers on every container boot (`bin/mcp_entrypoint.sh:74-95`). The rejected skill
route would have been **0 of ~60 even after the new image**, because
`/opt/data/.comm-seeded` already exists on every one of their PVCs
(`bin/mcp_entrypoint.sh:60-67`). This is the single most important line in the report for the
propagation job.

**PASS/FAIL.** The mechanism is wired, the instruction is written and rendered as received,
the numbers have two homes and no fourth, and the commit is pushed with `HEAD == origin/main`
(§9). **PASS for the repository half.** The delivery half is by design not in this brief:
the text reaches agents when they run an image containing it, and that is a rebuild + restart
per agent — which the propagation job must do anyway. Nothing here requires a per-PVC step
first, which is exactly the property that makes the propagation cheap. **The delivery half
has since been measured once, end to end, on a recreated sandbox — §12.**

| File | Change | Why |
|---|---|---|
| `factories/sudo-agent/comm/PERSONA-SNIPPET.md` | new section `## Your memory` (+13 lines) | the instruction itself, carried into every agent on every boot |
| `factories/sudo-agent/comm/README.md` | one table row reworded, new section "Why the persona block also carries the memory contract" (+28/−1) | the seed explains itself; names the rejection of the skill route so nobody re-adds it |
| `factories/sudo-agent/config.yaml` | comment above `memory:` rewritten (values untouched) | removes the second copy of the instruction, states which file the agent actually reads, names the two homes of the numbers |

**Left alone on purpose** (and reported because they were dirty in the working tree when I
arrived): `factories/sudo-agent/setup.sh` and `factories/sudo-agent/bin/up.sh` carry another
engineer's **uncommitted** deploy-path work (removal of the hand-built `hermes-agent:latest`
base, `SUDO_AGENT_IMAGE` override). I staged neither file and did not "fix" the diff — see
§8.3.

---

## 2. (a) The diff of every file I changed

```diff
diff --git a/factories/sudo-agent/comm/PERSONA-SNIPPET.md b/factories/sudo-agent/comm/PERSONA-SNIPPET.md
index 2e075ab..956e910 100644
--- a/factories/sudo-agent/comm/PERSONA-SNIPPET.md
+++ b/factories/sudo-agent/comm/PERSONA-SNIPPET.md
@@ -9,3 +9,16 @@ You have three native abilities for talking to your siblings:
 - **`check-agent`** — read a sibling's trail at any depth. This is the single observability read: it answers both "what has it been doing" and "what is it doing right now" from the same trail. Two modes: `full` is the raw event stream (thinking, tool calls, tool results, and more); `compressed` is the plain chat transcript (just the spoken prompts and replies). A depth `n` selects how much — a small number returns the freshest events, `-1` returns everything, and the default is 100.
 
 **How to use them:** ALWAYS load the matching skill (`list-siblings`, `message-agent`, or `check-agent`) before calling its tool — the tool refuses to run otherwise. The skills carry the exact call syntax and when-to-use guidance, so load the skill rather than reconstructing syntax from memory. The point of being in a fleet is that you don't have to do everything yourself — see who's out there, reach out to a sibling by name when it makes sense, and keep the orchestrator/engineer split: if you're a planner, delegate the heavy technical work; if you're an engineer, take the handoff and do the work.
+
+## Your memory
+
+Your memory is a small notebook you keep by hand, not a log of what you did. It is put in front of you at the start of every session, so every entry costs attention on every turn, for as long as it lives there.
+
+Write an entry only when it will still be true — and still worth reading — in a month:
+
+- **Save:** a durable fact about your environment, a convention your team works by, a correction your operator gave you (the highest-value thing you can keep: it was said once and must never need saying twice), and the one-line fact that a skill exists when working its steps out took real effort. The steps live in the skill; memory keeps the pointer.
+- **Do not save:** the text of a task, the brief you were handed, another agent's message, or conversational filler. Those are already in the transcript, and `session_search` reads that. Filing them here is how a previous fleet filled its whole store with re-filed prompts and then stopped learning for nine days while everyone assumed memory was working.
+
+**One entry is one fact** — a sentence or two, roughly 100–300 characters. Entries of thousands of characters mean you are filing messages instead of facts, and the store fills with other people's words.
+
+When your memory is full, a save does not land: an add over budget is refused, and once a store is over budget every later add is refused until space is freed. Nothing else in your loop notices, so an agent that ignores the refusal keeps working and quietly stops learning. When a save is refused, treat that as urgent — reissue it as ONE batch that removes or shortens something stale and adds the new fact in the same call.
diff --git a/factories/sudo-agent/comm/README.md b/factories/sudo-agent/comm/README.md
index 7f35364..1ff51a2 100644
--- a/factories/sudo-agent/comm/README.md
+++ b/factories/sudo-agent/comm/README.md
@@ -16,7 +16,7 @@ Three folders, three layers that must align:
 |---|---|---|
 | **Tool** | `tools/` | the mechanism — the Python CLI backends (baked into the image at `/opt/comm-tools/`) |
 | **Skill** | `skills/` | the procedure — when + how to call each tool (seeded into `$HERMES_HOME/skills/` on first boot) |
-| **Persona** | `PERSONA-SNIPPET.md` | the awareness — applied to `SOUL.md` as a factory-managed block on every boot so the agent knows it has these |
+| **Persona** | `PERSONA-SNIPPET.md` | the awareness — applied to `SOUL.md` as a factory-managed block on every boot so the agent knows it has these tools, and what its memory is for |
 
 ## The three tools
 
@@ -56,3 +56,30 @@ Three folders, three layers that must align:
 
 A fresh engineer is therefore born able to list, message, and check its
 siblings — no post-deploy install, no one-off.
+
+## Why the persona block also carries the memory contract
+
+`PERSONA-SNIPPET.md` has two sections: `## Fleet communication` and `## Your
+memory`. The second one exists because the snippet is the only text in this repo
+that is guaranteed to be in an agent's context on every boot — in both factories,
+with no marker to clear and nothing to load first.
+
+The memory budget (`memory_char_limit` / `user_char_limit`) lives in
+`factories/sudo-agent/config.yaml`, and a YAML comment reaches the maintainer, not
+the model. A budget tells an agent how much room it has; nothing in it says what
+belongs in the store. That is what `## Your memory` says, and it is the whole
+reason it exists: a model-written store whose writer has never been told its shape
+fills with re-filed prompts and then stops accepting writes.
+
+Three rules hold this together:
+
+- **One authored copy.** The text lives here and only here. `config.yaml` points
+  at it rather than repeating it; do not paste it into a skill as well, or the two
+  copies will drift and an agent will believe whichever it read first.
+- **No numbers in the persona text.** The char limits have exactly two homes —
+  `config.yaml` and `setup.sh`'s only-if-absent heredoc — because an agent reading
+  its own budget starts rationing entries against it instead of judging facts.
+- **Skills are the wrong carrier for it.** `comm/skills/` is seeded on FIRST boot
+  only behind `/opt/data/.comm-seeded`, so a new skill reaches no agent that
+  already has a PVC; and skill content is loaded on demand, while this instruction
+  has to be present at the moment the agent decides what to save.
diff --git a/factories/sudo-agent/config.yaml b/factories/sudo-agent/config.yaml
index ec25a14..6b2a3a4 100644
--- a/factories/sudo-agent/config.yaml
+++ b/factories/sudo-agent/config.yaml
@@ -41,11 +41,17 @@ terminal:
 # pair that filled (99,861 chars, 34 entries averaging 2,850) and silently stopped
 # accepting writes. Fix the writer instead.
 #
-# MEMORY INSTRUCTION — what this store is FOR, not how big it may grow:
-#   SAVE      durable facts about the environment, team conventions, a procedure
-#             that took real effort to work out, corrections the operator made.
-#   DO NOT SAVE  task text, a brief someone sent you, another agent's message, or
-#             conversational filler. Transcripts live in session_search, not here.
+# WHAT AN AGENT IS TOLD IS NOT IN THIS FILE — a YAML comment is read by the person
+# editing it, never by the model, and a budget does not tell an agent what belongs
+# in the store. The instruction that shapes what it saves is the persona seed,
+# applied on EVERY boot: comm/PERSONA-SNIPPET.md section "## Your memory" -> baked to
+# /opt/comm/PERSONA-SNIPPET.md -> SOUL.md by bin/mcp_entrypoint.sh:95. Edit it
+# there; do not copy it back here, or the two copies drift.
+#
+# THE NUMBERS have exactly two homes and both must move in the same commit: this
+# `memory:` block, the seed for a NEW agent, and setup.sh's only-if-absent heredoc,
+# so deleting this file cannot resurrect the old pair. Never repeat the numbers in
+# the persona text and never add a third home.
 memory:
   memory_char_limit: 40000
   user_char_limit: 20000
```

Three files, +52/−6 (`git diff --shortstat`). Nothing else of mine is in the tree. The YAML still parses, and the
six memory keys are unchanged (values, not just text — §6):

```
$ python3 -c 'import yaml;d=yaml.safe_load(open("factories/sudo-agent/config.yaml"));print(d["memory"])'
{'memory_char_limit': 40000, 'user_char_limit': 20000, 'memory_enabled': True,
 'user_profile_enabled': True, 'write_approval': False, 'nudge_interval': 1}
```

---

## 3. (c) The instruction as the agent actually receives it

Not "the source lines" — the rendered block. Method: take the **real** `_apply_fleet_block`
out of the real entrypoint (`sed -n '78,95p' bin/mcp_entrypoint.sh`), put the new seed at the
real path it occupies in the image (`/opt/comm/PERSONA-SNIPPET.md`), and run it against a
fresh `SOUL.md`. Extracted output, verbatim (`phase2-out/h3/rendered-block-as-received.md`):

```
<!-- FLEET-COMM-AWARENESS-BEGIN -->
## Fleet communication

You are one agent in a **fleet** of sibling agents. … (unchanged, 2.6 KB)

## Your memory

Your memory is a small notebook you keep by hand, not a log of what you did. It is put in
front of you at the start of every session, so every entry costs attention on every turn,
for as long as it lives there.

Write an entry only when it will still be true — and still worth reading — in a month:

- **Save:** a durable fact about your environment, a convention your team works by, a
  correction your operator gave you (the highest-value thing you can keep: it was said once
  and must never need saying twice), and the one-line fact that a skill exists when working
  its steps out took real effort. The steps live in the skill; memory keeps the pointer.
- **Do not save:** the text of a task, the brief you were handed, another agent's message,
  or conversational filler. Those are already in the transcript, and `session_search` reads
  that. Filing them here is how a previous fleet filled its whole store with re-filed prompts
  and then stopped learning for nine days while everyone assumed memory was working.

**One entry is one fact** — a sentence or two, roughly 100–300 characters. Entries of
thousands of characters mean you are filing messages instead of facts, and the store fills
with other people's words.

When your memory is full, a save does not land: an add over budget is refused, and once a
store is over budget every later add is refused until space is freed. Nothing else in your
loop notices, so an agent that ignores the refusal keeps working and quietly stops learning.
When a save is refused, treat that as urgent — reissue it as ONE batch that removes or
shortens something stale and adds the new fact in the same call.
<!-- FLEET-COMM-AWARENESS-END -->
```

Two whole-file renders are kept beside this report: `rendered-soul-fresh-case.md` (a brand-new
identity, no block yet — append path) and `rendered-soul-upgrade-case.md` (an existing identity
with a stale block — replace path).

---

## 4. (b) The mechanism decision, with the code that decides it

Both candidates were read at the source before choosing. The difference is not stylistic; it
is one `if` and one marker file.

### Mechanism A — skills, seeded on first boot → REJECTED

```
bin/mcp_entrypoint.sh:44-51   # the entrypoint's own design note:
                              #   "(1) SKILLS — seeded into $HERMES_HOME/skills (the PVC) on
                              #    FIRST boot only, guarded by a .comm-seeded marker. …
                              #    the agent may edit them later, so a re-seed every boot
                              #    would clobber its edits."
bin/mcp_entrypoint.sh:60-67   if [ ! -f /opt/data/.comm-seeded ]; then
                                cp -a /opt/comm-skills/. /opt/data/skills/ || true
                                touch /opt/data/.comm-seeded
                              fi
Dockerfile:70                 COPY comm/skills/ /opt/comm-skills/
```

Three separate reasons it is the wrong carrier for *this* text:

1. **It reaches nobody who already has a PVC.** All ~60 running agents have
   `/opt/data/.comm-seeded` on their PVC. A new `comm/skills/memory-…/SKILL.md` ships inside
   the image and is **never copied**, on any restart, on any recreation, until someone deletes
   that marker on that PVC. The brief is right that this matters enormously: the skill route
   is **zero reach**, not "reach on next restart".
2. **It is not present when the decision is made.** A skill's *body* enters context only when
   the model calls `skill_view`. The memory write happens at the end of a turn, unprompted —
   there is no moment at which anything would make the agent load a memory skill first. What
   is always present is the skill's one-line description, which is a pointer, not a rule.
3. **It duplicates the contract.** A skill would be a second authored copy of the same rules
   (the description's first 57 chars are, by the skill-authoring convention, a trigger phrase,
   not a policy). Two copies of a behavioural rule drift, and the agent believes whichever it
   read last.

### Mechanism B — persona seed, applied every boot → CHOSEN

```
bin/mcp_entrypoint.sh:53-59   # the entrypoint's own design note:
                              #   "(2) PERSONA — … applied to SOUL.md as a FACTORY-MANAGED
                              #    BLOCK on EVERY boot (not first-boot-only). It lives between
                              #    fixed BEGIN/END markers; on each boot we replace the content
                              #    between the markers (or insert the block if absent) so the
                              #    agent can never permanently lose or stale its fleet
                              #    awareness … Nothing outside the markers is ever touched."
bin/mcp_entrypoint.sh:78-94   _apply_fleet_block() { … }        # replace-between-markers / append
bin/mcp_entrypoint.sh:95      _apply_fleet_block /opt/data/SOUL.md /opt/comm/PERSONA-SNIPPET.md
bin/mcp_entrypoint.sh:129-151 # fresh-SOUL watcher: polls up to 300 s for the gateway to create
                              # SOUL.md, then applies the same block (the brand-new-pod case)
Dockerfile:71                 COPY comm/PERSONA-SNIPPET.md /opt/comm/PERSONA-SNIPPET.md
Dockerfile:97                 ENTRYPOINT ["/opt/hermes-mcp/mcp_entrypoint.sh"]
```

Everything the brief asks for, and nothing invented:

- **Every boot, not first boot.** `:95` is unconditional in the entrypoint (the only guard
  inside the function is "target file exists"). A restart re-runs it; a rebuilt image ships a
  fresh snippet on the next restart.
- **No stale copy possible.** The awk at `:87-92` replaces everything between the markers, so
  an agent that had an older version of the text gets the new one, and an agent that deleted
  the text gets it back.
- **SOUL.md is the identity document the model reads.** This is not an inference: every agent
  on this team is running the comm block right now, and this report's author has the block in
  its own system prompt — the same block, byte-identical, which is why the Phase 1 brief could
  describe the comm layer to me before I had read any code.
- **It is the only carrier that already exists without touching a file I do not own.** The
  alternative would be a second managed block in `bin/mcp_entrypoint.sh` (a new file, new
  markers, new COPY) — that is a change to two files outside this brief's partition
  (`bin/` and `Dockerfile`, the latter held by another engineer), for a benefit of zero.

### The cost of that decision, stated plainly

`PERSONA-SNIPPET.md` is shared with the **second factory in this repo**: the non-Hermes
(Letta) `up.sh` copies this exact file and applies it to `persona.md`
(`factories/sudo-letta/bin/up.sh:1016` `_fc_snippet="$REPO_DIR/../sudo-agent/comm/PERSONA-SNIPPET.md"`,
applied at `:1028-1049`; documented as a deliberate invariant in `docs/SPEC.md:194` and
`docs/ARCHITECTURE.md:286-288`). **So this section also reaches that factory's agents on their
next deploy.** I kept the text true for both — it names no Hermes-only API except the word
`session_search`, and the "over budget is refused" behaviour is a property of a bounded memory
store, not of one runtime. If the lead wants that coupling cut, the change is one line in
`sudo-letta/bin/up.sh` (point it at a second snippet file) — a file this brief does not give
me, so I did not touch it.

---

## 5. (d) The full code path, seed → agent context

| # | Step | File:line | What it does |
|---|---|---|---|
| 1 | seed committed | `factories/sudo-agent/comm/PERSONA-SNIPPET.md` | the authored text; one copy, in `main` |
| 2 | baked into the image | `Dockerfile:71` `COPY comm/PERSONA-SNIPPET.md /opt/comm/PERSONA-SNIPPET.md` | not shadowed by the `/opt/data` PVC, so it is always the image's copy |
| 3 | image entrypoint | `Dockerfile:97` `ENTRYPOINT ["/opt/hermes-mcp/mcp_entrypoint.sh"]` | `up.sh` runs it with args `["gateway","run"]`; it is the pod's entrypoint, every boot |
| 4 | block applied | `bin/mcp_entrypoint.sh:95` (+ `:78-94` the function, `:96` chown) | replaces content between `<!-- FLEET-COMM-AWARENESS-BEGIN/END -->` in `/opt/data/SOUL.md`, or appends the block |
| 5 | brand-new pod | `bin/mcp_entrypoint.sh:129-151` | if `SOUL.md` does not exist yet (gateway creates it after the entrypoint starts), a background watcher applies the same block the moment it appears |
| 6 | model context | `/opt/data/SOUL.md` is the agent's persona | injected into the system prompt every turn — the mechanism the whole fleet already runs on |

Proof that step 4 does what I claim, run against the real function (not a re-implementation):
`sed -n '78,95p' bin/mcp_entrypoint.sh` extracted verbatim, seed at `/opt/comm/PERSONA-SNIPPET.md`,
stub `SOUL.md` with a stale block plus hand-written text after `END`:

```
=== extracted function (first line, last line) ===
_apply_fleet_block() {
_apply_fleet_block /opt/data/SOUL.md /opt/comm/PERSONA-SNIPPET.md

=== CASE 1: before ===
281 /opt/data/SOUL.md
=== CASE 1: after one boot (bytes) ===
4424 /opt/data/SOUL.md
=== CASE 1: idempotence, boot1 vs boot2 md5 (must be identical) ===
4345fae42a86b1a4c122dd787c5e7bf5  /tmp/boot1.md
4345fae42a86b1a4c122dd787c5e7bf5  /opt/data/SOUL.md
=== CASE 1: stale line gone? (expect 0) ===
0
=== CASE 1: hand-written tail still present? (expect 1) ===
1
=== CASE 2: fresh SOUL after first boot (bytes, then block count) ===
4343 /opt/data/SOUL.md
1        # exactly one BEGIN marker: no duplicate block
1        # "## Your memory" present
```

So: the stale copy is replaced, a second boot changes nothing (idempotent), text outside the
markers survives, and a fresh identity gets exactly one block with the new section.

**What must be true for an agent to receive it:** the pod runs an image built from a commit
containing this file. That is all. No PVC marker, no SOUL deletion, no per-agent config edit.

---

## 6. (e) Reach, stated as a number

| Question | Answer |
|---|---|
| Of the ~60 Hermes agents now running, how many get the instruction on their next **restart, with their current image**? | **0.** The snippet is read from `/opt/comm/PERSONA-SNIPPET.md` *inside the image*; the image they run predates this commit. |
| …on their next restart after being recreated on an image built from this commit? | **~60 of ~60, with no further step.** The entrypoint replaces the block between the markers on every boot. **Measured once, on one recreated agent — §12.** |
| …if I had chosen the skill route? | **0 of ~60, even on the new image**, until `/opt/data/.comm-seeded` is deleted on each PVC. That is the trap this decision avoids. |
| What does the propagation job have to do about it? | Exactly one thing, and it is already on its list: recreate each agent from the new image. **No marker step, no memory-file move for the instruction** (the legacy memory archive is a separate concern). |

The **budget** is a different reach question, and it belongs to the propagation job, not to
this instruction. Per-agent configs are instance state and were seeded once, on first deploy:

```
$ cd factories/sudo-agent/config && ls *.yaml | wc -l                      66
$ grep -l 'memory_char_limit: 100000' *.yaml | wc -l                       65
$ grep -l 'memory_char_limit: 40000'  *.yaml | wc -l                        1
$ grep -n -A2 '^memory:' <agent>.yaml        # any of the 65
7:memory:
8-  memory_char_limit: 100000
```

So 65 of 66 per-agent configs still carry the old budget; the one exception is the config the
sandbox recreate is already setting. **The instruction reaches an agent before its budget
does** — and that is the safe order: an agent told what belongs in memory with a 100,000-char
budget writes better entries immediately; an agent with 40,000 and no instruction would just
fill it more slowly.

---

## 7. (f) Consistency with the Phase 1 SOUL section

That section (`## What goes in memory`, written in Phase 1) exists on **one gitignored
per-agent SOUL file** — which is precisely why the reach problem existed. Side by side, the
two say the same thing; the later one is the one that reaches everyone:

| Rule | Phase 1 SOUL section (1 agent, instance-only) | This persona block (all agents, in `main`) |
|---|---|---|
| what the store is | "small, hand-kept stores, not a log" | "a small notebook you keep by hand, not a log" |
| save | "durable facts about this box and the repo, conventions the team works by, … any correction the operator made to you" | "a durable fact about your environment, a convention your team works by, a correction your operator gave you (the highest-value thing…)" |
| do not save | "the text of a task, a brief someone sent you, another agent's message, or conversational filler … already in the transcript, which `session_search` reads" | "the text of a task, the brief you were handed, another agent's message, or conversational filler … already in the transcript, and `session_search` reads that" |
| entry size | "One entry is one fact: a sentence or two, 100-300 characters … the store will fill and stop accepting writes" | "**One entry is one fact** … roughly 100–300 characters … a full store refuses every later add … quietly stops learning" |

Same four rules, same register, same store. No contradiction on any point, and an agent that
has both reads the same policy twice — acceptable, because the SOUL section is *instance*
material that will disappear for the other ~55 agents anyway.

Three things in the neighbourhood that I did **not** silently diverge from, but which the lead
should rule on:

1. **The brief's wording "writes start being dropped SILENTLY" is not exactly what v0.22.5
   does, and I wrote what the code does instead.** In `tools/memory_tool_store.py` (tag
   `v0.22.5`), an add that would exceed the budget returns an `over_budget` error *to the
   model*, with the current entries and usage so it can consolidate
   (`:322-325`, `_failure_with_entries`), and the tool's own description says "IF FULL: an add
   is rejected with the current entries shown. Reissue as ONE batch…" (`tools/memory_tool.py:391-393`).
   The silent part is elsewhere and is worse: after **3** failed consolidation attempts in one
   turn (`_MAX_CONSOLIDATION_FAILURES_PER_TURN = 3`, `:184`) the tool returns a *terminal*
   "Stop retrying memory calls — leave memory unchanged for now" result (`:204-219`) and the
   turn proceeds. A store that is already over budget on load blocks every later add with only
   a server-side warning, "no visible cause" to the agent (`:246-252`). That is the mechanism
   that cost the last generation nine days: not one silent write, but a refusal the agent
   walked away from, 3 turns at a time. My text says exactly that, and keeps the brief's
   punch ("quietly stops learning", "nine days"). **I did not put the word "silently" on the
   refusal itself, because an agent that believes refusals are invisible will not read the one
   it gets.**
2. **Procedures: Phase 1 says save them, the stock tool description says don't.** The SOUL
   bullet says "a procedure that took real effort to work out"; v0.22.5's memory tool
   description says the opposite — "Anything learned while doing a task (procedures, pitfalls…)
   belongs in the task's skill via skill_manage … memory is injected into every turn and must
   stay small" (`tools/memory_tool.py:385-390`). My section resolves it in one clause rather
   than picking a side: *"the one-line fact that a skill exists when working its steps out
   took real effort. The steps live in the skill; memory keeps the pointer."* That agrees with
   the platform and does not contradict the SOUL bullet, but the SOUL bullet is still the
   looser statement — worth tightening when that file is next touched.
3. **Phase 1's config comment carried a second copy of the instruction.** I replaced that copy
   with a pointer to the persona section. A YAML comment that restates a policy is the same
   class of bug as a budget with no writer: two sources, one of which is never read by the
   model and both of which drift. The pointer is the fix; the "do not raise these back to
   100000/50000" deterrent is untouched.

---

## 8. The numbers: two homes, one map, no fourth

**The decision is 40000 / 20000. I did not change it.**

| Where | File:line | Role | Rule |
|---|---|---|---|
| **canonical** | `factories/sudo-agent/config.yaml:56-57` | the seed a **new** agent's config is copied from; the file Hermes reads for a fresh install | change here first |
| second home | `factories/sudo-agent/setup.sh:227-228` | heredoc that writes `config.yaml` **only when it is absent** (the deleted-template path) | must change in the **same commit**, or deleting/moving the template silently resurrects the old numbers |
| the map | `factories/sudo-agent/config.yaml:36-54` (comment above the block) | tells a maintainer both of the above and why the budget is large | states the rule; carries no instruction text any more |

What a maintainer must do to move the number: change `config.yaml:56-57` **and**
`setup.sh:227-228` in one commit, then (for running agents) rewrite the per-agent
`config/<agent>.yaml` memory block — instance state, 65 of 66 still at the old pair, owned by
the propagation job, not by this file.

Proof there is no fourth home, and that my text adds none:

```
$ grep -n '40000\|20000\|100000\|50000' factories/sudo-agent/comm/PERSONA-SNIPPET.md
NONE
$ grep -rn '40000\|20000' factories/sudo-agent/comm/
NONE
$ git grep -n 'memory_char_limit: \|user_char_limit: ' -- .
factories/sudo-agent/config.yaml:56:  memory_char_limit: 40000
factories/sudo-agent/config.yaml:57:  user_char_limit: 20000
factories/sudo-agent/setup.sh:227:  memory_char_limit: 40000
factories/sudo-agent/setup.sh:228:  user_char_limit: 20000
```

(The other hits are prose in dated Phase 1 reports, which are records of measurements, not
configuration.) I also wrote the rule into `comm/README.md` and into the `config.yaml` comment
— *never repeat the numbers in the persona text, never add a third home* — so the next person
adding a memory sentence knows not to drag the numbers along with it.

The persona text deliberately contains **100–300 characters** (the entry-size guardrail) and
not the budget: an agent that knows its own budget starts rationing entries against it instead
of judging facts, which is the failure mode this whole change is about.

---

## 9. What I deliberately did not change

1. **The numbers.** 40000/20000 stands. I was asked to make them consistent and obvious, not
   to re-decide them.
2. **`setup.sh` and `bin/up.sh`.** Both were **already dirty** in the shared checkout when I
   arrived — another engineer's uncommitted deploy-path work (removing the hand-built
   `hermes-agent:latest` base; adding a `SUDO_AGENT_IMAGE` override so a build can be verified
   without re-pointing the live tag). I read the diff, confirmed `setup.sh:227-228` still reads
   40000/20000 in the working tree, and **staged neither file**. Committing them would have
   attached someone else's work to my commit; reverting them would have destroyed it.
3. **`Dockerfile`.** Not mine, and not needed: `comm/skills/` and
   `comm/PERSONA-SNIPPET.md` are already `COPY`d at `:70-71`, so the seed ships without a
   Dockerfile change. A second managed block *would* have needed one — which is one of the
   reasons it was not the right mechanism.
4. **`bin/mcp_entrypoint.sh`.** Same reasoning: the block mechanism already exists, and it
   reads the file I extended. No code change was required to carry persona-level text, which
   is the whole point of choosing the mechanism that already exists over inventing one.
5. **A new skill under `comm/skills/`.** Rejected in §4 — it would reach zero agents and
   duplicate the contract.
6. **Per-agent SOUL files.** Only five exist, all gitignored instance material; writing them
   is not the seed route and the public repo must not carry agent identities.
7. **Per-agent configs** (66 gitignored files): not mine, and the propagation job owns them.
8. **Any README other than `comm/README.md`.** The top-level and factory READMEs belong to the
   documentation pass.
9. **The cluster.** See the last section.

---

## 10. (g) One line on the cluster

No cluster access of any kind: nothing was exec'd into, restarted, scaled, deployed or read
from any pod; no image was built, and no tag — `sudo-agent:latest` least of all — was created,
moved or re-pointed. Every command in this report ran in a throwaway container against the git
checkout or the research directory on the host.

---

## 11. Push

| item | value |
|---|---|
| branch | `main` (no rebase, no force-push, no history rewrite) |
| staged by explicit path | `factories/sudo-agent/config.yaml`, `factories/sudo-agent/comm/PERSONA-SNIPPET.md`, `factories/sudo-agent/comm/README.md`, `docs/P2-C-MEMORY-CONTRACT.md` |
| not staged | the ~18 pre-existing untracked files in the checkout, and the two files another engineer has modified (`setup.sh`, `bin/up.sh`) |
| HEAD after push | recorded in the footer commit that follows this one — see "PUSHED AS" below |

### PUSHED AS — confirmed, not attempted

| item | value |
|---|---|
| code + report commit (this document) | **`afef43e21ac594eeddbecc96a62b4a16d0d1637c`** |
| commit subject | `seed the memory contract into every agent's persona` |
| ref update | `1ebbed3..afef43e  main -> main` |
| `git ls-remote origin main` | `afef43e21ac594eeddbecc96a62b4a16d0d1637c\trefs/heads/main` |
| `git rev-parse HEAD` | `afef43e21ac594eeddbecc96a62b4a16d0d1637c` |
| branch state after push | `git rev-list --left-right --count origin/main...HEAD` → `0  0` |
| `git diff --cached --name-status` before commit | `A docs/P2-C-MEMORY-CONTRACT.md`, `M comm/PERSONA-SNIPPET.md`, `M comm/README.md`, `M config.yaml` — exactly four, nothing swept in |
| left uncommitted on purpose | another engineer's in-progress work (`setup.sh`, `bin/up.sh`), the documentation pass's `docs/` + `README.md` edits, and the ~18 pre-existing untracked files |

Read back **from the remote ref**, not from the working tree (`git show origin/main:<path>`
after `git fetch`):

```
PERSONA-SNIPPET.md  '## Your memory' occurrences: 1
PERSONA-SNIPPET.md  lines: 24
config.yaml         40000/20000:   memory_char_limit: 40000   user_char_limit: 20000
comm/README.md      new section: 1
docs report         bytes: 34284

100644 blob 787a411c1352084e8a6690bfcfbea80d125173e2    docs/P2-C-MEMORY-CONTRACT.md
100644 blob 956e9101aef9017809ac342d190b3ed014d83af4    factories/sudo-agent/comm/PERSONA-SNIPPET.md
100644 blob 1ff51a2f5056a477c284922a8b70053fa4820202    factories/sudo-agent/comm/README.md
100644 blob 6b2a3a4c84f38b18c949dbee6099cee127425eae    factories/sudo-agent/config.yaml
```

This footer is a second, later commit (`docs(P2-C): confirm the push`) on `main`: a report
cannot contain the hash of the commit that first carries it. Everything above describes
`afef43e`, which is the commit that changes behaviour; the footer commit only edits this file.

---

## 12. The delivery half, measured — STEP 7 on a recreated sandbox

§1 signs off the repository half and calls the delivery half out of scope. It is no longer
untested. This section records the first end-to-end delivery of *this* block to an agent
that already had a past, and every number below is my own read-only re-measurement taken at
**19:56Z on 2026-10-28**, not a copy of another hand's write-up. h2's pass on the same pod
is `737a181` (`docs/P2-B-SANDBOX-RECREATE.md` §7 and §12.3); this section reads the same
facts again, independently, and lands on the same two load-bearing digests (§12.5 notes
where two cosmetic values in that write-up differ from what the file says).

### 12.1 The object measured

| item | value |
|---|---|
| pod | `sudo-mail-bot-hermes-66f565699b-lrfsz`, `2/2 Running`, restarts `0`, age 15 min |
| image, both containers | `sudo-agent:p2a-h1` |
| annotation `sudo-agent/image-sha` | `sha256:ebc56f72e84a2342b59344fdb413534e998420b69c0b12ea7e6b504ed63edbf9` |
| `hermes --version` in the pod | `Hermes Agent v0.22.5 (2026.9.24) · upstream bf0203a7` |
| what it was before | an agent with a past: 411 pre-upgrade sessions (P2-B §12.1), `.comm-seeded` 2026-09-30 and 18 of its own skills (both measured here) |

A genuine recreate on h1's throwaway image tag — the pod is 15 minutes old, and the PVC it
booted against is the one the agent had before (P2-B §3 states that baseline; P2-B §12.1
re-counts it after).

### 12.2 The answer: yes — and only inside the markers

```
$ kubectl exec … -c sudo-agent -- sh -c \
    'wc -c /opt/data/SOUL.md; md5sum /opt/data/SOUL.md;
     grep -n "FLEET-COMM-AWARENESS\|## Your memory" /opt/data/SOUL.md;
     grep -c "## Your memory" /opt/data/SOUL.md; ls -l /opt/data/.comm-seeded'
9559 /opt/data/SOUL.md
62e1be7a40585e729c2704b8c19ef77c  /opt/data/SOUL.md
54:<!-- FLEET-COMM-AWARENESS-BEGIN -->
67:## Your memory
79:<!-- FLEET-COMM-AWARENESS-END -->
1
-rw-r--r-- 1 root root 0 2026-09-30 04:47 /opt/data/.comm-seeded
$ ls /opt/data/skills | wc -l
18
```

- `## Your memory` appears **exactly once**, at **line 67**, strictly between the BEGIN (54)
  and END (79) markers. It is inside the block the entrypoint owns, not appended after it.
- **9,559 bytes** is exactly the post-upgrade size §6 recorded on the same agent — the
  delivery did not depend on that measurement, it reproduces it.
- **No PVC surgery, no marker deletion, no per-agent config edit** produced this. The only
  writer is `bin/mcp_entrypoint.sh` on boot, which is the mechanism §4 chose.

### 12.3 Two byte-level proofs: current text, and nothing else moved

(a) **The block on the PVC is the committed snippet, not a stale baked copy.** Take the
24 lines between the markers and digest them:

```
$ block = SOUL.md lines 55..78, between the markers     # 4,195 bytes, 24 lines
$ sha256(block)                7c1420eb7393c86b13d0f985d37bf30787c90b1ec32ce4b814f5d415d817b9b7
$ git show HEAD:factories/sudo-agent/comm/PERSONA-SNIPPET.md | sha256sum
                               7c1420eb7393c86b13d0f985d37bf30787c90b1ec32ce4b814f5d415d817b9b7
$ block == HEAD blob, byte for byte:  True
```

Equal — so the text that landed is the text `main` ships *today*, including the `## Your
memory` section. A stale snippet baked into an older image would have produced a different
digest here; the persona block is re-copied and re-rendered on every boot, so "the image is
old" is not a defence this mechanism can hide behind.

(b) **Everything outside the block is still the pre-upgrade file.** The pre-upgrade snippet
is still in git, so the agent's own persona can be rebuilt and hashed without the old PVC:

```
$ pre  = SOUL.md lines 1..54   (through BEGIN)
$ post = SOUL.md lines 79..    (END and after)
$ rebuilt = pre + $(git show afef43e^:factories/sudo-agent/comm/PERSONA-SNIPPET.md) + post
  7,891 bytes   md5 721754026f924d2079a37f0d323c6d22
```

7,891 bytes and that md5 are exactly the values §6 captured on the pod *before* the
recreate. So the only bytes that changed on `/opt/data/SOUL.md` are the 13 lines the
snippet itself grew by; the persona around them is untouched, and 7,891 → 9,559 (+1,668) is
the snippet's own growth, not reconstruction drift.

### 12.4 The contract is being followed in practice, not just installed

The first real turn after the recreate wrote **one** entry, **115 characters**, at 19:41Z:

```
$ wc -c /opt/data/memories/MEMORY.md     →  115      mtime 2026-10-28 19:41
```

That is inside the band the section asks for (`one fact, a sentence or two, roughly 100–300
characters`) and it is one entry, not a log. One observation is not compliance, but it is
the right shape on the first attempt, which is more than the instruction alone can promise.

### 12.5 Two cosmetic values in h2's write-up, and why they do not weaken it

| value | h2's text (`737a181`) | measured here |
|---|---|---|
| line of `## Your memory` | 66 | **67** (1-based `grep -n`; 66 is its 0-based index) |
| block size | 4,165 chars | **4,195 bytes** |

Both sit inside h2's §12.3, next to the digest that *is* the proof; the digest and the
reconstruction md5 both reproduce exactly, so the conclusion stands unchanged. The line
number is flagged rather than edited because `docs/P2-B-SANDBOX-RECREATE.md` is h2's file —
the partition holds even for a one-character correction.

Both have since been applied — by h2, in `550f2a8` (`docs(P2-B)`: 12.3 — the block is
4,195 bytes and `## Your memory` is line 67), 9 insertions and 2 deletions on that one file and
nothing else, `HEAD` == `origin/main` == `550f2a8` when re-checked from this side. The table above
stays as it was written: it is the pre-correction snapshot against `737a181`, and the edit belongs
to the file's owner rather than to this document's author.

### 12.6 What this changes in the reach table, and what it does not

- §6's second row — `~60 of ~60, with no further step` — stops being only a projection: it
  now has **one measured instance**, on an agent that had a `.comm-seeded` dated 2026-09-30
  and 18 skills of its own.
- The rejection of Mechanism A is now **observed**, not merely reasoned: that marker and
  those 18 skills are still there after the recreate, so a skill shipped in the new image
  would have delivered nothing. The persona block is what delivered.
- It does **not** move the number for the other ~59. They are still `0 of ~59` until their
  own recreate; one instance shows the mechanism works, not that the population has been
  reached. §6's first row stands.
- It does not change §10. **This section's cluster access was read-only**: `kubectl get`,
  and `exec` running `cat`, `wc`, `md5sum`, `grep`, `ls` — nothing written to any pod, PVC,
  config, deployment or image. The two files used for the hashing were written to the host's
  `/tmp` and removed afterwards.

### 12.7 Push

| item | value |
|---|---|
| commit carrying this section | **`7c584b85a8e7a19b9ff7973ae86b665164eb3c7b`** |
| subject | `docs(P2-C): record STEP 7 - the block lands on a recreated agent, measured` |
| parent / ref update | `366fd16..7c584b8  main -> main` |
| `git ls-remote origin main` | `7c584b85a8e7a19b9ff7973ae86b665164eb3c7b\trefs/heads/main` |
| `git rev-parse HEAD` | `7c584b85a8e7a19b9ff7973ae86b665164eb3c7b` |
| branch state after push | `git rev-list --left-right --count origin/main...HEAD` → `0  0` |
| staged | `M docs/P2-C-MEMORY-CONTRACT.md` — one file; the ~20 pre-existing untracked files were not staged |

Read back **from the remote ref**, not the working tree:

```
$ git show origin/main:docs/P2-C-MEMORY-CONTRACT.md | grep -c '^## 12. The delivery half'
1
$ git show origin/main:docs/P2-C-MEMORY-CONTRACT.md | wc -c
42404
$ git ls-tree origin/main docs/P2-C-MEMORY-CONTRACT.md
100644 blob 8a8e3dc6b38ba6033373fb40ec524da3ee640bb2    docs/P2-C-MEMORY-CONTRACT.md
```

This footer is a third commit (`docs(P2-C): confirm the STEP 7 record with the pushed
hash`), for the same reason as §11's: a section cannot contain the hash of the commit that
first carries it. Everything above describes `7c584b8`.
