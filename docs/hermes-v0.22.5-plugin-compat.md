# P1-C — Will our two plugins still fire on Hermes v0.22.5?

**Answer: YES. All nine hooks exist in v0.22.5, and every payload field our
plugins read is still delivered.** The tape stays lit. The gate stays armed.

Read-only desk research. Nothing on the cluster was touched. Method: the actual
v0.22.5 source tree (GitHub tag `v0.22.5`, annotated tag object `56b6a31`), read
file by file at the fire sites, then machine-checked with three scripts whose
output is reproduced below. Not inferred from release notes.

Provenance of the code under test — pulled from the host copies, hashed so the
reader can confirm it is the version I analysed:

```
b7b5eb12a6091855f9c12ecdaafc9a16d1e0995bc32d32d4d59c2411552b1315  watch_plugin/__init__.py   (1021 lines)
89df73a2f5e93929465b25e5db056de0c6d95b3837117b6e42104933442cbc22  watch_plugin/plugin.yaml
97b59d4814cc22e8be60e7694955ef96e5de7524eddd5f7d7127a697fbc82eb4  comm_gate/__init__.py      (188 lines)
64a68e0585e0ada6d855f9684004e1c5ef062c7b99f415cd8121e32514319721  comm_gate/plugin.yaml
```

`00-FACTS.md` F16 and F17 agree with the code exactly: 7 hooks + 2 hooks = 9, no
drift between the fact table, `plugin.yaml`, and the `ctx.register_hook()` calls.

---

## 1. The table — read this and you can decide

| # | Hook | Plugin | What our callback reads out of the payload | v0.22.5 | Verdict |
|---|---|---|---|---|---|
| 1 | `on_stream_start` | watch | `turn_id`, `iteration`, `session_id`, `model`, `provider`, `surface` | present, all 6 | **unchanged** |
| 2 | `on_stream_delta` | watch | `delta`, `kind` + the 6 turn fields | present, all 8 | **unchanged** |
| 3 | `on_stream_end` | watch | `final_text`, `finished`, `error` + the 6 turn fields | present, all 9 | **unchanged** |
| 4 | `pre_api_request` | watch | `turn_id`, `session_id`, `model`, `provider`, `api_call_count`, `api_request_id`, `task_id`, `api_mode`, `message_count`, `tool_count`, `approx_input_tokens`, `request_char_count`, `max_tokens`, `started_at`, `request`, `system_prompt`, `user_message`, `request_messages`, `conversation_history`, `platform` | all present | **unchanged** |
| 5 | `post_api_request` | watch | `turn_id`, `api_call_count`, `session_id`, `model`, `provider`, `platform`, `assistant_message`, `usage`, `finish_reason`, `api_duration`, `response_model`, `assistant_content_chars`, `assistant_tool_call_count`, `api_mode` | all present (+`context_length` added) | **unchanged** |
| 6 | `pre_tool_call` | watch | `tool_name`, `args`, `tool_call_id`, `turn_id`, `session_id`, `api_request_id`, `task_id` | present, all 7 | **unchanged** |
| 7 | `post_tool_call` | watch | `tool_name`, `args`, `result`, `status`, `error_type`, `error_message`, `duration_ms`, `tool_call_id`, `turn_id`, `session_id`, `api_request_id`, `task_id` | present, all 12 | **unchanged** |
| 8 | `on_skill_lifecycle` | gate | `action`, `skill_name`, `session_id` (fires with `action="loaded"`) | present, all 3 | **unchanged** |
| 9 | `pre_tool_call` | gate | `tool_name`, `session_id`, `args["command"]`; **returns** `{"action":"block","message":...}` | present, block contract honoured | **unchanged** |

Nine of nine unchanged. Zero missing. Zero unknown.

Two footnotes that are *not* defects, and why:

- Row 4: `surface` is the one field the plugin reads that the fire site does not
  send — in v0.22.5 **or** in the version we run today. The callback does
  `surface = kw.get("surface") or ""` then `surface or platform`, and `platform`
  is always sent, so it falls back cleanly. The `input_context` event never
  carried a `surface` key in the first place (it carries `platform`). No loss.
- Rows 6/7: the callbacks read `tool_name or name`. `tool_name` is always sent;
  `name` is a dead fallback that is never reached. No loss.

---

## 2. Evidence, hook by hook

### 2.1 The three stream hooks (the tape's core)

