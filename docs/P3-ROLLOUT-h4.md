# P3 rollout — h4 batch: the recreate is BLOCKED, every agent is intact

**Phase 3, brief h4.** Nine live agents were assigned to this hand. **Zero were upgraded. Zero were
damaged.** The batch canary failed on its first attempt and, per the brief's own instruction ("if it
fails, stop and report — do not plough through the other 8"), the remaining eight were not attempted.

**PASS 0 · HOLD 9.**

The one line that matters: **every one of the nine agents still holds its own history, its own skills
and its own SOUL — byte-identical to the baseline I captured before starting.** Nothing migrated,
nothing was lost, nothing was recreated. All nine are still running `sudo-agent:latest` and healthy.

The blocker is a defect in `factories/sudo-agent/bin/up.sh`, not in the image and not in any agent.
It is one line, it is in h1's file, and I did not touch it (file-partition rule).

Owner: sudo-fleet-glm-h4 · Date: 2026-10-28/29 (UTC) · Namespace: `default`

---

## 1. Verdict

| | |
|---|---|
| Agents assigned | **9** |
| Upgraded to `sudo-agent:p2a-h1` | **0** |
| PASS | **0** |
| HOLD | **9** (1 attempted-and-rejected, 8 not attempted) |
| Agents that lost history or skills | **0** |
| Deployments whose spec I changed | **0** |
| `sudo-agent:latest` re-pointed | **no** — still the rollback image |

The image is not in question. I verified both ends of the identity chain before attempting anything:

```
docker      sudo-agent:p2a-h1   sha256:ebc56f72e84a2342b59344fdb413534e998420b69c0b12ea7e6b504ed63edbf9
containerd  docker.io/library/sudo-agent  p2a-h1  2003be5cb4349   1.08GB
docker      sudo-agent:latest   sha256:16d149ddf0f2…   (untouched, the rollback target)
```

Both digests match the brief and P2-B's image of record. The recreate never got far enough to use it.

---

## 2. STEP 1 — before, captured for all nine

One instrument (`measure.sh`) was used for before and after, so the comparison is like-for-like:
`state.db` read-only through sqlite on the agent container, `ls skills | wc -l`, `md5sum SOUL.md`,
plus the deployment image and `hermes --version`.

| agent | sessions | messages | schema | skills | SOUL md5 (short) | image |
|---|---|---|---|---|---|---|
| sudo-linkedin-bot-h | 98 | 1,463 | 32 | 18 | `5ae4adb6` | `sudo-agent:latest` |
| sudo-qtest-hermes | 17 | 33 | 32 | 18 | `bcaf1840` | `sudo-agent:latest` |
| sudo-vast-glm-h | 54 | 753 | 32 | **22** | `7a21cc7c` | `sudo-agent:latest` |
| sudo-ya-glm-h | 166 | 6,157 | 32 | 18 | `2fa82e08` | `sudo-agent:latest` |
| sudo-ya-glm-h2 | 74 | 2,904 | 32 | 18 | `9d42ae4e` | `sudo-agent:latest` |
| sudo-ya-glm-h3 | 51 | 1,523 | 32 | 18 | `e95822cf` | `sudo-agent:latest` |
| sudo-ya-glm-h4 | 52 | 1,669 | 32 | 18 | `342c247a` | `sudo-agent:latest` |
| sudo-ya-glm-h5 | 58 | 1,532 | 32 | 18 | `385058c9` | `sudo-agent:latest` |
| sudo-ya-glm-h6 | 46 | 1,351 | 32 | 18 | `742e1b26` | `sudo-agent:latest` |

Every one reports `Hermes Agent vunknown (2026.9.24)` — the version drift P2-D recorded — and patch
marker `1`, i.e. all nine are genuinely on the old image. `schema_version` is **32** everywhere, as
the brief said it would be.

### 2.1 `sudo-qtest-hermes` was at 0 replicas — I had to scale it up

Confirmed at 0 before touching it, as the brief warned. I scaled it to 1, waited for the rollout,
confirmed a 2/2 pod, captured the four numbers above, and only then treated it as a normal agent.

**Because the recreate never happened, I scaled it back to 0** at the end, returning it to the
replica count it had when I found it. Its PVC and store were never touched, so it lost nothing: the
17/33/18 baseline above still reads 17/33/18 in `state.db`. A retry will need to scale it to 1 again.

---

