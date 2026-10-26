---
name: "@letta-ai/dictation"
description: "Operator commands /listen and /done: dictate speech into an agent chat from a microphone on another machine over SSH, with no time limit, ending with the transcript in the composer unsent."
---

# dictation mod semantics

This mod is **operator-facing, not agent-facing**. It registers no tools: the
model never sees it, and a dictation turn only exists once the operator presses
Enter.

## What it adds

Two slash commands:

- **`/listen`** — start dictating. Spawns the configured recorder and shows a
  live panel that updates on every `partial` line, so words appear as they are
  spoken.
- **`/done`** — stop dictating. Stops the recorder, waits for the recorder's own
  `done` confirmation, and places the transcript **in the operator's composer,
  unsent and editable**. It never sends anything to the agent.

Both are `runWhenBusy: true`, so an operator can start or stop dictating while
the agent is working; neither command needs the agent.

## The two non-negotiables

### 1. There is no time limit

No maximum duration, no wall clock, no "ten minutes" message, and no
`--maxdur`-style flag passed to any recorder. A dictation runs until the
operator says `/done`. The only timers in this mod bound *shutdown*
(how long to wait for the recorder to confirm it stopped) and composer chunk
delivery; none of them truncate a recording and none of them run while the
operator is talking.

### 2. `/done` does not send the text to the agent

`/done` returns a command result of type **`output`** — never `prompt`, which is
the type that sends. The transcript is:

- inserted into the composer as bracketed paste (editable, unsent, as if typed),
- and printed in the transcript pane in the `/done` output.

Only the operator's own Enter sends it.

### How the composer is filled, and why not with a `turn_start` veto

The composer value is React state private to the input component; no mod API
reaches it. The `turn_start` veto does **not** work for this in letta-code
0.33.2:

- the composer restores text only when the submit handler returns
  `{ submitted: false }`, and restores *what the operator submitted*;
- a mod command always resolves to `{ submitted: true }` — so does a normal
  message, after `await processConversation(...)`;
- the veto path only writes its reason into a status buffer and returns early.

An armed veto would leave the input box empty and silently swallow the
operator's next real message, and it cannot be made one-shot: the composer never
contains our transcript, so there is no content to match and no way to tell the
vetoed turn from the turn the operator meant to send.

Instead the mod uses the one input path the TUI really reads: its stdin paste
parser. The transcript is pushed as bracketed paste chunks, which the composer
inserts exactly like a terminal paste. Only paste bytes are written — never
Enter, never a newline — so nothing can be sent before the operator presses
Enter. Where no composer exists (headless, desktop listener), the mod degrades
to output-only and says so in the `/done` result.

## Configuration

The mod is a thin client of an external recorder; nothing about a particular
machine is hardcoded. Either hand it one shell command (`DICTATION_CMD`, plus
optional `DICTATION_STOP_CMD`), or hand it an ssh target and remote command
(`DICTATION_HOST` + `DICTATION_REMOTE_CMD`, optional `DICTATION_SSH_KEY`,
`DICTATION_SSH_PORT`, `DICTATION_REMOTE_STOP_CMD`) and let the mod build the ssh
call with `BatchMode=yes`, `StrictHostKeyChecking=accept-new`,
`ConnectTimeout=10`, `ServerAliveInterval=15`. `StrictHostKeyChecking=no` is
never used.

If nothing is configured, `/listen` fails with a short actionable message naming
the variable and pointing at the dictation setup skill — it does not silently do
nothing. A hand-written `DICTATION_CMD` / `DICTATION_STOP_CMD` that contains
`StrictHostKeyChecking=no` is refused outright: the mod never starts a recorder
that has disabled host key verification.

The full recorder JSON contract (`status` / `partial` / `final` / `done` /
`error`) and worked examples are in `README.md`.

## State machine (one owner)

| phase | meaning | `/listen` | `/done` |
| --- | --- | --- | --- |
| `idle` | nothing running | allowed | refused ("Nothing is recording") |
| `recording` | recorder live | refused (already recording) | collects |
| `stopping` | `/done` in flight | refused | refused (already stopping) |
| `ended` | recorder died on its own, transcript uncollected | refused until `/done` takes it | collects |

Exactly one session exists per process. There is no double-spawn: a second
`/listen` while one is live is refused explicitly, not incidentally. A `/listen`
after a failed `/done` is allowed, because `/done` always returns the session to
`idle`.

## Stopping and cleanup

`/done` stops the recorder with the deployment's stop command when one is
configured — and **checks its exit status**, reporting a failure instead of
swallowing it — otherwise by writing `stop\n` to the recorder's stdin and
closing it. It then waits for the recorder's own `done` line rather than killing
it after a fixed delay, so the last utterance is never truncated. If no `done`
arrives it says so plainly in the result and terminates the process anyway: a
microphone is never left hot. The recorder leads its own process group, and the
last-resort kill signals the whole group (SIGTERM then SIGKILL), so an
`sh -c "ssh …"` pipeline cannot survive as an orphaned ssh with the mic open.

The disposer returned from `activate()` kills the recorder and the stop child,
clears every timer, and closes the panel, so a mod reload leaks no processes.

## Panel

When `ui.panels` is available the mod opens one panel (id `dictation`, order 60,
max 6 lines) showing state, segment/character counts, the live tail of the
current partial, and the last log lines. It is refreshed on every recorder line —
genuinely incremental, not a periodic redraw. Without `ui.panels` the panel is
simply skipped and everything still works through command output.

## Failure behaviour

- recorder cannot start → `/listen` reports it and leaves no session behind.
- recorder dies mid-dictation → phase `ended`, panel/log say why, the transcript
  is kept, and a `turn_end` notification tells the operator to run `/done`.
- stop command fails → surfaced in the `/done` result (which is returned with
  `success: false`) while still handing over whatever was captured.
- recorder never confirms → reported plainly, process terminated, transcript
  delivered.

## Requirements

- letta-code >= 0.33.0 (command results, `events.turns`, `ui.panels`).
- A recorder program that speaks the JSON contract in `README.md`, reachable
  locally or over key-based ssh.
- For composer insertion: an interactive TUI. Anything else gets the transcript
  in the `/done` output.