**What our plugin registers** — `watch_plugin/__init__.py:1000-1010`, seven
`ctx.register_hook()` calls; the three stream callbacks are
`_on_stream_start`, `_on_stream_delta(delta="", kind="text", **kw)`,
`_on_stream_end(final_text="", finished=True, error=None, **kw)`.

**What v0.22.5 sends.** The base payload is one dictionary, and every stream
hook is emitted as `base + fields`:

```python
# agent/stream_delivery.py:282-290  (v0.22.5)
def _stream_hook_base_payload(self):
    return {"turn_id": ..., "iteration": int(self._api_call_count ...),
            "session_id": self.session_id or "", "model": self.model or "",
            "provider": self.provider or "", "surface": self.platform or "cli"}
```

```python
# agent/stream_delivery.py:293, 296, 332, 362  (v0.22.5)
self._enqueue_stream_hook("on_stream_start")
self._enqueue_stream_hook("on_stream_end", final_text=final_text, finished=finished, error=error)
self._enqueue_stream_hook("on_stream_delta", delta=text, kind="text")
self._enqueue_stream_hook("on_stream_delta", label=..., delta=text, kind="reasoning")
```

Same kwarg names our callbacks declare: `delta`, `kind`, `final_text`,
`finished`, `error`. **Source: v0.22.5 `agent/stream_delivery.py:282-362`;
`agent/plugin_stream_hooks.py:133-171` for the dispatcher. Corroborated by
`website/docs/user-guide/features/hooks.md:466-468, 515-534`, which publishes
the identical payload list.**

Note on dispatch: stream hooks do not go through `invoke_hook`. They are queued
per-callback onto a dedicated dispatcher thread (`plugin_stream_hooks.py:133`),
which is exactly why the plugin's "never block the model" queue design still
applies. The dispatcher calls `callback(**payload)` with no signature
narrowing, and our callbacks take `**kw`, so nothing is dropped on the floor.

`on_stream_end` fires per API call, not per turn — that is why the plugin
synthesises a `stream_end` from `post_api_request` for non-streaming paths. Both
behaviours are unchanged (the docstring's `synthesized` note was written against
the same runtime).

### 2.2 `pre_api_request` / `post_api_request`

**What v0.22.5 sends:**

```python
# agent/turn_api_request.py:62-91  (v0.22.5)
_invoke_hook("pre_api_request",
    task_id=..., turn_id=..., api_request_id=..., session_id=...,
    user_message=..., conversation_history=list(messages), platform=...,
    model=..., provider=..., base_url=..., api_mode=..., api_call_count=...,
    retry_count=..., request_messages=..., system_prompt=...,
    message_count=..., tool_count=..., approx_input_tokens=...,
    request_char_count=..., max_tokens=..., started_at=...,
    middleware_trace=..., request=agent._api_request_payload_for_hook(api_kwargs))
```

```python
# agent/turn_response_intake.py:66-95  (v0.22.5)
_invoke_hook("post_api_request",
    task_id=..., turn_id=..., api_request_id=..., session_id=..., platform=...,
    model=..., provider=..., base_url=..., api_mode=..., api_call_count=...,
    api_duration=..., started_at=..., ended_at=..., first_chunk_at=...,
    finish_reason=..., message_count=..., response_model=..., response=...,
    usage=agent._usage_summary_for_api_request_hook(response),
    context_length=..., assistant_message=assistant_message,
    assistant_content_chars=len(assistant_message.content or ""),
    assistant_tool_call_count=len(getattr(assistant_message, "tool_calls", None) or []),
    moa_references=...)
```

Every field the plugin reads is in those two lists. `assistant_message` is a
message **object**, not a dict (`post_api_request` hands the normalised
`assistant_message`), and the plugin correctly does
`getattr(msg, "content", None)` — so the non-streaming answer text path is
intact.

`post_api_request` gains `context_length` in v0.22.5 — purely additive, the
plugin ignores it.

**Source: v0.22.5 `agent/turn_api_request.py`, `agent/turn_response_intake.py`;
docs `hooks.md:460-461`.**

### 2.3 `pre_tool_call` (both plugins) and `post_tool_call`

**v0.22.5 `pre_tool_call` payload** (`hermes_cli/plugins.py:1956-1961`):

```python
hook_results = invoke_lifecycle_hook(
    "pre_tool_call", tool_name=tool_name, args=args if isinstance(args, dict) else {},
    task_id=task_id, session_id=session_id, tool_call_id=tool_call_id, turn_id=turn_id,
    api_request_id=api_request_id, middleware_trace=list(middleware_trace or []))
```

