# P2-D — the runtime checks: does the new image actually WORK, or is it just green?

Phase 2, brief D. The "tested" half of Phase 2, run against the **one** sandbox agent
the operator named. Read-only on the cluster: every kubectl verb used was `get`,
`describe`, `logs` or a read-only `exec`. No `apply/patch/delete/scale/rollout/create/edit`,
no restart, no `sudo-agent:latest` build or tag.

Sandbox: `sudo-mail-bot-hermes` (ns `default`) — the single agent this phase was allowed
to touch. It was recreated onto the new image by h2 (brief P2-B); this brief measures the
result. 103 deployments existed before and after; this document changed none of them.

---

## 1. First screen

| # | Runtime check | Measured value | Verdict |
|---|---|---|---|
| 1 | **Tape is live, not merely non-empty** | `plugin.json` `"loaded": true` with **7 hooks**; tape grew **+244 rows / +346,772 bytes** from one driven turn, carrying `turn_start` ×4, `delta` ×133, `completion` ×4, `tool_call` ×3, `tool_result` ×3 | **PASS** |
| 2 | **Comm layer answers** | `message_agent.py mail-bot-hermes "<prompt>"` → `msg-f6e17b7e30c5`, `ok: true`, full reply returned | **PASS** |
| 3 | **MCP door is up** | Service `sudo-mail-bot-hermes-mcp` 8000 → targetPort **18397**; handshake HTTP 200, 2 tools; `hermes_prompt` → `ok: true`, output `alive` | **PASS** |
| 4 | **Gate still refuses, then allows** | Same session, same command: `status=blocked` → *"BLOCKED: load the list-siblings skill first, then retry."* → `skill_view list-siblings` `status=ok` → same command `status=ok`, `exit_code: 0`; `skills/.usage.json` writable, mtime moved on the load | **PASS** |

**Does the new image WORK? YES — all four runtime checks have a measurement behind them,
and the two that fail silently (the tape and the gate) were driven, not inferred.**

**Is the agent STILL ITSELF? YES** — `state.db` unchanged at 78,569,472 bytes, 411→414
sessions and 6,344→6,358 messages with every one of those deltas accounted for by a turn
driven during this phase, `schema_version` **32** (no migration), 18 skills, and the
**identity half of `SOUL.md` is byte-identical** before and after
(`sha256 659dbbaa…`, 5,294 bytes) — only the factory-managed block changed, which is the
designed behaviour and not a regression.

