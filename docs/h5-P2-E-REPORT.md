# H5 / P2-E — does a stranger get a working agent from what is written down?

Phase 2, brief E (documentation). Date 2026-10-28. Author: h5, one of the five
engineers on the sudo-fleet-glm team.

> **Post-push correction, 2026-10-28 — the `jq` findings below are historical.**
> Two commits landed after this report was pushed and make its central code gap
> false at HEAD. **`4918ca2`** ("fix(bootstrap): install jq and drop instance
> names from Command 1") adds step `2/5 Bootstrap: Docker + jq` to `setup.sh`,
> which installs `jq` on apt boxes and hard-stops with the install line when it
> cannot. **`898b6bc`** ("fix(up.sh): fail fast when jq is missing instead of
> dropping operator env") adds the matching guard to
> `factories/sudo-agent/bin/up.sh`, so a `jq`-less host aborts the deploy instead
> of silently emptying the operator-env preserve-set.
>
> Read every "`setup.sh` does not install `jq`" sentence below as what was true
> when this pass measured it (before `4918ca2`); the transcripts in §6.5 are left
> verbatim for that reason, with the current counts beside them. The doc clauses
> this report added were already right and needed no further edit:
> `README.md:12-17` and `docs/OPERATIONS.md:12-16` state the prerequisite and
> that `setup.sh` installs it on apt boxes.

**What this brief did NOT do:** nothing was built, tagged, deployed, restarted,
scaled or exec'd. No `kubectl`. The danger in this phase is a build re-pointing
`sudo-agent:latest`, which ~60 live deployments pin with
`imagePullPolicy: IfNotPresent`; this run never invoked `docker build`. The
tools that produced the evidence below are `grep`, `sed`, `awk`, `ls`,
`bash -n`, `git`, a link checker written for this pass over the docs tree, and
one `docker run` of a stock `ubuntu:24.04` to measure what a clean box has.

---

## 1. First screen

- **Claims fixed: 46 edits across 13 files** — both READMEs, `docs/` (nine files
  edited), `factories/sudo-agent/DESIGN.md`, and two usage blocks in `bin/`
  (`verify-change.sh`, `paperclip-hire.sh`) that named this fleet's agents as if
  they were the defaults. Each is in §3 with the command that verifies the new
  sentence.
- **Claims left, with doubt: 6** — §5, each quoted, with why it was left.
- **The three-command install path, in one line:** the README now describes
  Command 1 and Command 2 accurately (bootstrap vs deploy, `sudo-planner` /
  `sudo-engineer`, empty brains by default), and Command 3 accurately —
  **including the host prerequisite nobody had written down, `jq`, which
  `talk.sh` requires and `setup.sh` did not install when this pass ran** (fixed
  after this report shipped, in `4918ca2` — see the banner at the top). With `jq`
  present the sequence is coherent end to end; without it the third command fails
  on a stock box. That is now stated in the README instead of hidden. The
  separate question — does the install path build the same image the deploy path
  runs — was measured by h1 as **identical** (53 identical layer digests, §4.2).
- **Verdict: a stranger can now follow the docs to a running pair, and cannot
  yet do it on a bare box without one extra install.** Clone → bootstrap →
  deploy is described correctly and the pages that said "this cannot work" are
  gone. Of the two code blockers this pass named, one has since been closed in
  code: `jq` **is** installed by Command 1 as of `4918ca2` (§4.1), so the extra
  install line is belt-and-braces rather than load-bearing. The other still
  stands: Command 2's own closing advice (`bash bin/k8s-down.sh`) is wrong from
  the directory Command 2 leaves you in (§4.3).

---

## 2. What Phase 1 invalidated, and where the docs still said the old thing

Phase 1's report named one stale sentence
(`factories/sudo-agent/README.md:158`, the deleted `patch_memory_review.py`). It
was not one sentence. The pattern: a Phase 1 finding was recorded in a *report*,
and the *reference pages* kept describing the old world. This pass fixed the
reference pages.

| # | Phase 1 change | Where the docs still said the old thing |
|---|---|---|
| 1 | `patch_memory_review.py` deleted; memory is Hermes-native and model-written | `sudo-agent/README.md` (rebuild rule; "everything you tell it gets stored"), `DESIGN.md` ("100k + 50k", "saves automatically"), root `README.md` ("memory: fresh each task") |
| 2 | Base pinned to `nousresearch/hermes-agent:v0.22.5` | `ARCHITECTURE.md` §1 ("built on `hermes-agent:latest`"); the factory README never stated the pin at all |
| 3 | Deploy path rebuilt (single build from the Dockerfile, build-on-missing) | `ARCHITECTURE.md` §9 step 5; `sudo-agent/README.md`'s rebuild rule |
| 4 | `k8s-up.sh` repaired (`07d5d77`): defaults `planner`/`engineer`, seed optional, no fixed Marc/Caesar | `ARCHITECTURE.md` §1 note "Command 2 currently cannot complete (D1)", `OPERATIONS.md` §2.1, `REPOSITORY-VS-INSTANCE.md`, `SPEC.md`, `KNOWN-ISSUES.md` D1, `PAPERCLIP.md` (Marc/Caesar/ONalwase) |
| 5 | `deployments/` emptied of identities; instance material gitignored | `ARCHITECTURE.md` §1 ("holds `ONalwase/` and `Talker/` — live agent identities, committed") |

---

## 3. The table of claims

`Said` is the text at HEAD `1ebbed3` (plus h3's `5c5faa7` for the memory files);
`Now` is what the file says after this pass. Every "verified by" was run in this
session at this checkout; the outputs are in §6.

### 3.1 `README.md` (the stranger's entry point)

| # | Said | Now | Verified by |
|---|---|---|---|
| 1 | "Asks for one LLM API key and an optional web-search key" | names the prompts: LLM API key, LLM base URL (blank = provider default), optional web-search key | `grep -n '_ask "' setup.sh` → `:190`, `:231`, `:270` |
| 2 | "Deploys a Letta planner and a Hermes engineer, with their storage and network wired." | names `sudo-planner` / `sudo-engineer`; the Paperclip step is attempted and non-fatal; a fresh clone ships no identity, so both start empty-brained | `k8s-up.sh:30-33`, `:264-281`, header `:9-14` |
| 3 | `sudo bash bin/talk.sh --planner` + "Run it from the repo root" — after Command 2 (`cd bin`) this resolves to `bin/bin/talk.sh` | `cd .. && sudo bash bin/talk.sh --planner`, plus "it needs a real terminal" and why | `talk.sh:38`, `:50`; `k8s-up.sh:23` |
| 4 | "You are in front of a working agent with persistent memory, tools, and a teammate" | same, plus "both agents start with an empty brain — the repository ships no saved identity" | `ls deployments/` → `README.md`; `k8s-up.sh:9-14` |
| 5 | ENGINEER memory: "fresh each task" | "persistent, self-written", with a paragraph naming both stores and the 40000/20000 budget | `config.yaml:56-57`; `docs/P2-C-MEMORY-CONTRACT.md` §1 |
| 6 | Docs index: 7 files, "All of it lives in `docs/`" | adds `DOC-FACTS.md`, points at `docs/README.md` as the full index, mentions the phase records | `ls docs/` (18 files) — §7 |
| 7 | "Pod spec needs `k8s-up.sh` again" | "re-run that factory's `bin/up.sh --<name>`" — `k8s-up.sh` deploys the pair | `k8s-up.sh:213-224`; `OPERATIONS.md` §2.4 |
| 8 | No prerequisites at all; "Three commands. That is the whole install." | "Three commands after one prerequisite": systemd, `curl`, `git`, `sudo`, and **`jq`**, with the one-line install | §4.1, §6.5 |
| 9 | "Every folder, one line each:" — lists 9 of ~20 | "The folders you will touch first (COMPONENTS.md covers every directory)" | `git ls-files` in a fresh clone: `factories/sudo-gws/`, `factories/paperclip-*`, `bin/hooks/`, `tests/`, `logs/`, `down.sh` all exist and were unlisted |

### 3.2 `factories/sudo-agent/README.md`

| # | Said | Now | Verified by |
|---|---|---|---|
| 10 | "**Auto memory** — everything you tell it gets stored. No commands, no prompts, no opt-in." | "Memory the agent writes itself": `MEMORY.md` / `USER.md` on the PVC, 40000/20000 budget, the model decides, nothing dumps whole messages; plus where the instruction actually lives (`comm/PERSONA-SNIPPET.md` §"Your memory", not the YAML) | `config.yaml:56-57`; `comm/PERSONA-SNIPPET.md:13`; h4's build result (patch absent, no `store.add`) |
| 11 | Quick Start assumed an existing cluster without saying so | states these are factory-level commands needing Docker + k3s, and names Commands 1 and 2 | `factories/sudo-agent/setup.sh:15-19`; `bin/up.sh` needs `kubectl` |
| 12 | "Run local LLMs — DeepSeek API only" | any OpenAI-compatible endpoint works via `LLM_BASE_URL` / `LLM_PROVIDER` / `LLM_MODEL`; the image ships no weights | `setup.sh:120-149`; `config.yaml:16-31` |
| 13 | **the F6 sentence**: "Changing `mcp_server.py`, `mcp_entrypoint.sh`, `hermes_prompt.py`, `Dockerfile` or `patch_memory_review.py` means the image must be rebuilt … `up.sh` refuses …" | split into **what is enforced** (three `COPY`d files, digest-compared, mismatch = exit 1, `SUDO_AGENT_ALLOW_STALE_IMAGE=1` overrides) and **what is not** (`Dockerfile`/`comm/`/`meta-data/` — timestamp note only); a missing image is built by `_ensure_image_built`; base pinned | `bin/up.sh:1353` `_src_digest`, `:1359` `_image_digest`, `:1367` `_assert_image_fresh`, `:1320` `_ensure_image_built`; `Dockerfile:15` |
| 14 | `**One command. Hermes Agent with **privileged** root…**` (broken bold) | `**One command.** Hermes Agent with **privileged** root…` | rendered text |

### 3.3 `docs/ARCHITECTURE.md`

| # | Said | Now | Verified by |
|---|---|---|---|
| 15 | "(`sudo-agent:latest`, built on `hermes-agent:latest`, …)" | "built `FROM nousresearch/hermes-agent:v0.22.5` — a pinned release tag, not `:latest`" | `Dockerfile:15` |
| 16 | Command 2 "deploys Marc (Letta planner) and Caesar (Hermes engineer) through … `--from-glimor`" | starter pair `planner`/`engineer` → `sudo-planner`/`sudo-engineer`; `--from-glimor` **only when** `deployments/<Name>/` exists | `k8s-up.sh:30-33`, `:37-41`, `:213-224` |
| 17 | "`deployments/` … holds two packages, `ONalwase/` and `Talker/` … live agent identities, committed to the factory repository" | holds only `README.md`; `.gitignore` excludes `deployments/*/`; a saved identity is instance material | `ls deployments/`; `.gitignore` |
| 18 | The D1 note: "Command 2 currently cannot complete", three retries, "Caesar is never reached" | what a fresh clone actually deploys (no seed), and the real guard: a named-but-missing seed aborts before `kubectl apply` | `k8s-up.sh:37-41`; `bin/up.sh:689` (validation) vs `:1423` (`kubectl apply`) |
| 19 | §2 table: "Memory: files injected at session start" | "native `MEMORY.md` / `USER.md` on the PVC, written by the model, budgeted 40000/20000 chars, injected at session start" | `config.yaml:56-61`; P2-C §1 |
| 20 | "…but nothing carries context forward either, and a lost prompt leaves no trace." | what carries forward is what the agent wrote down — the stores, injected at session start; not the conversation | same |
| 21 | §9 step 5: "`up.sh` imports them …" (plural) | imports the image its pod runs (`sudo-agent:latest` here, `sudo-letta:latest` on the other factory) | `bin/up.sh` `_import_image` calls |

### 3.4 `docs/OPERATIONS.md`, `KNOWN-ISSUES.md`, `COMPONENTS.md`

| # | Said | Now | Verified by |
|---|---|---|---|
| 22 | §2.1 "those directories do not exist … `k8s-up.sh` fails loudly at the seed check on a fresh clone … repeats unattended" | the pair needs no identity package; a seed that *is* named and bad aborts that factory's `up.sh`; the boot unit's output is worth reading | `k8s-up.sh:37-41`; `ls deployments/` |
| 23 | §1 prerequisites: "systemd, curl, git and root or sudo" | adds `jq`, with why (talk.sh + verify-change.sh) — and, as the tree stood then, that Command 1 did not install it (it has since: `4918ca2`) | §4.1 |
| 24 | D1 "HIGH — unresolved … NOT fixed here" | RESOLVED in code `07d5d77`, with the evidence and the note that the residue was documentation, corrected here | `git log --oneline -S _seed_for -- bin/k8s-up.sh` |
| 25 | `COMPONENTS.md`: Command 2 "Deploys the starter pair …" | names `sudo-planner`/`sudo-engineer`, the Paperclip step, and "seed absent by default" | `k8s-up.sh` steps 3–5 |

### 3.5 `PAPERCLIP.md`, `REPOSITORY-VS-INSTANCE.md`, `SPEC.md`, `DESIGN.md`, `docs/README.md`

| # | Said | Now | Verified by |
|---|---|---|---|
| 26 | "every agent … hired automatically — Marc, Caesar, ONalwase" | "the starter pair (`sudo-planner` and `sudo-engineer`) and any new agent" | `k8s-up.sh:30-33` |
| 27 | "Verified end to end on a fresh box (…, hostname `paperclip-test`, …): … Marc + Caesar hired" | test-box hostname dropped; "the planner and engineer hired" | `REPOSITORY-VS-INSTANCE.md` (hostnames are instance facts) |
| 28 | "## The three commands" (lists two) | "## The two commands" | `setup.sh:4`, `k8s-up.sh:4` |
| 29 | `# fleet up: Marc + Caesar, THEN Paperclip` | `# fleet up: planner + engineer, THEN Paperclip` | as above |
| 30 | `--name Marc --deploy sudo-marc   # hire one` | `--name planner --deploy sudo-planner` | `k8s-up.sh:266` uses the same pair of flags |
| 31 | "blocking the Caesar deploy entirely" / "seeded **planner** persona (Marc)" | "the engineer" / "the planner persona" | no code change; instance names removed |
| 32 | `REPOSITORY-VS-INSTANCE.md`: "the identity packages … were removed … so that script fails on a fresh clone" | ships with no identity; `--from-glimor` only when a package exists | `k8s-up.sh:37-41`; `ls deployments/` |
| 33 | `SPEC.md`: "**cannot complete on a fresh clone** today" | runs unseeded; the pair comes up without an identity and grows one | as above |
| 34 | `DESIGN.md`: "Auto memory (MEMORY.md 100k chars + USER.md 50k chars …)" | 40000 / 20000, model-written | `config.yaml:56-57` |
| 35 | `DESIGN.md`: "automatically saves … without any manual commands … no 'remember this' command" | the model writes its own memory (nudged every turn); the old save-every-message patch is gone; both stores injected at session start | `config.yaml:59-62`; h4 build result |
| 36 | `bin/verify-change.sh:96` example `sudo-marc` | `sudo-planner` | `k8s-up.sh:32` |
| 37 | `bin/paperclip-hire.sh:28-29` usage: `--name Marc`, `--namespace sudo-fleet`, `--deploy sudo-marc` | `--name planner`, `--namespace <ns>`, `--deploy sudo-planner` | `k8s-up.sh:30-32` (defaults + `sudo-` prefix); the script resolves the namespace itself (`:117-121`) |
| 38 | `docs/README.md` full index omitted four pages plus `DOC-FACTS.md`'s siblings | a **Phase records** section lists them (and this report) | §7 |

---

## 4. Part 3 — the three commands, and what each actually does

As the README now prints them:

```
sudo apt-get install -y jq          # prerequisite, not a command: talk.sh needs it

①  git clone https://github.com/salmonhealer772/sudo-fleet.git && cd sudo-fleet && bash setup.sh
②  cd bin && bash k8s-up.sh
③  cd .. && sudo bash bin/talk.sh --planner
```

### 4.1 Command 1 — `setup.sh` bootstraps, it does not deploy

- Header `setup.sh:4-16`: "Command 1 of 2 (bootstrap ONLY) … It does NOT deploy
  agents". The body matches: `1/5` keys (`:146`), `2/5` Docker (`:325`), `3/5`
  k3s (`:359`), `4/5` env-var bridge (`:420`), `5/5` build images (`:445`), then
  the boot unit (`:465-489`). No agent is applied.
- Prompts: `:190` LLM API key, `:231` LLM API URL, `:270` Tavily; `:255` asks
  for a model **only** on a non-DeepSeek endpoint.
- Builds both factory images by calling each factory's own `setup.sh` (`:452-457`).

**The prerequisite gap.** `bin/talk.sh` pipes `kubectl … -o json` through `jq`
at lines 52, 56, 59, 60, 225, 226, 232, 262 under `set -euo pipefail`, so a
missing `jq` kills it at line 52 (`jq: command not found`) before any prompt.
`bin/verify-change.sh` has 47 `jq` calls. Nothing installed it — measured in §6.5
against the tree as it stood then. The README now says so in prose and as a
copy-pasteable line.

**This was a code gap, not a prose gap — and it is closed in code now.** The fix
belonged in Command 1 (`apt-get install -y jq`); h1, who owns `setup.sh` this
phase, made it after this pass reported it (message `msg-0166914c4e22`):

- `4918ca2` adds step `2/5 Bootstrap: Docker + jq` — `command -v jq` at
  `setup.sh:336`, apt install in `_bootstrap_jq` (`:332-335`), and a **hard stop**
  at `:346` with the manual install line, so a box that cannot get `jq` fails in
  Command 1 instead of 50 lines into Command 3. `grep -c jq setup.sh` is 17 at
  HEAD, against 0 when §6.5 was measured.
- `898b6bc` adds the matching guard to the deploy path (`up.sh:38-46`, +10 lines,
  nothing else in that commit), because `up.sh` runs without `set -e` and a
  missing `jq` there emptied the operator-env preserve-set and dropped operator
  variables on the next roll.

The README line is now belt-and-braces rather than load-bearing — it does not
become wrong.

(Stock `ubuntu:24.04` also has no `curl` and no `git`, which Commands 1 and 2
both assume. Both READMEs now list them.)

### 4.2 Command 2 — `k8s-up.sh` deploys a pair, then Paperclip

- `:30-31` defaults `planner` / `engineer`; `:32-33` prepend `sudo-`; `:37-41`
  `_seed_for` emits `--from-glimor` **only** if `deployments/<Capitalised-name>/`
  exists.
- `:213-224`: planner via `factories/sudo-letta/bin/up.sh`, engineer via
  `factories/sudo-agent/bin/up.sh`, each in `_retry 3`.
- `:228-231` waits on `agent=planner` / `agent=engineer`; `:233-241` verifies two
  PVCs and four Services; `:245-261` Paperclip + auto-hire, non-fatal; `:265-268`
  prints the summary.
- With no seed on disk both factories deploy clean agents — the header says
  exactly that (`:9-14`), and `up.sh` with no `--from-glimor` emits no seed
  initContainer. The pages that said the opposite are fixed (§3.4).

**Is the image Command 1 builds the image Command 2 deploys?** Yes — measured by
h1, and re-read here from their experiment log
(`phase2-out/h1/build-p2-eq.log`, produced before their report landed). They ran
the install path (the real `setup.sh`, tagging `sudo-agent:p2a-eq-install`) and
the deploy path (the real `up.sh` `_ensure_image_built`, tagging
`sudo-agent:p2a-eq-deploy`) in the same tree and compared the results:

```
IDENTICAL layer digest lists (53 layers) - same image content
/opt/comm, /opt/comm-tools, /opt/comm-skills, /opt/meta-data, /opt/hermes-mcp
  -> same sha256 in both images
hermes Hermes Agent v0.22.5 (2026.9.24) · upstream bf0203a7   (both)
patch-marker 0                                                 (both)
live tag sudo-agent:latest: sha256:16d149dd… 2026-10-18T23:12:48Z  (untouched)
```

That is the answer to this brief's highest-stakes question: the three-command
install does not produce a second, different image. h1's own report
(`docs/P2-A-DEPLOY-PATH.md`, which landed while this audit was being written)
says the same in one line — "**Measured equal**: both paths, building one
identical tree, exported the identical image manifest `sha256:b96404e8…`" — and
adds what I could not see from the docs alone: `up.sh` no longer builds, tags or
imports any `hermes-agent:latest`, and `bin/k8s-auto-up.sh` stopped re-importing
it on every boot.

What I verified myself, independently, is that there is **one tag and one
recipe** — `factories/sudo-agent/setup.sh:63` builds `sudo-agent:latest` from
`$SCRIPT_DIR/Dockerfile` with `$SCRIPT_DIR` as context, `bin/up.sh`'s
`_ensure_image_built` (`:1320`) builds the same recipe, and root `setup.sh:453`
calls that factory `setup.sh`. Two of the paths are the same build; h1's
measurement is what shows the output is byte-identical.

### 4.3 Command 3 — `talk.sh` opens a session

- `:50` `DEPLOY="sudo-$NAME"` → `--planner` addresses `sudo-planner`, the
  deployment Command 2 creates.
- `:38` refuses without a TTY → "it needs a real terminal".
- `:61-63` routes on the container name: `sudo-agent` → `hermes`,
  `sudo-letta` → `letta --new`. The README now says `--planner` opens Letta and
  `--engineer` opens Hermes, which is what the code does.
- Needs root for the nsenter path (with a `kubectl exec` fallback), hence `sudo`.

**A script wart I could not fix:** `k8s-up.sh:268` prints
`Stop (preserve state): bash bin/k8s-down.sh` while the script has left you in
`bin/`. Same defect class as the README's old Command 3, in the script's own
output; `k8s-up.sh` was nobody's file this phase.

---

## 5. Claims I did not change, and my doubt

| # | Where | Quote | Why left / doubt |
|---|---|---|---|
| 1 | the install path itself | README: "Three commands after one prerequisite" | **I could not execute it here.** Installing on this host would install docker/k3s and re-point `sudo-agent:latest` — both forbidden. What I did instead: read each command's own header and flags line by line (§4), and re-read h1's measured equality experiment (§4.2: install-path build vs deploy-path build → identical 53-layer digest lists and the same manifest, live tag untouched), which their `docs/P2-A-DEPLOY-PATH.md` states as PASS. The remaining doubt is not the image, it is the un-runnable part: a real bootstrap on a clean box. |
| 2 | `setup.sh:19` | "Prompted here (EXACTLY three fields …)" | Not mine to edit. True for DeepSeek; a non-DeepSeek endpoint gets a **fourth** prompt (`:255`). The prose I wrote does not overclaim; the script's own comment is loose. Cheap fix for whoever owns `setup.sh`. |
| 3 | `ARCHITECTURE.md` §2 / `config.yaml` | "the native memory stores are injected at session start, inside the budget `config.yaml` sets" | Verified from config + h3's P2-C. **Not verified on a running pod by me** — h4 ran the runtime checks. If a runtime check shows different injection behaviour, this is the sentence to correct. |
| 4 | `docs/DOC-FACTS.md` | ~200 rows of line-numbered citations | Deliberately not re-verified: a dated appendix (2026-10-27) whose preamble says to re-grep after edits. My edits shift line numbers in `ARCHITECTURE.md`, `OPERATIONS.md`, `KNOWN-ISSUES.md`; DOC-FACTS mostly cites *code* lines, but any citation into those three docs is now off. Rewriting 200 rows blind would be worse than leaving the appendix dated. |
| 5 | `docs/SPEC.md` §4 | "deterministic port scheme `8642 + cksum(name) % 5000`" | Already marked STALE in DOC-FACTS §2, and SPEC's own status note names the port scheme as the stale figure. SPEC is explicitly the historical design contract. |
| 6 | `logs/psnvc-2026-10-11.md` | "68 agents registered … 66 deployments" + agent names | **Instance material, committed, public.** A daily operator log of *this* fleet, in a repo whose own rule says instance content never belongs here. Not mine to delete (not docs; deletion may be deliberate history) — flagged for the operator. |

---

## 6. Evidence, verbatim

### 6.1 Command 2's names and the optional seed

```
$ grep -n 'PLANNER_NAME=\|ENGINEER_NAME=\|_seed_for()' bin/k8s-up.sh
17:#   PLANNER_NAME=boss ENGINEER_NAME=worker bash bin/k8s-up.sh
30:PLANNER_NAME="${PLANNER_NAME:-planner}"
31:ENGINEER_NAME="${ENGINEER_NAME:-engineer}"
37:_seed_for() {
```

### 6.2 The guards the factory README now describes

```
$ grep -n "_assert_image_fresh()\|_src_digest()\|_image_digest()\|_ensure_image_built()\|^IMAGE_SHA=" factories/sudo-agent/bin/up.sh
561:IMAGE_SHA="$(docker image inspect sudo-agent:latest --format '{{.Id}}' 2>/dev/null)"
1320:_ensure_image_built() {
1353:_src_digest() {
1359:_image_digest() {
1367:_assert_image_fresh() {
```

`_assert_image_fresh` at `:1367`: if the image is missing it calls
`_ensure_image_built` (`:1372`); it compares `_src_digest` of
`bin/{hermes_prompt,mcp_server,mcp_entrypoint}.{py,py,sh}` against
`_image_digest` read out of the image, and on a mismatch it prints
`✗ FATAL: … does not contain the current mcp_server.py / …` and `exit 1`
(`:1386-1391`) unless `SUDO_AGENT_ALLOW_STALE_IMAGE=1` (`:1383`). That is what
the README now says, no more.

### 6.3 Memory, base, deployments

```
$ grep -n 'memory_char_limit\|user_char_limit' factories/sudo-agent/config.yaml
56:  memory_char_limit: 40000
57:  user_char_limit: 20000
$ grep -n '^FROM' factories/sudo-agent/Dockerfile
15:FROM nousresearch/hermes-agent:v0.22.5
$ ls deployments/
README.md
```

### 6.4 Prompt set (Command 1)

```
$ grep -n '_ask "' setup.sh
190:  _KEY="$(_ask "LLM API key:")"
210:    _KEY="$(_ask "LLM API key (real key, NOT the trial key):")"
231:  _BASE_URL="$(_ask "LLM API URL [default https://api.deepseek.com/v1]:")"
255:    _MODEL="$(_ask "LLM model (required for custom endpoint, e.g. deepseek-ai/DeepSeek-V4-Pro):")"
270:  _WS_KEY="$(_ask "Tavily API key (optional):")"
```

### 6.5 The jq prerequisite — measured before `4918ca2`, closed in code since

The counts below are what the tree said when this pass ran; they are kept
verbatim because they are the evidence for the finding. At HEAD, after `4918ca2`,
`grep -c 'jq' setup.sh` is **17** and the install lives in step `2/5`
(`setup.sh:324-346`), so the first and third lines below no longer describe HEAD.

```
$ grep -c 'jq' setup.sh
0
$ grep -c 'jq' bin/talk.sh
8
$ grep -rn 'install.*jq\|apt.*jq' setup.sh bin/ factories/*/setup.sh | wc -l
0
$ docker run --rm ubuntu:24.04 sh -c 'command -v jq || echo "NO JQ IN STOCK ubuntu:24.04"'
NO JQ IN STOCK ubuntu:24.04
```

### 6.6 Syntax and links

```
$ for f in setup.sh bin/k8s-up.sh bin/talk.sh bin/verify-change.sh; do bash -n "$f" && echo "PASS $f"; done
PASS setup.sh
PASS bin/k8s-up.sh
PASS bin/talk.sh
PASS bin/verify-change.sh
```

Link check over both READMEs and every `docs/*.md` — see §7 for the figures and
§9 for the run against the pushed tree.

---

## 7. Index reconciliation

`docs/README.md`'s "Full index" listed 12 rows plus `verifications/`. `ls docs/`
says 18 documents before this pass. Four were unlisted — and they are the pages
that say *how a claim was checked*, the ones a doubting reader needs:

```
NOT LISTED  P1-B-MEMORY-AND-IDENTITY.md
NOT LISTED  h1-P1-A-REPORT.md
NOT LISTED  hermes-v0.22.5-build-result.md
NOT LISTED  hermes-v0.22.5-plugin-compat.md
```

(`README.md` itself is the index; it is never a row.)

They now sit in a **Phase records** section, alongside the phase-2 records that
exist at HEAD — `P2-C-MEMORY-CONTRACT.md`, this report, and
`P2-A-DEPLOY-PATH.md`, which landed while this audit was being written and whose
index row was added by the same generator in the confirmation commit. `P2-B` and
`P2-D` were still absent when this was written: an index row pointing at a
missing file is the exact defect this brief exists to find, so the generator only
emits a row for a file on disk. When they land, re-run it (idempotent) or add two
rows by hand in the same table.

Link check, before and after (the "after" is the fresh clone of `origin/main`):

```
files scanned: 19   relative links checked: 29
MISSING TARGETS: 0 — every relative link resolves
```

---

## 8. The stranger walkthrough — where you get stuck

Read as: clone → setup → deploy → talk, on a machine that is not this one.

1. **`jq` was required and nobody said so.** Command 3 died at `talk.sh:52` on a
   stock Ubuntu. *Docs fixed; code gap closed after this pass by `4918ca2`
   (`setup.sh` step 2 installs it and dies with the install line if it cannot).*
2. **Command 3's `cd`.** Command 2 is `cd bin && …`; Command 1 is run from the
   repo root; the old Command 3 said "run it from the repo root" while sitting
   after a command that leaves you in `bin/`. *Fixed (`cd .. &&`).*
3. **Command 2's own closing advice contradicts its own cwd** —
   `bash bin/k8s-down.sh` printed while you are in `bin/`. *Not fixed (script);
   still true at HEAD (`k8s-up.sh:268`).*
4. **Command 1's closing line said "stand up Marc + Caesar"** — this fleet's
   agents, not the repo's defaults. *Fixed by h1 in `4918ca2`: setup.sh now ends
   "stand up the starter pair (planner + engineer)".*
5. **The reader could not tell what the pair would be called.** "a Letta planner
   and a Hermes engineer" never said `sudo-planner` / `sudo-engineer`, which is
   exactly what Command 3 needs as `--planner`. *Fixed.*
6. **"A working agent" without saying what state it is in.** A fresh clone ships
   no identity, so the agent starts with no persona and no history. Anyone
   expecting a personality would have called that broken. *Fixed in both READMEs.*
7. **Four places said Command 2 fails on a fresh clone** (`ARCHITECTURE.md` §1
   note, `OPERATIONS.md` §2.1, `REPOSITORY-VS-INSTANCE.md`, a `SPEC.md` bullet).
   A reader who believed them would stop before the path that works. *Fixed in
   all four.*
8. **The docs index hid half the set**, including `DOC-FACTS.md`, the page that
   exists so a reader can check rather than trust. *Fixed.*
9. **`curl` and `git` are assumed but never listed.** Stock `ubuntu:24.04` has
   neither. *Fixed: both READMEs state the prerequisite set.*
10. **`setup.sh` is documented as one key prompt; it is three (four on a custom
    endpoint).** *Fixed in the READMEs; the script's own comment is still loose
    (§5.2).*
11. **The factory README's Quick Start looked standalone** — it builds an image
    whose `up.sh` needs a cluster, which that page never said. *Fixed.*
12. **`PAPERCLIP.md` promised "three commands" and listed two**, and named three
    of this fleet's agents as if they were defaults. *Fixed.*
13. **A committed instance log** (`logs/psnvc-2026-10-11.md`) reports fleet
    counts — harmless to a stranger, wrong for the repo. *Named, not fixed.*

Items 1–8 would stop a careful stranger; 9–13 would make them distrust the
document. `4918ca2` closed items 1 and 4 in code after this pass; item 3 is still
open in the script; everything else is closed in the text.

---

## 9. Push, and the proof

Three commits, in order, on `main` in the shared checkout:

| Commit | What it is |
|---|---|
| `c7ead0d` | this audit's doc changes + the report (13 files edited, 1 added) |
| `5cb39db` | h1's P2-A (deploy path). It landed in the same checkout between my commit and my confirmation; not mine, and I staged none of its files. |
| `fe13f90` | the push confirmation, plus the index row for `P2-A-DEPLOY-PATH.md` once that file existed |
| `2b75fec` | the report re-closed against the tree P2-A landed in (this report cites `docs/P2-A-DEPLOY-PATH.md` directly) |

The push, read back:

```
$ git rev-parse HEAD
fe13f904c9cd22cf375e1e28b6a05a24196f5257
$ git ls-remote origin main
fe13f904c9cd22cf375e1e28b6a05a24196f5257        refs/heads/main
$ git push origin main
   5cb39db..fe13f90  main -> main
```

Then the check that matters — not "the push succeeded" but "the pushed tree is
the one that passes". A fresh clone of `c7ead0d` (the doc commit) was measured:

```
$ git clone --depth 1 https://github.com/salmonhealer772/sudo-fleet.git /tmp/h5-fresh-clone
$ cd /tmp/h5-fresh-clone && git rev-parse HEAD
c7ead0d82c038db470fbdafa6559832801a41239
$ python3 h5_links.py /tmp/h5-fresh-clone
files scanned: 21   relative links checked: 35
MISSING TARGETS: 0 — every relative link resolves
$ ls deployments/
README.md
$ grep -n 'cd .. && sudo bash bin/talk.sh' README.md
41:    cd .. && sudo bash bin/talk.sh --planner
```

So the clone a stranger gets is the clone measured here: 35 relative links, none
broken; the docs index names every file in `docs/`; `deployments/` is empty as
`ARCHITECTURE.md` §1 now says; and Command 3 carries its own `cd ..`.

Re-run at the tip that includes h1's P2-A (`2b75fec`, the commit before the one
carrying this paragraph) — one more document, one more link, still nothing
missing:

```
$ git clone --depth 1 https://github.com/salmonhealer772/sudo-fleet.git /tmp/h5-final-clone
$ cd /tmp/h5-final-clone && git rev-parse HEAD
2b75fec18e7c4608ebfc63341f2e35811f8b1c97
$ python3 h5_links.py /tmp/h5-final-clone
files scanned: 22   relative links checked: 36
MISSING TARGETS: 0 — every relative link resolves
```

This paragraph is the only thing the commit that carries it changes — a commit
cannot contain its own hash, so the file's own commit is `2b75fec`'s child and
`git log --oneline -6` shows the chain.

**What my commits do not contain, and who owns it:**

- `factories/sudo-agent/bin/up.sh`, `factories/sudo-agent/setup.sh` and
  `bin/k8s-auto-up.sh` were h1's; they landed in `5cb39db`, not in mine. Every
  sentence I wrote about them was read from the tree as it stood, and §4.2 quotes
  h1's measurement as theirs.
- `docs/P2-B-SANDBOX-RECREATE.md` and `docs/P2-D-RUNTIME-CHECKS.md` were not in
  `docs/` at `fe13f90`, so the index does not name them — see §7 for what to run
  when they land.

**How close to the finish line: close, with one honest gap — since halved.** A
stranger can clone this repository, read the root README and understand exactly
what they are about to install, then follow three accurately described commands
to two clean agents. The one thing that could still stop them was `jq` not being
installed by Command 1 (§4.1); that is now written down *and* installed by
Command 1 itself (`4918ca2`), so it is no longer a hole. What remains is prose
this pass flagged and could not reach — Command 2's own closing line
(`k8s-up.sh:268`, §4.3).

## Addendum — brief C's knock-ons (folded in after the first push)

h3's Phase 2 brief C moved the memory instruction out of `config.yaml`'s comment
and into the persona seed (`comm/PERSONA-SNIPPET.md`, section `## Your memory`),
which made two things this doc set said false or thin. Folded in by commit
`3dafab9`:

| Where | What it said | What it says now |
|---|---|---|
| `ARCHITECTURE.md` §8, "the fleet-comm block" | the block is the comm awareness, `byte-identical for both factories` | still byte-identical, but names both sections and says the memory contract rides the same block, so Letta agents receive it on their next deploy too |
| `SPEC.md`, "persona awareness is a factory-managed block" | the fleet-comm text, re-applied every boot | adds what the second section is, and separates the budget (`config.yaml` `memory:`) from the instruction (the snippet) |
| `P1-B-MEMORY-AND-IDENTITY.md` | `config.yaml:50` / `:51` in a `git grep` receipt; `:50-51` as a live claim | the receipt is marked as of `983834f` with today's `:56` / `:57` named; the live claim cites `:56-57` |
| `hermes-v0.22.5-build-result.md` §5 | `config.yaml:49-53` and `:50-51`, unqualified | marked *as read at `6fc1b95`*, with a note that `afef43e` moved the block to `:55` and the limits to `:56-57`; values unchanged |

Measured, not assumed:

```
$ awk 'NR>=55 && NR<=57' factories/sudo-agent/config.yaml
memory:
  memory_char_limit: 40000
  user_char_limit: 20000

$ grep -n "PERSONA-SNIPPET" factories/sudo-letta/bin/up.sh factories/sudo-agent/bin/mcp_entrypoint.sh
factories/sudo-letta/bin/up.sh:1016:  _fc_snippet="$REPO_DIR/../sudo-agent/comm/PERSONA-SNIPPET.md"
factories/sudo-agent/bin/mcp_entrypoint.sh:95:_apply_fleet_block /opt/data/SOUL.md /opt/comm/PERSONA-SNIPPET.md

$ grep -n "memory_char_limit\|user_char_limit" factories/sudo-agent/setup.sh
factories/sudo-agent/setup.sh:227:  memory_char_limit: 40000
factories/sudo-agent/setup.sh:228:  user_char_limit: 20000
```

`setup.sh:227-228` is untouched by `afef43e`, so the "both tracked sources agree"
row in `hermes-v0.22.5-build-result.md` §5 still holds at the numbers' second
home. Nothing in this addendum touches a code file: the change is four documents
plus this paragraph.

One thing this addendum deliberately leaves alone: `docs/DOC-FACTS.md` is an
evidence appendix measured against a 2026-10-27 snapshot copy, and its own header
says to re-grep ranges after edits. Eleven of its rows cite `docs/SPEC.md` or
`ARCHITECTURE.md` line ranges that have moved since — re-pointing them is a pass
over that appendix's evidence, not a knock-on from brief C.
