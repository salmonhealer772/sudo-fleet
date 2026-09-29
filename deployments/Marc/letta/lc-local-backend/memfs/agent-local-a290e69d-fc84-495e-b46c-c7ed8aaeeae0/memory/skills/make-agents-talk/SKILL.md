---
name: make-agents-talk
description: Author the inter-agent relay for a planner+engineer pair so they can actually reach and message each other BOTH DIRECTIONS, including the three ask-engineer skills (bounded ask, unlimited ask, and read-the-result check — never a blocking ask for a status question). Use whenever building a Letta-planner + Hermes-engineer pair (or any two agents that must message). Distilled from the ms-glm + sbaco failures of 2026-09-08 and the lb-glm check-vs-ask fix of 2026-09-15.
version: 0.3.0
---

# Make Agents Talk To Each Other

The core job of a pair is that its halves can *message each other*. A pair where the planner "cannot message or even identify its engineer" is a **core fundamental failure** — that is the thing that went wrong on 2026-09-08 (ms-glm pair), and this skill exists so it never happens again.

## The three ways a relay fails (all hit today, all avoidable)

1. **Mis-identification.** The planner's pod sees the lima-VM docker daemon (`sudo-FA24`/`sudo-ardy`) and latches onto a docker container as "its engineer" — when the real engineer is `deploy/sudo-<name>-h`, a k3s Deployment one layer deeper. The docker socket in the planner's pod is NOT the path to its engineer.
2. **Vague "figure it out yourself" hint.** Telling the planner "reach the host via docker socket + nsenter" with no concrete command makes it re-derive the bridge from scratch and fail. The bridge must be handed over *verbatim*.
3. **The 120s stream timeout.** Every `kubectl exec ... hermes` call dies at 120s mid-task, killing the engineer mid-install. This is what drove ms-glm-l to invent a cron workaround. The fix is disabling the timeout with `inf` env vars at the call site — not `&`, not `nohup`, not cron.

## The one proven recipe (author these INTO the planner)

When building a Letta-planner (`sudo-<name>-l`) + Hermes-engineer (`sudo-<name>-h`) pair on the lima/k3s cluster, author **all three** of these artifacts into the planner. Do NOT settle for one or two.

### 1. Unambiguous identity (bold, at the top of the persona's reach section)

> Your engineer is `sudo-<name>-h` — a K8S Deployment (`deploy/sudo-<name>-h`) in the k3s cluster on the lima VM. It is NOT a docker container, NOT `sudo-FA24`, NOT `sudo-ardy`. Those are unrelated agents on the lima VM's docker daemon; ignore them entirely when delegating.

### 2. The verbatim one-shot — WITH the no-time-limit env vars (this is the whole point)

```
docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest sh -c \
  "nsenter -t 1 -m -u -i -n -p -- env HERMES_STREAM_READ_TIMEOUT=inf HERMES_STREAM_STALE_TIMEOUT=inf HERMES_API_CALL_STALE_TIMEOUT=inf KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl exec -i deploy/sudo-<name>-h -- hermes -z '<single-line prompt>'"
```

Rules to bake in verbatim:
- `inf` = infinite (disables the timeout). **Never `0`** — `0` is instant timeout, the opposite.
- Always all three: `HERMES_STREAM_READ_TIMEOUT=inf`, `HERMES_STREAM_STALE_TIMEOUT=inf`, `HERMES_API_CALL_STALE_TIMEOUT=inf`.
- These go on the `env` prefix *inside* the bridge (right after `nsenter ... --`), before KUBECONFIG/kubectl.
- With `inf`, the call survives as long as the engineer needs. **No `&`, no `nohup`, no cron** — just run the call and wait.
- Swap only the `hermes -z '...'` prompt. Do not re-derive the bridge.

### 3. A dedicated `skills/reaching-my-engineer/SKILL.md` in the planner's own MemFS