## 3. STEP 2 — the budget, set in all nine (this part is done and it is safe)

All nine per-agent configs existed; none had to be created. Each still read `100000 / 50000`.

Edited with `sed` on the anchored key, and **proved confined**: for every file, the md5 of the file
*with both `*_char_limit` lines stripped* is identical before and after, so nothing outside those two
numbers moved — `model`, `display.skin`, `plugins`, `stream_reasoning_deltas`, `_config_version` and
`platforms.api_server.port` all survive byte-identically.

```
linkedin-bot-h  CONFINED  2 lines  stripped_md5_same=yes   memory 40000 / user 20000
qtest-hermes    CONFINED  2 lines  stripped_md5_same=yes   memory 40000 / user 20000
vast-glm-h      CONFINED  2 lines  stripped_md5_same=yes   memory 40000 / user 20000
ya-glm-h        CONFINED  2 lines  stripped_md5_same=yes   memory 40000 / user 20000
ya-glm-h2 .. h6 CONFINED  2 lines  stripped_md5_same=yes   memory 40000 / user 20000
```

The real diff, one file, in full — this is the entire config change I made to all nine:

```
8,9c8,9
<   memory_char_limit: 100000
<   user_char_limit: 50000
---
>   memory_char_limit: 40000
>   user_char_limit: 20000
```

These files are gitignored instance material (`factories/sudo-agent/.gitignore`) and are not committed.

---

## 4. STEP 3 — the canary, and the defect that stopped the batch

### 4.1 The command, verbatim, and what it returned

```
cd /opt/0-0/sudo-fleet/factories/sudo-agent && \
KUBECONFIG=/etc/rancher/k3s/k3s.yaml SUDO_AGENT_IMAGE=sudo-agent:p2a-h1 \
  bash bin/up.sh --linkedin-bot-h
```

It ran cleanly through every earlier stage — port assignment, the 66-config uniqueness guard, watch
digests, the image digest (`sha256:ebc56…`), preservation of the deployment's operator-added env, and
image import (`→ sudo-agent:p2a-h1 present in containerd`). Then it died at the one step that matters:

```
error: error when applying patch:
  … for: "/opt/0-0/sudo-fleet/factories/sudo-agent/deployments/linkedin-bot-h.yaml":
  error when patching …: The order in patch list:
  [... API_SERVER_KEY … API_SERVER_HOST … API_SERVER_PORT …]
   doesn't match $setElementOrder list: [...]
✗ kubectl apply failed. Check: kubectl cluster-info
UP_EXIT=1
```

### 4.2 Why — duplicate env names, generated by `up.sh` itself

The generated manifest carries **three env names twice**:

```
 - name: API_SERVER_KEY     (valueFrom: secretKeyRef …)   <- template, line ~956
 - name: API_SERVER_HOST    value: "0.0.0.0"              <- template
 - name: API_SERVER_PORT    value: "<config port>"        <- template
 - name: API_SERVER_ENABLED value: "true"                 <- preserved from live deployment
 - name: API_SERVER_HOST    value: "0.0.0.0"              <- preserved AGAIN
 - name: API_SERVER_PORT    value: "<stale old port>"     <- preserved AGAIN
 - name: API_SERVER_MODEL_NAME …
 - name: API_SERVER_KEY     value: "<literal key>"        <- preserved AGAIN
```

Two mechanisms, out of sync:

1. The manifest template **defines** `API_SERVER_KEY`, `API_SERVER_HOST` and `API_SERVER_PORT`
   (`bin/up.sh` ~951-964, the `platforms.api_server` block, unconditional on every deploy).
2. The **preserve** step (~589-620) carries forward "every env entry the template does not itself
   define" — but its `TEMPLATE_ENV_NAMES` allow-list says:

   ```
   ["DEEPSEEK_API_KEY","LLM_API_KEY","SUDO_PASSWORD","HERMES_YOLO_MODE","MCP_PORT","AGENT_NAME","PERSONA_NAME","REDIS_URL"]
   ```

   `API_SERVER_*` is **not** in it. So the three names the template just emitted are re-appended from
   the live deployment as "extras". Duplicate `env` names make kubectl's client-side apply compute a
   patch whose ordering contradicts `$setElementOrder`, and the apply is rejected outright.