Watch's callback reads `tool_name`, `args`, and the five ids — all present.
Gate's callback reads `tool_name`, `args["command"]`, `session_id` — all present.

**The block contract still works.** `hermes_cli/plugins.py:1964-1985` scans the
returned results for `{"action": "block", "message": ...}` and returns it as the
veto; `_resolve_block_from_details` (`:2021-2050`) turns it into the tool
result. Gate returns exactly that shape with a non-empty message
(`comm_gate/__init__.py:163-178`; the return dict is at 172-177), which is required — a block with no message
is discarded (`:1982-1983`). Ours has one.

**v0.22.5 `post_tool_call`** (`model_tools.py:691-696`) maps the internal names
onto the public ones at the boundary:

```python
invoke_hook("post_tool_call", tool_name=function_name, args=function_args,
            result=result, **_CallIds(...).hook_kwargs(), duration_ms=...,
            status=..., error_type=..., error_message=..., middleware_trace=...)
```

So the `function_name`/`function_args` internal naming does **not** leak to
plugins — the hook receives `tool_name`/`args`, exactly what the watch plugin
reads. Status/error fields are derived from the result when not supplied
(`:689-690`).

**Source: v0.22.5 `hermes_cli/plugins.py:1941-2061`, `model_tools.py:674-698`;
docs `hooks.md:451-452`.**

### 2.4 `on_skill_lifecycle` (the gate's arm)

**The chain, read end to end in v0.22.5:**

1. The model calls `skill_view` → registry handler `_skill_view_with_bump`
   (`tools/skills_tool.py:734-760`) → on success
   `bump_use(str(resolved), task_id=kw.get("task_id"), session_id=kw.get("session_id"))`.
   The registry passes `session_id` through because the handler accepts `**kw`
   (`tools/registry.py:946-965`, `_kwargs_accepted_by` at 957).
2. `bump_use` (`tools/skill_usage.py:497-508`) applies the usage mutation and
   calls `_mutate_and_emit(skill_name, "loaded", ..., session_id=session_id)`.
3. `_mutate_and_emit` (`:485-489`) emits **only if the usage write landed**.
4. `_emit_skill_lifecycle` (`:470-480`) fires:

```python
invoke_hook("on_skill_lifecycle", action=action, skill_name=skill_name,
            provenance=..., task_id=task_id or "", session_id=session_id or "",
            use_count=..., reused=..., reuse_after_patch=...)
```

Our gate reads `action == "loaded"`, `skill_name`, `session_id` — all three are
in that call, with the same string `"loaded"`.

**Source: v0.22.5 `tools/skills_tool.py`, `tools/skill_usage.py`,
`tools/registry.py`; docs `hooks.md:477` (payload matches verbatim).**

⚠️ One structural dependency worth stating plainly, because it is the gate's
single point of failure and it is **not new**: step 3 means the hook only fires
if `<HERMES_HOME>/skills/.usage.json` is writable (`tools/skill_usage.py:52`).
If that write fails, `on_skill_lifecycle` never fires, the gate never records a
load, and **every gated tool is blocked forever**. Identical code and identical
path in v2026.9.24, so this is not an upgrade risk — but it is the thing to
watch on the canary (check 7 below), because its failure mode is "everything
blocked" and the cause is a file permission, not a hook.

---

## 3. How it was checked (so you can re-run it)

Three probes, all against the extracted v0.22.5 tree and the real plugin files.
No cluster, no Hermes import, no network at run time.

**(1) Static verifier** — parses `VALID_HOOKS` out of v0.22.5, then AST-parses
each fire site, resolves `**splat` payloads (the stream base dict, the
`_CallIds(...).hook_kwargs()` splat) and diffs the fields sent against the fields
each callback reads:

```
VALID_HOOKS in v0.22.5: 46 hooks
hook                plugin in VALID_HOOKS verdict    fields we read that the fire site does NOT send
------------------------------------------------------------------------------------------------------
on_stream_start     watch  True           UNCHANGED  -
on_stream_delta     watch  True           UNCHANGED  -
on_stream_end       watch  True           UNCHANGED  -
pre_api_request     watch  True           PARTIAL    ['surface']      <- see footnote, row 4
post_api_request    watch  True           UNCHANGED  -
pre_tool_call       watch  True           PARTIAL    ['name']         <- dead fallback, tool_name is sent
post_tool_call      watch  True           PARTIAL    ['name']         <- dead fallback
on_skill_lifecycle  gate   True           UNCHANGED  -
pre_tool_call       gate   True           UNCHANGED  -
```
The three PARTIALs are the two benign footnotes in §1, enumerated mechanically.