Procedural memory survives persona drift. Create the skill (YAML frontmatter with `name` + non-empty `description`) and put the SAME three blocks in it: identity, the verbatim no-time-limit one-shot, and the traps (docker-socket = lima daemon not your path; bare `nsenter` stays in your own pod; inf ≠ 0).

## The traps (each must be stated explicitly, not assumed)

- **docker-socket trap:** `/var/run/docker.sock` in the planner's pod is the lima-VM docker daemon — it shows only other docker containers, never the k3s Deployment. To reach the engineer you must *bridge* to k3s, not stop at docker.
- **bare-nsenter trap:** `sudo nsenter -t 1` from the planner's own pod re-enters ITS OWN PID 1 (`sh -c tail -f /dev/null`) because pods ship without `hostPID`. It *looks* like it worked (root shell in your own container) but kubectl/kubeconfig/talk.sh are absent. Only the docker-socket bridge reaches the real host (Ubuntu 26.04, systemd PID 1, `/etc/rancher/k3s/k3s.yaml`).
- **timeout trap:** the "long prompts → background with `&`" advice is a leftover workaround. The real fix is the `inf` env vars in the call. Do not teach `&`/cron as the time-hack.

## Verification checklist (before you call a pair "done")

- [ ] Planner's persona has the bold unambiguous identity (name = `sudo-<name>-h`, k3s, NOT docker).
- [ ] The verbatim one-shot includes all three `HERMES_*_TIMEOUT=inf` vars.
- [ ] A `skills/reaching-my-engineer/SKILL.md` exists in the planner's MemFS with the same content.
- [ ] Live test: from the pair's own conversation, the planner actually reaches the engineer via the bridge and gets a real reply (not a docker-container mis-fire).

## Live test proof (the only thing that counts)

A relay is only "working" once the planner, *on its own in its own session*, runs the verbatim bridge and gets a real `hermes -z` reply from `deploy/sudo-<name>-h`. "The pod is Running" and "the persona says the recipe" are NOT proof — the planner must demonstrably execute the call. This is what was missing today.

## Note: this is my lever, not forge's

I (psnvc) own authoring these three artifacts into the planner — it's the "spec the relay" half of my job. forge executes the file writes. I do NOT leave a pair with a bare "figure it out yourself" hint and call it deployed.

## The reverse direction (Hermes engineer → Letta planner)

A pair is only two-way when BOTH halves can reach each other. The reverse (engineer → planner) is a *different mechanism* than the forward one — do not copy it. (sbaco pair, 2026-09-08, the person explicitly asked for "vice versa" skills.)

- **Engineer → planner:** the Letta planner has no `hermes -z` equivalent. Reach it via the **`letta` CLI headless one-shot** — `letta -p "<prompt>"` (runs a one-off prompt against the current agent, no TTY). For the engineer's pod this means `<letta-binary> -p "<prompt>"` with `LETTA_AGENT_ID` (or the agent selectors) pointing at the planner. Confirm the exact form against the live binary (`letta` / `letta messages ...`) rather than assuming.
- **Where the reverse skill lives:** Hermes agents read skills from **`/opt/data/skills/`** (a categorized folder tree — `devops/`, `github/`, etc.), NOT a Letta-style MemFS git repo. Write the reverse skill as a folder in that tree (e.g. `/opt/data/skills/agent-messaging/SKILL.md`). **Hermes's skills dir is NOT a git repo** — no commit needed; the file just lives on disk and Hermes indexes it. (If it doesn't pick up immediately, rebuild the Hermes skill index / `hermes skills`.)
- **Author BOTH directions when wiring a pair** — the forward skill (planner → engineer) into the planner's MemFS, AND the reverse skill (engineer → planner) into the engineer's skills dir. Shipping only the forward half is a half-wired pair.

## Timer variants (bake BOTH, not just `inf`)

The person asked for **both** a bounded 10-minute call and an unbounded call — the planner "can't figure out" which to use when. Bake the rule in verbatim:

- The `HERMES_*_TIMEOUT` value is **seconds**. `600` = 10 minutes (for quick/bounded asks — dies after 10 min, use when you want a hard cap). `inf` = infinite (for long jobs — installs/builds, survives indefinitely). **Never `0`** — `0` is instant timeout, the opposite of what's wanted.
- Always set **all three** together: `HERMES_STREAM_READ_TIMEOUT`, `HERMES_STREAM_STALE_TIMEOUT`, `HERMES_API_CALL_STALE_TIMEOUT`.
- Give the planner the rule as a table ("quick ask → `600`, long job → `inf`"), not just one magic string, so it can choose per-task instead of guessing.

## Three skills, not two — "check on my engineer" is its OWN mode (added 2026-09-15)

When authoring the relay for a planner, bake in **three** distinct skills, not just "ask" and "ask-but-unlimited". The third is the one that prevents the single most annoying failure — the planner hanging forever on "did my engineer finish yet".

1. **`ask-engineer`** — bounded foreground one-shot (`HERMES_*_TIMEOUT=600`), inline reply, for a NEW question.
2. **`ask-engineer-long`** — same one-shot with `inf`, for big prompts.
3. **`ask-engineer-check`** — the **"is my engineer done / what did it say"** skill. This one is READ, not ASK.

The skill-selection trap (the reason this exists): a planner answering "did you finish the bug fix?" by loading `ask-engineer` is doing a **blocking foreground full-model round-trip for a one-word yes/no** — minutes to hang for what should be instant. The fix is routing, made loud in each skill:

- **WHEN-TO-USE at the top of every skill**: a status/check question routes to `ask-engineer-check` (READ), never `ask-engineer` (ASK).
- **Hard rule "reading ≠ asking"**: when the engineer has already responded, the planner does NOT send it anything — it retrieves the response that already exists. Never fire a fresh `hermes -z` to learn an old result; the reply is in the file, not in a fresh chat.
- **`inf` does not save a long foreground call**: `inf` disables *the engineer's* internal kill, but the *planner's own* bash tool still has its own hard ceiling (~10 min). For any job that might outlive that, **detached-to-file is the only way the planner will ever be able to read the result later**. `ask-engineer-long` should carry this trap explicitly, pointing to `ask-engineer-check`.

**The `ask-engineer-check` mechanism (bake this in):**
1. Fire long jobs **detached to a file** (`nohup ... > /opt/data/<planner>-last-reply.txt 2>&1 &`), never foreground.
2. Confirm it actually started (`ps aux | grep hermes` inside the engineer pod — a live `hermes -z` PID).
3. To check "is it done / what did it say": read the result file (empty/absent = still running) + `ps` for the live process. Optionally have the runner write a `RUNNING` → `DONE`/`FAILED` status marker for an unambiguous one-line read.
4. The status check is a single instant `kubectl exec` (~1–2s, no model wait) — that's the whole point.

## Do NOT teach "monitor/poll-and-wait" as the check method

A `Monitor`/watcher tool "arming a watcher on the result file so completion arrives as an event" **does not work reliably** — the person said so directly (2026-09-15): "DO NOT add this monitoring method to ur skills kus it DOES NOT WORK i alwase have to prompt you to check." The pattern that works is **read-when-asked**: when someone asks "is it done", go read the actual state (result file + `ps`), don't set a silent watcher and forget it exists. Bake the *read-on-request* model into the planner's check skill, not a "wait for an event" model.

## "It can't use skills/tools" — verify the MODEL before blaming config (corrected 2026-09-16)

When a freshly-built planner fails to load skills or use tools (empty-arg `Skill` calls, hallucinated tool names like `Say`/`Glob`/`EnterWorktree`/`Statusline`, infinite `Skill` retry loops, hard CLI crashes like `currentQuestion.options is not iterable`), first **rule out that it's the model, not the toolset.** The earlier "empty toolset / set `--toolset default`" theory was **empirically disproven**: `--toolset default` leaves `tools: []` unchanged (tools load at runtime, and an empty `tools` field is normal serialization). The realistic causes, in order of likelihood for a small/local model:

1. **The model can't read the actual tool schema.** A home-served 30B (e.g. `ollama/geodesic-control-pretrain-30b-sft`) that was trained to converse/reason — not to tool-call — will **confabulate** plausible tool names + args from its base priors (invented agent IDs, "memory files", `Edit`/`Write` tools that don't exist) instead of grounding in the real tool definitions. **Decisive test: ask a bare agent (no persona) "what tools do you have?"** — if it invents a fake tool surface instead of enumerating its actual tools, it's the model, not the config.
2. **Harness survives malformed calls poorly** — a malformed `AskUserQuestion` can throw an unhandled TUI exception, co-occurring with (but distinct from) the model's tool hallucination.

If the model is the problem, **no toolset/config/persona/skill fixes it** — the honest ceiling is a conversation-only agent. For a small model that CAN tool-call but fumbles, the persona-level fallback in the next section still applies. But don't burn turns chasing `--toolset default` when the model was never a tool-calling model to begin with.

## Weak/local model: bake the ONE critical command into the persona, not behind a `Skill` (added 2026-09-16)

For a planner whose model is small/local (30B-class) and fumble-prone at tool-calling, do **not** rely on it successfully invoking the `Skill` tool to load `reaching-my-engineer`. A model that drops tool arguments can't be trusted to even open the skill. Instead, bake the engineer-reach command **directly into the persona** (always in-context, no tool-load step) as a short "if they say talk to your engineer, run exactly this one Bash command" line, plus a hard anti-hallucination guard: *"if you find yourself inventing a `Say`/`Agent` tool or loading a skill first, stop — just run the Bash command."* Keep the `skills/reaching-my-engineer/SKILL.md` in place too (for when it CAN load it), but the persona carries the fallback so a single critical command is never more than one Bash call away. **Still write the reach command into BOTH — for the weak-model fallback the persona copy is the load-bearing one.**

Note: if the model *can't tool-call at all* (confabulates rather than reads the schema — see the section above), even the persona-baked command never fires, because there's no reliable Bash tool to run it. In that case the honest ceiling is conversation-only, and the engineer-reach is the operator's job, not the planner's.

## Name the exact skill invocation, and don't leave a contradictory fallback next to it (added 2026-09-16)

Two distinct failure modes when you tell a planner "load your skill to talk to your engineer":

1. **The model doesn't know the real skill name, so it invents one.** psy-glm-l hallucinated a `sayhi_to_engineer` skill (and even misspelled the engineer as "psyc-glm-h") because the persona described the engineer reach *without ever naming the actual skill*. When the operator says "load your skill," the model can only fire `Skill(skill: "<name>")` if the persona states the **exact skill name verbatim** (`skills/reaching-my-engineer/SKILL.md` → the `Skill` tool arg is `reaching-my-engineer`). Bake the literal name + the literal tool invocation into the persona, unmissably — not a paraphrase.
2. **A stale fallback line contradicts the new instruction.** psy-glm-l's persona still carried an earlier workaround line *"I do NOT need to load a skill first"* — which directly fought the operator's "now load the skill" command. The model resolved the contradiction by hallucinating a skill to *narrate about* instead of actually invoking the real one. **Rule: when you change how the planner reaches its engineer, remove/rewrite any prior "you don't need the skill / just run the inline command" line in the same breath** — two conflicting instruction sets side by side is how the model ends up doing neither. One unambiguous primary path (load the real skill by name) + one clearly-labelled fallback (the inline Bash command), never two competing "primary" paths.

Both fold into the same lesson: the reach instruction the model actually *reads* must name the real artifact and be internally consistent. A vague "there's a skill" + a stale "you don't need it" is exactly the recipe for a hallucinated tool call.