This is confirmed at `HEAD`, not inferred — `git show HEAD:factories/sudo-agent/bin/up.sh | grep -n TEMPLATE_ENV_NAMES`
returns the list above, with no `API_SERVER_*` entry. The allow-list was written when the template did
not define those names; the template later grew the api_server block and the list was never updated.

**Worth noting beyond the crash:** had the apply *succeeded*, last-wins on duplicate env names would
have handed the agent the **stale** operator values — the literal API key instead of the secretRef, and
the old port instead of the config-assigned one. The rejection was the safer outcome.

### 4.3 It failed SAFE — this is the important part

I verified the live agent was not touched, rather than trusting the error message:

| check | result |
|---|---|
| Deployment generation | **16 — unchanged** (not incremented) |
| Deployment image, both containers | `sudo-agent:latest` — unchanged |
| Pod | still the same pod, 2/2 Running, restarts 7 (20h ago) — **no restart caused** |
| `state.db` | 98 sessions / 1,463 messages / schema 32 — identical to baseline |
| skills | 18 — identical |
| `SOUL.md` md5 | `5ae4adb6…` — byte-identical |
| Fleet-wide deployment→image map | the only lines that changed were **other hands'** agents moving to `p2a-h1`; none of my nine moved |

So the canary cost the agent nothing. It cost the batch its schedule.

---

## 5. What I did NOT do, deliberately

- **Did not edit `bin/up.sh`.** The one-line fix is
  `TEMPLATE_ENV_NAMES` + `API_SERVER_KEY`, `API_SERVER_HOST`, `API_SERVER_PORT` — which makes the
  template's secretRef key and config-assigned port win over the stale literals, exactly the intended
  end state. But `up.sh` is h1's file and outside my partition; the planner owns that call.
- **Did not attempt the other eight.** The brief's canary rule is explicit, and the canary did fail.
  Eight of the nine have no literal `API_SERVER_KEY`, so they are *probably* unaffected — but "probably"
  is not a basis for rolling eight live agents when I was told to stop. All eight are captured and ready.
- **Did not use `kubectl rollout restart`**, did not touch `sudo-agent:latest`, did not touch any agent
  outside my list, did not delete any `.comm-seeded`.

### 5.1 Side effects of the failed run, disclosed

The run aborted at `kubectl apply`, but it had already written supporting objects. All are additive to
my one agent:

1. **Secrets created**: `sudo-linkedin-bot-h-api-key`, `sudo-linkedin-bot-h-api-server-key`.
2. **Service created**: `sudo-linkedin-bot-h-api`.
3. **ConfigMaps applied**: the three `…-watch-config`, `…-watch-plugin`, `…-comm-gate-plugin`
   (pre-existing, re-applied).
4. **Shared Redis re-applied — proven a no-op**: `sudo-agent-redis` is `generation 3`,
   `resourceVersion 1002953` — *character-for-character the baseline P2-B recorded* — and its pod's
   restart count is unchanged. It printed "rolled out" but nothing moved.
5. **The per-agent config** got `platforms.api_server.enabled: true` and an `mcp_servers` block from
   the preserve/enable steps. Since the deployment was never updated, that describes a deployment that
   does not exist, so **I restored the file to its pre-run content** and re-applied only the two budget
   numbers. Verified by diff: the only remaining delta is the two char limits (§3).
6. **Paperclip auto-hire did not run** (it sits after the apply). Nothing was created there.

I left 1-3 in place: deleting a Secret or Service is a larger cluster write than the failed run made,
and none of them is referenced by the running pod.

---

## 6. Final state at hand-off — every agent is itself

Re-measured all nine *after* the attempt, with the same instrument as the baseline. **Before and after
are identical on all five axes** (sessions, messages, schema_version, skill count, SOUL md5):