**(2) Entry-point proof** — imported both real plugin modules, called
`register(ctx)` with a stub context, checked every registered name against
v0.22.5's `VALID_HOOKS`:

```
sudo-watch-stream              has register(ctx): True
  registered on_stream_start / on_stream_delta / on_stream_end /
             pre_api_request / post_api_request / pre_tool_call / post_tool_call
  in VALID_HOOKS=True  (all seven)
sudo-comm-gate                 has register(ctx): True
  registered on_skill_lifecycle / pre_tool_call
  in VALID_HOOKS=True  (both)
watch state file written: True   -> {"plugin": "sudo-watch-stream", "loaded": true, ...
RESULT: PASS
```
This runs on Python 3.14.7, stdlib only, no repo imports — so it also proves the
plugins still import cleanly in the new base's interpreter.

**(3) Tape proof** — drove the registered callbacks with the *exact* kwargs the
v0.22.5 fire sites send (enumerated in §2), then read the resulting
`stream.jsonl`:

```
stream.jsonl: 16 events
turn_start / delta(2) / stream_end / input_context / completion /
tool_call / tool_result / plugin_state      -- all present

tool_call.tool         = 'terminal'  args={'command': 'ls -la'}
tool_result.result     = 'total 0\n-rw-r--r-- 1 root root 0 a.txt'   status='ok' duration_ms=12
input_context.platform = 'cli'  msgs=1  user_message='hello there'
delta[0]               = 'hello ' kind='text' text_chars=6
stream_end.final_text  = 'hello world'  delta_count=2
completion.finish      = 'tool_calls'  usage={'prompt_tokens': 20, ...}  streamed=True
all events carry turn_id: True
RESULT: PASS
```
Payloads intact → the tape writes the same events, with the same field fidelity,
against v0.22.5's contract.

**(4) Gate proof** — the three-step sequence a real turn takes:

```
gated cmd before skill load blocks             PASS   {"action":"block","message":"BLOCKED: load the message-agent skill first, then retry."}
same cmd after skill load passes               PASS
a DIFFERENT gate still armed (list-siblings)   PASS
ungated command never touched                  PASS
other session is not credited                  PASS
no session_id -> defer to CLI half (None)      PASS
action='patched' does NOT unlock               PASS
RESULT: PASS
```

---

## 4. (a) Did the plugin entry point change shape?

**No. `register(ctx)` + `ctx.register_hook(name, callback)` is intact, and it is
the documented contract.**

- `hermes_cli/plugins.py:943` — `def register_hook(self, hook_name: str, callback: Callable) -> PluginRegistration` — same name, same two positional arguments, now returns a registration handle (ignorable, ours ignores it).
- `hermes_cli/plugins_loader.py:526-531` — the loader still resolves `getattr(module, "register")` and calls `register_fn(ctx)`; a module with no `register()` is still "no register() function".
- The `ctx` object is still `PluginContext`; `register_hook` is one of the
  documented `PluginContext` methods that v0.22.5 promises not to remove or
  rename (`website/docs/developer-guide/plugins/index.md:230-253`,
  `plugins/AGENTS.md` "Native plugin compatibility contract").
- Behaviour on an unknown name is unchanged and worth knowing: `register_hook`
  **warns but still stores** the callback (`plugins.py:954-963` — the
  warning is logged, then `mapping.setdefault(key, []).append(callback)` runs anyway). An unknown
  hook name is therefore silent-ish, not loud — which is exactly the failure
  class this report exists to rule out. It is ruled out: all nine are in
  `VALID_HOOKS`.

Proof: probe (2) above — both real modules, real `register(ctx)`, all nine names
accepted.

## 5. (b) New hooks our watch plugin should adopt

**Streaming was not renamed and not split.** Comparing `VALID_HOOKS` between the
version we run (`v2026.9.24`, 41 hooks) and `v0.22.5` (46 hooks):

- **Removed: none.** Nothing we subscribe to disappeared.
- **Added: five** — `on_human_input_request`, `on_human_input_resolved`,
  `on_session_delete`, `post_compaction`, `post_gateway_admission`.
- None of the five is a streaming hook. `on_stream_start/delta/end` and
  `on_interim_message` exist in both, with identical payloads.

So there is no *new* hook the tape needs because of the upgrade. There are,
however, three **pre-existing holes** in the tape that this upgrade is a good
moment to close. In priority order:

1. **`pre_auxiliary_call` / `post_auxiliary_call`** — the biggest gap. Auxiliary
   LLM calls (title generation, compression, the **background review fork**,
   vision, approval) deliberately do **not** fire `pre/post_api_request`; they
   fire these two instead (`agent/auxiliary_hooks.py`, and `plugins.py:120-124`
   says so explicitly: "distinct events so turn-scoped `*_api_request`
   subscribers never receive auxiliary traffic"). Consequence today: the tape is
   blind to every background-review LLM call. It only sees them as the
   `housekeeping` surface heuristic on *turn* events, never as the call itself.
   Payload = the `*_api_request` shape **plus `aux_task`**, so the watch plugin's
   existing `_on_pre_api_request` body would work almost verbatim with
   `api_task` tagging the row.
2. **`api_request_error`** — a failed provider attempt produces no `completion`
   line at all today. That is the "why did this turn just go quiet" case the
   tape is supposed to answer. Payload includes `status_code`, `reason`,
   `retryable`, `retry_count`, `error` (`hooks.md:462`).
3. **`post_compaction`** (new in this release) — fires once per committed
   compaction with `before_tokens`, `after_tokens`, `messages_removed`
   (`hooks.md:475`). A compaction is the one sanctioned mid-conversation context
   change; without this the tape shows a turn that suddenly remembered less.

`on_interim_message` (`text`, `already_streamed` + turn fields) also exists in
both and is unsubscribed — mid-loop assistant text never reaches the tape. Lower
priority than the three above because the deltas mostly cover it.

## 6. (c) Did plugin LOADING change?

**No — the discovery path, the config key, and the enable step are all the same.**
Our plugins are shipped as ConfigMaps mounted at
`/opt/data/plugins/<key>/` and enabled via `plugins.enabled` in the per-agent
config (`up.sh:439-490, 970-980`). Checked against v0.22.5:

| What we rely on | v0.22.5 | Evidence |
|---|---|---|
| User plugin dir `<HERMES_HOME>/plugins/<key>/` is scanned | yes | `hermes_cli/plugins_discovery.py:209` — `user_dir = get_hermes_home() / "plugins"` |
| `plugins.enabled` is the opt-in gate | yes | `plugins_discovery.py:299-303` — "not in `plugins.enabled`" → skipped |
| Key matches our directory name | yes | `plugins_manifest.py:341` — `manifest_key()` = path-derived `key`, falling back to `name`; our dir and `name:` are both `sudo-watch-stream` / `sudo-comm-gate`, so either spelling matches |
| `kind: standalone` is valid | yes | `plugins_manifest.py:27` — `_VALID_PLUGIN_KINDS = {standalone, backend, exclusive, platform, model-provider}` |
| Entry point | yes | `plugins_loader.py:526-531` — `register_fn(ctx)` |
| `plugins.stream_reasoning_deltas` (reasoning deltas) | yes, same key, still default `False` | `agent/plugin_stream_hooks.py:156-166` |
| Load deadline / hook timeout knobs | same, existed in 9.24 too | `config_defaults.py:1727-1750` — `load_timeout_seconds: 10`, `hook_callback_timeout: 30` |

Two things that are *not* a change but are worth knowing before the build:

- `plugins.isolation` exists in v0.22.5 (`in_process` default, `host` opt-in).
  Our images leave it unset, so plugins stay in-process. If anything in the new
  `config.yaml` template sets `isolation: host`, the plugins would run in a
  separate host process — they would still register hooks, but `HERMES_HOME`
  resolution and the watch plugin's own file writes should be re-checked. **h2's
  file, not mine — just flagging that no such key should appear.**
- `plugins.hook_callback_timeout` defaults to 30 s and `pre_tool_call` is
  **fail-closed** on timeout: a slow `pre_tool_call` callback blocks the tool
  with "pre_tool_call plugin callback timed out or is still running"
  (`plugins_dispatch.py:60, 277-285`). This is identical in v2026.9.24, so it is
  not new — but it means our observer plugin and our gate share the tool path
  with the same 30 s budget. Both callbacks are queue-puts / one small JSON read,
  which is microseconds.

---

## 7. What I would watch on the canary (concrete, not "check the logs")

The upgrade is safe on this axis, so these are confirmations rather than
investigations. Both are already checks 5 and 7 in
`PROPAGATION-FEASIBILITY.md` §5 — this report just tells you what a pass looks
like with the plugin's own vocabulary.

1. **Tape is live, not just non-empty.** After one turn, `<HERMES_HOME>/watch/plugin.json`
   must exist with `"loaded": true` and seven hooks listed, and `stream.jsonl`
   must gain a `turn_start`, at least one `delta`, a `completion`, and — if the
   turn called a tool — a `tool_call` **with a non-empty `tool` field**. A tape
   that is writing `turn_start` but empty `tool` names would mean the
   `function_name → tool_name` boundary moved; it has not, per §2.3.
2. **Gate is armed, and its ledger is writable.** Call a gated tool cold and
   expect exactly `BLOCKED: load the <skill> skill first, then retry.`, then load
   the skill via `skill_view` and confirm the retry passes. If the gate blocks
   *after* a successful `skill_view`, check that
   `/opt/data/skills/.usage.json` is writable and that its mtime moves on the
   load — that is the failure mode described in §2.4, and it looks like a hook
   failure while being a filesystem one.
3. **Reasoning deltas.** `plugins.stream_reasoning_deltas: true` must survive
   into the new config; with it absent, `kind="reasoning"` rows silently stop
   while `kind="text"` rows keep flowing — a partial-dark tape, the exact silent
   failure this report was asked to prevent.

---

## 8. What breaks first if this goes wrong

If a hook *had* moved, the very first thing to go dark is `on_stream_delta` — it
is the highest-frequency hook and the one the console reads, so the operator
would see a silent screen while the agent kept answering normally, and the
transcripts would look empty rather than wrong. The second casualty is the gate:
it fails in whichever direction its two hooks go, blocking every comm tool (loud,
at least) or quietly allowing everything (silent). Neither happened here: all
nine hooks and every field they read are present in v0.22.5, verified at the
fire site and reproduced by running the plugins against the new contract.

**Recommendation: P1-D is clear to build on `nousresearch/hermes-agent:v0.22.5`.
The plugin contract is not a reason to hold.** (Tag independently confirmed:
docker tag `v0.22.5`, multi-arch amd64+arm64, pushed 2026-10-23T02:36Z — matches
F27/F28, so h1's pin is correct.)

---

## Sources

Ordered as the brief ranks them. Every verdict above cites at least one.

1. **Upstream source, tag `v0.22.5`** (annotated tag `56b6a31`, 2026-10-23) —
   full tree extracted from `codeload.github.com/NousResearch/hermes-agent/tar.gz/refs/tags/v0.22.5`:
   `hermes_cli/plugins.py`, `hermes_cli/plugins_dispatch.py`,
   `hermes_cli/plugins_loader.py`, `hermes_cli/plugins_discovery.py`,
   `hermes_cli/plugins_manifest.py`, `hermes_cli/lifecycle.py`,
   `hermes_cli/config_defaults.py`, `agent/stream_delivery.py`,
   `agent/plugin_stream_hooks.py`, `agent/turn_api_request.py`,
   `agent/turn_response_intake.py`, `model_tools.py`, `tools/skill_usage.py`,
   `tools/skills_tool.py`, `tools/registry.py`, `hermes_constants.py`.
2. **Upstream docs shipped in that tag** —
   `website/docs/user-guide/features/hooks.md` (the published payload table,
   lines 451-478 and 515-541) and
   `website/docs/developer-guide/plugins/index.md` § "Native plugin
   compatibility contract" (lines 230-253). `plugins/AGENTS.md` for the
   discovery/kinds table.
3. **Source of the version we run today, `v2026.9.24`** — the same files fetched
   at that tag, used only for the before/after diff (nothing removed, payloads
   identical, fail-closed `pre_tool_call` already present).
4. **Release metadata** — GitHub releases API (`latest` = `v0.22.5`,
   2026-10-23T05:28Z); Docker Hub tags API for `nousresearch/hermes-agent`
   (`v0.22.5`, amd64 + arm64).
5. **Our own code and wiring** —
   `phase1-src/watch_plugin/{__init__.py,plugin.yaml}`,
   `phase1-src/comm_gate/{__init__.py,plugin.yaml}`,
   `phase1-src/up.sh:439-490, 970-980, 1033-1040`,
   `phase1-src/Dockerfile`.
6. **Brief docs** — `RESEARCH.md` §6, `PROPAGATION-FEASIBILITY.md` §2.2 and §3,
   `00-FACTS.md` F16/F17/F27/F28, `01-PHASE-1-PLAN.md`.

**Not used, deliberately:** the running pods. No agent was exec'd into, restarted,
scaled, or read from. The isolation rule held.

---

*P1-C. Read-only. No repository file was changed by this investigation; this
report is the only artifact.*