**Full implementation — does the documented install path produce this agent? YES for the
image** (same Dockerfile, same build context, same pinned `FROM`; 53/53 identical layer
digests, identical runtime `Config`/`Created`/`Size` — independently re-measured here).
**With one caveat about the box, not the image: the documented path does not complete on a
stock host until `jq` is installed** (h5's finding, §8).

---

## 2. STEP 0 — the baseline, captured on the OLD image before anything moved

Taken at **19:17Z**, before h2's recreate. This is the only inside view of the old image
and it is what makes "the upgrade changed something" a measurement instead of a claim.

Pod `sudo-mail-bot-hermes-cc98c89b7-z48n6`, image `sudo-agent:latest`, age 16d.

```
$ kubectl -n default exec <pod> -c sudo-agent -- hermes --version
Hermes Agent vunknown (2026.9.24)
Install directory: /opt/hermes
Install method: docker
Python: 3.14.7
OpenAI SDK: 2.24.0
```

```
$ cat /opt/data/watch/plugin.json
{"plugin": "sudo-watch-stream", "loaded": true, "pid": 123539, "started": 1792971726.9368775,
 "hooks": ["on_stream_start", "on_stream_delta", "on_stream_end", "pre_api_request",
           "post_api_request", "pre_tool_call", "post_tool_call"],
 "counts": {"plugin_state": 1, "log": 2296, "activity": 2806}, "dropped": 0, ... }

$ wc -lc /opt/data/watch/stream.jsonl
   343878 144996731 /opt/data/watch/stream.jsonl
```

```
$ kubectl ... -o jsonpath='{.status.containerStatuses[*].restartCount} {.status.startTime}'
47 5 2026-10-12T00:11:57Z          # sudo-agent 47, watch 5 -> pod total 52
```

```
$ grep -nE "char_limit" /opt/data/config.yaml
8:  memory_char_limit: 100000
9:  user_char_limit: 50000
```

```
sessions 411 | messages 6344 | schema_version( table ) 32
$ md5sum /opt/data/SOUL.md   -> 721754026f924d2079a37f0d323c6d22  (7891 bytes)
$ ls /opt/data/skills/ | wc -l  -> 18
$ wc -c /opt/data/memories/*.md -> 100217 MEMORY.md, 50222 USER.md
```

Plus, captured for the identity test in §7:

```
IDENTITY_PREFIX  sha256=659dbbaa89a1c8023ef222eebc30f912f4d421863ea64e3b183f87387461cb1d bytes=5294
FLEET_BLOCK      sha256=fa55d658551187a824e87e078a8b2bab9fd0a77ee768efbd8d688cff754849d8 bytes=2596
BLOCK_HAS_MEMORY_SECTION False
```

**Where the brief's expected baseline was wrong:** it said **51** restarts; measured
**52**. The fleet had been running, so the pod restarted once between the brief and this
capture. Every other expected value matched exactly (vunknown, 100000/50000, 411 sessions,
6,344 messages, schema_version 32).

**Restarts are pre-existing, not upgrade-related.** The `lastState` of the old pod shows
`sudo-agent` exited **78** on 2026-10-25 and `watch` exited **1**; this is the fleet-wide
48–53 restart pattern already recorded in the facts table, not something this phase caused.

---

## 3. The dependency: how long the marker took

h2's marker is the only signal h2 is done; it was polled every 90 s, never messaged.

```
19:24:21Z poll#1 -> none
19:25:51Z poll#2 -> none
...                                    (13 polls, all "none")
19:42:31Z poll#13 -> none
19:44:01Z poll#14 -> P2B-DONE.txt      <- found, ~20 minutes in
```

`P2B-DONE.txt` named pod `sudo-mail-bot-hermes-66f565699b-lrfsz`, image
`sudo-agent:p2a-h1` (image id `sha256:ebc56f72e84a…`), budget **40000/20000**, and the
memory instruction arriving **"present via persona … NOT via skill"**. Those claims are
re-verified independently in §6–§7 below — I did not take them on trust.

---

## 4. Check 1 — the tape is LIVE, not merely non-empty

### 4.1 Loading (necessary, not sufficient)

```
$ cat /opt/data/watch/plugin.json
{"plugin": "sudo-watch-stream", "loaded": true, "pid": 7, "started": 1793216374.7498558,
 "hooks": ["on_stream_start", "on_stream_delta", "on_stream_end", "pre_api_request",
           "post_api_request", "pre_tool_call", "post_tool_call"],
 "counts": {"plugin_state": 1, "log": 203, "activity": 40, "input_context": 6,
            "turn_start": 6, "delta": 219, "stream_end": 7, "completion": 6,
            "tool_call": 4, "tool_result": 4},
 "dropped": 0, ... }
```

`loaded: true` and **seven** hooks — the same seven the old image registered. Loading alone
proves nothing, so the tape was driven.

### 4.2 The row delta from a real turn

| | rows | bytes | when |
|---|---|---|---|
| before the turn | **344,227** | 145,234,277 | 19:44:38Z |
| after the turn | **344,471** | 145,581,049 | 19:46:09Z |
| **delta** | **+244** | **+346,772** | one turn |

**The delta is the point, and so is the shape.** On this agent the tape's row count also
grows with no turn at all: between 19:17 and 19:24 it gained **21 rows** of pure
`activity`/`log` heartbeat, with zero model traffic. A file that is growing is therefore
not evidence that the tape works — only the event vocabulary is. That is why the histogram
below, not the row count, is the verdict.

Event vocabulary produced by that one turn:

```
--- event histogram over the last 4000 rows (NO payload text) ---
  activity       1911
  log            1833
  delta          219
  stream_end     7
  input_context  6
  turn_start     6
  completion     6
  plugin_state   4
  tool_call      4
  tool_result     4
tools_seen ['memory', 'skill_view', 'terminal']

--- last events ---
{"event": "stream_end", "turn_id": "local-ede2af", "delta_count": 77, "text_chars": 274, "error": null}
{"event": "completion", "turn_id": "local-ede2af", "finish_reason": "stop", "streamed": true}
```

`turn_start` ✓, deltas ✓, `completion` ✓, and — because the turn ran tools — `tool_call` /
`tool_result` with **non-empty tool names** (`terminal`, `skill_view`, `memory`), which is
the specific thing h3's Phase 1 §7 said would indicate that the
`function_name → tool_name` boundary had moved. It has not.

No error rows appear in `/opt/data/watch/`, and `"dropped": 0` — the plugin is not
silently discarding work.

---

## 5. Check 2 — the comm layer answers

Route used: `message_agent.py` from this engineer's pod → the recipient's MCP
`hermes_prompt` → its Redis queue → the in-pod drain worker. The subject is the sandbox
agent itself, **not** a `sudo-fleet-glm` sibling (they are working this phase and were
never used as test subjects).

```
$ python3 /opt/comm-tools/message_agent.py mail-bot-hermes "<diagnostic prompt>"
{
  "id": "msg-f6e17b7e30c5",
  "queued": true,
  "status": "pending",
  "source": "1277b9e215794b6789272898b1158e18"
}

$ python3 /opt/comm-tools/message_agent.py mail-bot-hermes --queue
{ "id": "msg-f6e17b7e30c5", "ok": true,
  "output": "Summary:\n\nStep 1 printed (exact): {\"error\": \"BLOCKED: load the
             list-siblings skill first, then retry.\"}\n\nLoaded the skill: yes, I
             loaded the list-siblings skill after step 1 was blocked.\n\nStep 3 print…",
  "error": "",
  "enqueued_at": 1793216714.40605, "started_at": 1793216714.6723175,
  "finished_at": 1793216727.714058 }
```

`ok: true` with real content, and the queue emptied (`inflight: []`, `pending: []`) — so
this is a round trip, not an accepted write. What this route does **not** cover on its own
is the MCP handshake itself; that is check 3, driven directly.

---

## 6. Check 3 — the MCP door is up

Ports are derived per agent, so they were **read from the Deployment**, not guessed — and
this matters, because the port moved during the recreate:

```
$ kubectl get svc sudo-mail-bot-hermes-mcp -o jsonpath='...'
sudo-mail-bot-hermes-mcp   port=8000   targetPort=18397
sudo-mail-bot-hermes-watch port=8000   targetPort=27841

$ kubectl get deploy sudo-mail-bot-hermes -o jsonpath='...env...'
MCP_PORT=18397   WATCH_PORT=27841   API_SERVER_PORT=63209

$ kubectl get endpoints sudo-mail-bot-hermes-mcp
sudo-mail-bot-hermes-mcp   <pod-ip>:18397
```

**The `-mcp` targetPort changed from 13725 on the old deployment to 18397 on the new one,
and the Service was updated to match.** Anything that cached the numeric port breaks across
a recreate; anything using the Service (`<agent>-mcp:8000`) does not. Worth knowing before
propagating 60 agents.

Door reached over the ClusterIP (`<mcp-service-clusterIP>:8000`), handshake + `tools/list`:

```
$ python3 mcp-call.py --url http://<mcp-service-clusterIP>:8000/mcp --list
initialize: HTTP 200  session=99acb92fb8944949971bb886eb60fc5c
  server: {"name": "sudo-agent", "version": "4.0.9"}
tools/list: HTTP 200  2 tools
  hermes_prompt, hermes_queue_status
```

And `hermes_prompt` actually answering:

```
$ python3 mcp-call.py --url ... --tool hermes_prompt \
    --args '{"prompt":"Reply with exactly one word: alive. Do not run any tool.","mode":"inbox"}'
tools/call hermes_prompt: HTTP 200
{"id": "msg-9772acf7647f", "queued": true, "status": "pending", "source": "h4-p2-d-check3"}

$ python3 mcp-call.py --url ... --tool hermes_queue_status --args '{}'
{ "id": "msg-9772acf7647f", "ok": true, "output": "alive", ... }
```

---

## 7. Check 4 — the gate still refuses, then allows

### 7.1 The prerequisite h3 flagged: the ledger must be writable

h3's Phase 1 §2.4 records the chain that makes this gate fail "everything blocked
forever": `on_skill_lifecycle` only fires if `<HERMES_HOME>/skills/.usage.json` can be
written. On the recreated pod:

```
-rw------- 1 hermes hermes 32163 Oct 19 07:20 /opt/data/skills/.usage.json
USAGE_WRITABLE=yes
USAGE_MTIME 1792394438.875218      -> after the skill load: 1793216722.840284
```

Writable, and the mtime **moved** when the skill was loaded — the write landed.

### 7.2 The block, then the allow — one session, one command

Driven through the pod's own agent so the plugin half (`pre_tool_call` veto) is genuinely
in the path. Extracted from the tape, which is the agent's own record of what happened:

```
tool_call    terminal   python3 /opt/comm-tools/list_siblings.py --filter zzzz-nomatch
tool_result  terminal   status=blocked dur=0
                        {"error": "BLOCKED: load the list-siblings skill first, then retry."}
tool_call    skill_view list-siblings
tool_result  skill_view status=ok dur=114
                        {"success": true, "name": "list-siblings", ...}
tool_call    terminal   python3 /opt/comm-tools/list_siblings.py --filter zzzz-nomatch
tool_result  terminal   status=ok dur=971
                        {"output": "no matching siblings for filter \"zzzz-nomatch\"", "exit_code": 0}
```

Same session, same command: **blocked before the skill load, allowed after it.** Nothing
else changed.

### 7.3 The lifecycle hook really fired (not just "the CLI refused")

The gate's ledger gained a new session keyed by the driven turn, carrying the loaded skill.
That entry can only be written by `on_skill_lifecycle`:

```
--- sessions recorded in the ledger ---
sessions_in_ledger 2
   20261011_212002_ -> ['list-siblings', 'message-agent']
   local-ede2af8d30 -> ['list-siblings']          <- this turn, recorded by the hook
```

### 7.4 The CLI half, and both directions of its policy

```
CLI half, COLD session id, list-siblings  -> BLOCKED: load the list-siblings skill first, then retry.   EXIT=69
CLI half, SAME cold session, message-agent-> BLOCKED: load the message-agent skill first, then retry.  EXIT=69
CLI half, SAME cold session, check-agent  -> BLOCKED: load the check-agent skill first, then retry.    EXIT=69
CLI half, NO session (human/script path)  -> no matching siblings for filter "zzzz-nomatch"            EXIT=0
ungated command                           -> ungated-ok                                               EXIT=0
```

All three gated tools refuse inside a Hermes session (exit 69, `EX_UNAVAILABLE`) and the
human/script path stays open — the gate is armed without being a wall.

> Probe note, because it is the kind of thing that fakes a pass: `message_agent.py --help`
> exits **0** regardless of the gate, because `argparse` handles `--help` before `main()`
> ever calls `gate()`. An earlier version of this probe used `--help` and would have
> reported "allowed" for a gated tool. Every `EXIT=` here is captured from the command
> itself, never from a pipe (`cmd | head; echo $?` reports `head`'s status).

---

## 8. STEP 3A — the memory instruction: present, current, and does it reach the fleet?

**Present, by the persona route, and byte-identical to the current repo text.**

The mechanism h3 chose is `comm/PERSONA-SNIPPET.md`, applied to `SOUL.md` as a
factory-managed block on **every boot** (`bin/mcp_entrypoint.sh:95`). Verified inside the
pod, not from the report:

```
IDENTITY_PREFIX  sha256=659dbbaa89a1c8023ef222eebc30f912f4d421863ea64e3b183f87387461cb1d bytes=5294
FLEET_BLOCK      sha256=68bb9ed3d636a16f30ea3dfaf0b30ddabd9457b45ad94ae411f54f74d7c92d3a bytes=4264
BLOCK_HAS_MEMORY_SECTION True
BLOCK_HAS_ONE_ENTRY_IS_ONE_FACT True
```

**Freshness — is it the CURRENT text, or a stale copy?** Comparing the pod's block, with
the two marker lines stripped, against `comm/PERSONA-SNIPPET.md` at repo HEAD:

```
repo HEAD  factories/sudo-agent/comm/PERSONA-SNIPPET.md
           7c1420eb7393c86b13d0f985d37bf30787c90b1ec32ce4b814f5d415d817b9b7   4195 bytes

pod SOUL.md fleet block, markers stripped:
  inner[1:]  4195 bytes  7c1420eb7393c86b13d0f985d37bf30787c90b1ec32ce4b814f5d415d817b9b7  <-- MATCHES REPO HEAD
```

Byte-for-byte identical. Not a stale landed copy.

**Reach — the answer the propagation job needs, stated plainly:** the carrier is the
**persona block, which is re-applied on every container boot**, so **every one of the ~60
running agents will receive it on its next restart once it runs an image built from this
commit**. It is **not** first-boot-only. The skill route was correctly rejected: the skill
seed sits behind `/opt/data/.comm-seeded`, which still reads `Sep 30 04:47` on this pod and
exists on every agent's PVC — a new skill would have reached **0** of them. There is no
marker to clear and no PVC surgery, which is what makes this cheap to propagate.

The `config.yaml` comment that used to hold the instruction is now maintainer-only prose
pointing at the persona file; a YAML comment is never seen by the model, so as long as the
instruction lives in the persona it is the only copy that counts. On this pod the instruction
is in `SOUL.md` and matches HEAD; it is in **no** skill (`grep -rl '^## Your memory'
/opt/data/skills/` → no match), which is exactly the intended single home.

---

## 9. STEP 3B — the budget is the new one

```
$ grep -nE "char_limit" /opt/data/config.yaml     # inside the pod, not the host file
8:  memory_char_limit: 40000
9:  user_char_limit: 20000
10:  memory_enabled: true
11:  user_profile_enabled: true
```

**40000 / 20000 — the new pair, live.** This is not a footnote result: had it read
100000/50000 the whole memory measurement would have been of the old world.

A store written under the new contract is also visible: `/opt/data/memories/MEMORY.md` is
**115 bytes** (one entry) rather than the 100,217-byte, 34-entry, 2,850-char-average store
the old image had accumulated. Small sample, but the shape is the intended one.

---

## 10. STEP 3C — is the agent still itself? (verified independently of h2)

| Measure | Before (old image) | After (new image) | Reading |
|---|---|---|---|
| `state.db` size | 78,569,472 B | 78,569,472 B | unchanged |
| sessions | 411 | **414** | +3, all driven turns (h2's, my diagnostic, my `alive`) |
| messages | 6,344 | **6,358** | +14, same three turns |
| `schema_version` | 32 | **32** | **no migration** |
| `SOUL.md` whole-file md5 | 721754026f924d2079a37f0d323c6d22 | 62e1be7a40585e729c2704b8c19ef77c | **changed — and it must** |
| `SOUL.md` **identity prefix** sha256 | 659dbbaa… | **659dbbaa…** | **identical — still itself** |
| skills | 18 | **18** | unchanged |
| `.comm-seeded` | 2026-09-30 | 2026-09-30 | untouched |

**Why the whole-file md5 changing is correct, not a regression.** The fleet persona block
is re-applied to `SOUL.md` on every boot. When h3 changed the snippet, the block grew from
2,596 to 4,264 bytes, so `SOUL.md` grew 7,891 → 9,559 bytes. Judging "is it still itself?"
by the whole-file md5 would therefore report a **false failure on every correctly upgraded
agent**. Hashing the identity prefix separately (`≤FLEET-COMM-AWARENESS-BEGIN`, 5,294 bytes)
gives the honest answer: **byte-identical before and after.** The agent is the same agent;
only its factory-managed instructions were updated.

History is readable through the product path, inside the new pod:

```
sessions 414 | messages 6358 | schema_version 32
session_date_range 2026-08-24 -> 2026-10-28
sessions_started_before_2026-10-19  410
session_search browse:   success=True results=3 mode=browse
session_search discover('email'): success=True results=3
  matched_dates ['August 24, 2026 …', 'August 25, 2026 …', 'September 06, 2026 …']
```

410 sessions predate this work and the search tool returns them — real old content, quoted
here only as counts and dates (this agent holds live correspondence; no titles, previews or
message bodies are reproduced in this document).

Memory was **archived, not deleted**: `MEMORY.md` 100,217 B and `USER.md` 50,222 B moved to
`/opt/data/memories-legacy/` at byte-identical sizes, and `/opt/data/memories/` starts clean.

---

## 11. STEP 3D — does the documented install path produce this agent?

**YES — the documented install path builds the same image content the deploy path builds.**
Checked two ways.

By construction: both entry points build the *same* Dockerfile with the *same* context and
the *same* pinned base.

```
factories/sudo-agent/setup.sh:60   AGENT_IMAGE="${SUDO_AGENT_IMAGE:-sudo-agent:latest}"
factories/sudo-agent/setup.sh:63   docker build -t "$AGENT_IMAGE" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"
factories/sudo-agent/bin/up.sh:61  AGENT_IMAGE="${SUDO_AGENT_IMAGE:-sudo-agent:latest}"
factories/sudo-agent/bin/up.sh     docker build -t "$AGENT_IMAGE" -f "$REPO_DIR/Dockerfile" "$REPO_DIR"
                                   (REPO_DIR = factories/sudo-agent = setup.sh's SCRIPT_DIR)
Dockerfile:15                      FROM nousresearch/hermes-agent:v0.22.5
```

`config.yaml` is **not** COPYed into the image, so `setup.sh`'s later LLM-config rewrite
cannot make the install-path image differ from the deploy-path image.

By measurement — h1 built the same tree through both real entry points and this engineer
re-measured the resulting images independently:

```
$ docker image inspect <install> <deploy>   -> RootFS.Layers identical
layer-list sha256 (both)  ce779d094d4784d82016937d3709577058f9d1832476383e46db44ec29d16750
Config identical, Created identical, Size identical, 53 layers

$ docker run --entrypoint sh <image> -c 'md5sum /opt/comm/PERSONA-SNIPPET.md'
sudo-agent:p2a-eq-install   b5fae6e89d61516457e882ad5c69de5b   (== repo at build time)
sudo-agent:p2a-eq-deploy    b5fae6e89d61516457e882ad5c69de5b
sudo-agent:latest (OLD)     53b46fea0e0941eb172c78607911aff8   (predates the memory contract)
```

One honest caveat about *identity*, not content: the two builds carry **different image
IDs** while their `Config`, `Created`, `RootFS` and `Size` are equal, so the difference is
build metadata, not image content. **Do not verify a rebuild by comparing image IDs** — and
note that `up.sh` pins the pod template with the image ID, so a rebuild forces a pod roll
even when the content is unchanged.

h5's independent docs pass reached the same conclusion on the image ("identical — 53
identical layer digests") and found the remaining gap is on the **host, not the image**: the
three-command path needs **`jq`**, which `talk.sh` requires and `setup.sh` did not install,
so a stranger on a stock box gets a working image and then fails on command 3. That is a
documentation/code gap to close, not a defect in what was tested here.

---

## 12. Before / after — did the upgrade break anything?

| Measure | OLD image (19:17Z) | NEW image (19:46Z) | Changed? |
|---|---|---|---|
| `hermes --version` | `vunknown (2026.9.24)` | `v0.22.5 (2026.9.24) · upstream bf0203a7` | **yes — the point** |
| Python | 3.14.7 | 3.14.9 | yes |
| `plugin.json` loaded / hooks | true / **7** | true / **7** | **no** |
| Tape event vocabulary | `turn_start`,`delta`,`stream_end`,`completion`,`input_context`,`tool_call`,`tool_result` | identical set | **no** |
| Tape row growth with no turn | +21 rows in 7 min (`activity`/`log`) | same behaviour | **no** |
| Memory budget | 100000/50000 | **40000/20000** | yes (intended) |
| schema_version | 32 | 32 | **no migration** |
| sessions / messages | 411 / 6,344 | 414 / 6,358 | +3 / +14, all driven |
| `SOUL.md` identity prefix | `659dbbaa…` | `659dbbaa…` | **no** |
| Fleet block | 2,596 B, no memory section | 4,264 B, memory section == HEAD | yes (intended) |
| skills | 18 | 18 | no |
| `MEMORY.md` | 100,217 B (archived) | 115 B, one entry | yes (intended) |
| Gate: cold block (3 tools) | 69 / 69 / 69 | 69 / 69 / 69 | **no** |
| Gate: no-session allow | allowed | allowed | **no** |
| MCP tools | 2 | 2 | no |
| `-mcp` targetPort | 13725 | **18397** | yes — Service follows |
| restarts | 52 | 0 | new pod |

**The tape's shape did not change.** That is measured, not assumed: a turn recorded on the
**old** image (session `20261019_072022_…`) carries the same vocabulary as the turns driven
on the new one —

```
turn 20261019_072022_f4054e:7dc76   (OLD image)
  activity=17, completion=2, delta=1444, input_context=2, stream_end=2,
  tool_call=2, tool_result=2, turn_start=2      core_shape: PRESENT   tool_events: yes
turn local-ede2af8d30bb823f1b315f   (NEW image, this phase's gate turn)
  activity=25, completion=4, delta=133, input_context=4, stream_end=5,
  tool_call=3, tool_result=3, turn_start=4      core_shape: PRESENT   tool_events: yes
```

So: **the upgrade changed the version, the budget and the persona block — and did not
change the tape, the gate, the schema, the identity or the skill set.** A check that passes
identically before and after is the evidence that the upgrade did not break it.

---

## 13. What I could NOT exercise, and why

1. **The gate with the plugin absent.** I verified the plugin half (block → allow, ledger
   written) and the CLI half separately, but I did not disable the plugin to prove the CLI
   half still blocks on its own — that needs a write (a configmap change), which is outside
   this brief.
2. **A fresh-PVC first boot.** Every check ran against an existing agent whose
   `.comm-seeded` is from Sep 30. The *first boot* path (skill seeding, the SOUL.md watcher
   at `mcp_entrypoint.sh:137`) is therefore untested here. It matters for a new install,
   not for the 60 existing agents.
3. **`plugins.isolation`.** Left unset, so plugins run in-process — h3 flagged that setting
   `host` would move `HERMES_HOME` resolution. Not exercised; the new config does not set it.
4. **The 60-agent propagation itself.** This is one sandbox agent; nothing here claims the
   other 59 behave identically. The before/after table is the per-agent template for that job.
5. **The documented install path end-to-end on a clean host.** I verified the *image* is
   identical and read h5's docs pass; I did not run `setup.sh`+`k8s-up.sh` on a bare box, so
   the `jq` gap is reported from h5, not re-measured here.
6. **Reasoning-delta rows.** h3's §7 point 3 says `plugins.stream_reasoning_deltas: true`
   must survive or `kind="reasoning"` rows silently stop. The turn I drove produced
   `kind="text"` deltas; I did not force a reasoning-heavy turn on this agent, so
   `reasoning` rows are **not** confirmed here.

---

## 14. Cluster writes

**I wrote nothing to the cluster.** Every kubectl invocation in this brief was `get`,
`describe`, `logs` or a read-only `exec` running a script that opens files and SQLite in
read-only mode and prints hashes and counts. No `apply`, `patch`, `delete`, `scale`,
`rollout`, `create`, `edit`, `cordon` or `drain`. No image was built and `sudo-agent:latest`
was never tagged — it remains `16d149ddf0f2…`, untouched.

Measured at the end of the run, not asserted:

```
$ kubectl get deploy -A --no-headers | wc -l
103                                    # unchanged from before this phase
$ kubectl get deploy -A ... | grep -c "sudo-agent:latest"
59                                     # 60 Hermes deployments minus the one sandbox
$ kubectl get deploy -A ... | grep "p2a-h1"
sudo-mail-bot-hermes sudo-agent:p2a-h1,sudo-agent:p2a-h1,   # exactly one deployment
$ docker image inspect sudo-agent:latest --format '{{.Id}} {{.Created}}'
sha256:16d149ddf0f2d8f9fcbf6bd94447d6790104660e98f7f32c9b46b120bd1b4bca 2026-10-18T23:12:48…
```

One deployment differs from `sudo-agent:latest`; the other 59 are untouched and the shared
tag still points at the old image, so nothing else in the fleet can be affected by this
phase until someone deliberately propagates.

The only state that changed on the pod was changed **by the pod's own agent in response to
prompts I sent** (two turns: the gate diagnostic and a one-word reply), which is what checks
1, 2 and 4 require in order to be real. Those two turns account for the entire
+3 sessions / +14 messages in §10.

---

## 15. Probe scripts (re-runnable)

Committed beside this report under `docs/p2-d-probes/`. All are secret-free and print no
message content — counts, hashes and event names only, because the subject of these checks
can be a mail agent.

| Script | Runs where | Purpose |
|---|---|---|
| `probe-runtime.sh` | inside the agent container | version, plugin.json, tape size, budget, `state.db` counts, identity, gate ledger, instruction presence |
| `probe-tape.sh` | inside the agent container | tape rows/bytes + event histogram over the tail (no payload text) |
| `probe-tape-turns.py` | inside the agent container | per-turn event vocabulary — the "same shape" check |
| `probe-tape-tools.py` | inside the agent container | tool_call/tool_result pairs for one session (the block→allow evidence) |
| `probe-gate.sh` | inside the agent container | gate ledger, `.usage.json` writability, CLI-half block/allow in both directions |
| `probe-soul.sh` | inside the agent container | splits SOUL.md into identity prefix vs managed block, hashes each |
| `probe-history.py` | inside the agent container | `session_search` + session spans, counts and dates only |
| `mcp-call.py` | anywhere with network to the pod | stdlib streamable-HTTP MCP client: `tools/list`, `tools/call` |

Run them as:

```
kubectl -n <ns> exec <pod> -c sudo-agent -- sh -s        < probe-runtime.sh
kubectl -n <ns> exec <pod> -c sudo-agent -- python3 -   < probe-tape-turns.py
python3 mcp-call.py --url http://<clusterIP>:8000/mcp --list
```

*Read-only. One agent. The fleet was not touched.*