| agent | before | after | image | version |
|---|---|---|---|---|
| sudo-linkedin-bot-h | 98 / 1,463 / 32 / 18 | 98 / 1,463 / 32 / 18 | `sudo-agent:latest` | vunknown (2026.9.24) |
| sudo-qtest-hermes | 17 / 33 / 32 / 18 | 17 / 33 / 32 / 18 | `sudo-agent:latest` | vunknown (2026.9.24) |
| sudo-vast-glm-h | 54 / 753 / 32 / 22 | 54 / 753 / 32 / 22 | `sudo-agent:latest` | vunknown (2026.9.24) |
| sudo-ya-glm-h | 166 / 6,157 / 32 / 18 | 166 / 6,157 / 32 / 18 | `sudo-agent:latest` | vunknown (2026.9.24) |
| sudo-ya-glm-h2 | 74 / 2,904 / 32 / 18 | 74 / 2,904 / 32 / 18 | `sudo-agent:latest` | vunknown (2026.9.24) |
| sudo-ya-glm-h3 | 51 / 1,523 / 32 / 18 | 51 / 1,523 / 32 / 18 | `sudo-agent:latest` | vunknown (2026.9.24) |
| sudo-ya-glm-h4 | 52 / 1,669 / 32 / 18 | 52 / 1,669 / 32 / 18 | `sudo-agent:latest` | vunknown (2026.9.24) |
| sudo-ya-glm-h5 | 58 / 1,532 / 32 / 18 | 58 / 1,532 / 32 / 18 | `sudo-agent:latest` | vunknown (2026.9.24) |
| sudo-ya-glm-h6 | 46 / 1,351 / 32 / 18 | 46 / 1,351 / 32 / 18 | `sudo-agent:latest` | vunknown (2026.9.24) |

None of the five after-checks can pass for any of them, because none is on the new image:
(a) pod 2/2 Running ✓ but on the old pod — not a recreate; (b) image ≠ `p2a-h1` ✗;
(c) version ≠ v0.22.5 ✗; (d) four numbers unchanged *because nothing happened*;
(e) `## Your memory` = 0 and patch marker = 1 ✗ — the old image, untouched.

**All nine pods were 2/2 Running** at hand-off; `sudo-qtest-hermes` was returned to 0 replicas as found.

---

## 7. The rows

| agent | before (ns,nm,sk) | after (ns,nm,sk) | image | version | verdict |
|---|---|---|---|---|---|
| sudo-linkedin-bot-h | 98,1463,18 | 98,1463,18 | `sudo-agent:latest` | vunknown | **HOLD** — up.sh apply rejected, duplicate `API_SERVER_*` env |
| sudo-qtest-hermes | 17,33,18 | 17,33,18 | `sudo-agent:latest` | vunknown | **HOLD** — not attempted (canary failed) |
| sudo-vast-glm-h | 54,753,22 | 54,753,22 | `sudo-agent:latest` | vunknown | **HOLD** — not attempted (canary failed) |
| sudo-ya-glm-h | 166,6157,18 | 166,6157,18 | `sudo-agent:latest` | vunknown | **HOLD** — not attempted (canary failed) |
| sudo-ya-glm-h2 | 74,2904,18 | 74,2904,18 | `sudo-agent:latest` | vunknown | **HOLD** — not attempted (canary failed) |
| sudo-ya-glm-h3 | 51,1523,18 | 51,1523,18 | `sudo-agent:latest` | vunknown | **HOLD** — not attempted (canary failed) |
| sudo-ya-glm-h4 | 52,1669,18 | 52,1669,18 | `sudo-agent:latest` | vunknown | **HOLD** — not attempted (canary failed) |
| sudo-ya-glm-h5 | 58,1532,18 | 58,1532,18 | `sudo-agent:latest` | vunknown | **HOLD** — not attempted (canary failed) |
| sudo-ya-glm-h6 | 46,1351,18 | 46,1351,18 | `sudo-agent:latest` | vunknown | **HOLD** — not attempted (canary failed) |

Machine-readable: `h4-P3-rows.tsv` beside this file.

---

## 8. What the planner needs to decide

1. **Fix `TEMPLATE_ENV_NAMES` in `bin/up.sh`** (h1's file): add `API_SERVER_KEY`, `API_SERVER_HOST`,
   `API_SERVER_PORT`. Then re-run the canary. Until that lands, `up.sh` cannot deploy any agent whose
   live deployment predates the api_server block *and* carries those names as literals.
2. **Unauthorise-or-authorise the other eight.** They have no literal `API_SERVER_KEY`, so the duplicate
   is unlikely — but I did not test them and I will not claim they are safe without running them.
3. **`sudo-neu-bot-h` is in h2's batch and carries the same signature.** I warned h2 (two messages,
   id `msg-40c20db22f65` and `msg-c05c6b14949b`). I also told h2 that their `sudo-sbaco-hermes1`
   went green on `p2a-h1`, so this does not stop their whole batch.

The batch is ready to resume the moment `up.sh` is fixed: baselines are captured, budgets are set,
and nothing has to be undone.
