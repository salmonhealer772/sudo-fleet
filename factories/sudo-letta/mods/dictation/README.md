# @letta-ai/dictation — `/listen` + `/done`

Dictate speech into an agent chat from a microphone that is **somewhere else**:
your Mac, a Windows box, a WSL2 host, or the machine the CLI already runs on.
The mod is a thin, machine-agnostic client of a recorder you point it at; it
never contains a Mac-specific script.

Two hard properties, by design:

1. **No time limit.** There is no wall clock, no maximum duration, and no
   session-truncation timer anywhere in this mod. Dictation runs for as long as
   you talk. The only timers are shutdown watchdogs (how long to wait for the
   recorder's own confirmation before deciding it is stuck).
2. **`/done` never sends to the agent.** It stops the recorder, takes the
   transcript, and puts it in your composer **unsent and editable** — exactly as
   if you had typed it. Nothing reaches the model until you press Enter.

```
/listen     start recording
/done       stop, collect, put the text in the composer (press Enter to send)
```

Neither command needs the agent, so both work while it is mid-turn.

---

## Configuration

Everything machine-specific lives in environment variables. There are two
shapes; use whichever fits the deployment.

### Shape A — one shell command (`DICTATION_CMD`)

| Variable | Meaning |
| --- | --- |
| `DICTATION_CMD` | **Required (shape A).** A shell command, run with `/bin/sh -c`, that starts your recorder and speaks the JSON protocol below on stdout. |
| `DICTATION_STOP_CMD` | Optional. A shell command run on `/done` to stop the recorder deterministically. If unset, `/done` writes a single line `stop\n` to the recorder's stdin and closes it (see *Stopping*). |

Either command is **refused** (and never run) if it contains
`StrictHostKeyChecking=no` — write `accept-new` plus `BatchMode=yes`,
`ConnectTimeout` and `ServerAliveInterval` yourself, exactly as shape B does.

### Shape B — SSH to the microphone (`DICTATION_HOST` + `DICTATION_REMOTE_CMD`)

Used when `DICTATION_CMD` is unset. The mod builds the `ssh` call itself, so
the SSH options are not something you can get wrong:

| Variable | Meaning |
| --- | --- |
| `DICTATION_HOST` | **Required (shape B).** ssh target, `user@host` or `host`. |
| `DICTATION_REMOTE_CMD` | **Required (shape B).** Command to run on the remote host (one shell string; the remote shell parses it). |
| `DICTATION_REMOTE_STOP_CMD` | Optional. Command run over ssh to stop the recorder. If unset, the `stop\n`-on-stdin rule applies. |
| `DICTATION_SSH_KEY` | Optional. `-i <key>`. |
| `DICTATION_SSH_PORT` | Optional. `-p <port>`. |

Shape B always uses, in this order:

```
-o BatchMode=yes
-o StrictHostKeyChecking=accept-new
-o ConnectTimeout=10
-o ServerAliveInterval=15
-o ServerAliveCountMax=4
```

`StrictHostKeyChecking=no` is never used: `accept-new` still trusts a host key
only on first contact and refuses a changed key. `BatchMode=yes` keeps ssh from
ever prompting for a password (use a key). `ServerAliveInterval` keeps the
session from being dropped silently mid-dictation.

### Delivery

| Variable | Meaning |
| --- | --- |
| `DICTATION_COMPOSER` | `auto` (default) / `inject` / `output` / `off`. `auto` inserts into the composer when a TUI is attached, otherwise shows the transcript only. `output` never inserts. `off` inserts nothing and prints nothing. |

---

## The recorder JSON contract

Your recorder is a normal program. **stdout carries newline-delimited JSON**
(one object per line). **stderr carries human logs** and is never parsed. The
mod ignores blank lines, tolerates non-JSON stdout lines (it treats them as log
lines for the panel), and ignores unknown `type` values, so you can add fields
without breaking old clients.

Five message types. `type` is required; extra fields are allowed and ignored.

### `status`

```json
{"type":"status","message":"connected, mic open"}
```

Human-readable progress. Shown in the live panel. No effect on the transcript.
Use it to make a slow ssh/whisper warm-up visible.

### `partial`

```json
{"type":"partial","text":"hello and welcome to the"}
```

The **in-progress** transcript of the current utterance. **Replaces** the
previous partial (it is not appended). The panel updates the moment a line
arrives — send one per recognised token/segment, not on a fixed interval, and
the operator watches words appear as they speak.

### `final`

```json
{"type":"final","text":"hello and welcome to the show."}
```

A **completed** utterance. Appended to the transcript, each `final` on its own
line. Clears the current partial (the recorder may then start a new one).

### `done`

```json
{"type":"done"}
```

The recorder has finished cleanly and is no longer recording. **Emit this once,
as the last message, then exit 0.** `done` is the mod's proof that the last
words are in — `/done` waits for it instead of guessing with a delay, so the tail
of the last sentence is never cut off.

### `error`

```json
{"type":"error","message":"whisper server unreachable at 10.0.0.5:8080"}
```

Fatal. Recorded, surfaced to the operator, and included in the `/done` summary
if shutdown does not confirm.

### Sequence

```
{"type":"status","message":"connecting"}
{"type":"status","message":"mic open"}
{"type":"partial","text":"so the thing is"}
{"type":"final","text":"so the thing is, we need two more weeks."}
{"type":"partial","text":"and then"}
{"type":"final","text":"and then we ship."}
{"type":"done"}
```

Resulting transcript (`final`s joined by newline, plus a trailing `partial` if
the recorder never finalised it):

```
so the thing is, we need two more weeks.
and then we ship.
```

### Exit codes

- `0` after `done` — clean. `/done` reports success.
- `0` without `done` — accepted with a note ("exited without a done line").
- non-zero / killed by signal — reported as a failure, with the tail of stderr.

### Stopping

`/done` stops the recorder exactly one way:

1. If `DICTATION_STOP_CMD` (or `DICTATION_REMOTE_STOP_CMD` in shape B) is set, it
   is run as its own process. **Its exit status is checked and surfaced** — a
   failing stop command is reported to the operator, never swallowed. It gets 8
   seconds.
2. Otherwise the mod writes one line, `stop\n`, to the recorder's stdin and
   closes it. Your recorder should treat either EOF on stdin or the line `stop`
   as "stop now, flush the last utterance, print `done`, exit 0".

Then the mod waits for your `done` line (20s, inside a 25s overall budget —
the environment kills any command at 30s). If `done` never arrives it says so
plainly in the summary and terminates the process anyway, so a microphone is
never left hot. The recorder is spawned in its own process group and stopped as
a group (SIGTERM, then SIGKILL), so an `sh -c "ssh …"` pipeline cannot leave an
orphaned ssh listening after `/done`. A recorder that has already died on its
own keeps its transcript: `/listen` refuses to start a new session until `/done`
has taken it, so nothing is silently dropped. A recorder that dies within a
quarter second of `/listen` without producing a word is reported as a failed
start ("exited immediately: <stderr>"), not as a live session.

---

## Worked examples

### The CLI's own machine (local mic)

```bash
export DICTATION_CMD='/opt/recorder/listen.sh --whisper http://127.0.0.1:8080'
export DICTATION_STOP_CMD='/opt/recorder/stop.sh'
```

### A Mac on the LAN, dictating into an agent on the linux host

```bash
export DICTATION_HOST='aidan@192.0.2.2'
export DICTATION_SSH_KEY="$HOME/.ssh/id_ed25519_mac"
export DICTATION_REMOTE_CMD='/usr/local/bin/dictate --whisper http://10.0.0.5:8080 --json-lines'
export DICTATION_REMOTE_STOP_CMD='pkill -f /usr/local/bin/dictate || true'
```

### A Windows box / WSL2 host

Same as above; point `DICTATION_HOST` at the WSL2 sshd or the Windows OpenSSH
server and put your recorder behind `DICTATION_REMOTE_CMD`. Nothing in the mod
knows or cares which it is — the only requirement is that the remote side can
run a program that speaks the JSON above and can be told to stop.

### Testing without a microphone

```bash
export DICTATION_CMD='printf "%s\n" \
  "{\"type\":\"status\",\"message\":\"fake recorder\"}" \
  "{\"type\":\"partial\",\"text\":\"hello\"}" \
  "{\"type\":\"final\",\"text\":\"hello world\"}" \
  "{\"type\":\"done\"}"'
```

Then `/listen`, then `/done`: "hello world" appears in your composer, unsent.
(That recorder exits immediately; the mod marks the session `ended` and `/done`
still delivers.)

---

## How `/done` gets text into the composer

The composer's value is React state inside the input component. There is no mod
API, bus event or host command that writes it, and the `turn_start` veto cannot
do it either: the composer only restores text when the submit handler returns
`{submitted: false}`, a mod command always resolves to `{submitted: true}`, and
the veto path only writes a status line. An armed veto would therefore leave the
input box empty *and* silently swallow your next real message.

What the TUI *does* read is its own stdin: the input component parses bracketed
pastes (`ESC[200~ … ESC[201~`) and inserts them into the composer. A mod runs in
that same process, so this mod pushes the transcript onto stdin as bracketed
paste chunks — the exact path a terminal paste takes. Consequences:

- the text lands in the composer, editable, **unsent**;
- only paste bytes are ever written — never a newline or an Enter key — so the
  agent cannot receive it before you press Enter;
- long transcripts are split into ≤5-line / ≤500-char chunks because the
  composer collapses anything larger into a `[Pasted text #N +M lines]`
  placeholder (the content is still preserved and expanded on send, but it is
  no longer inline-editable);
- it requires an interactive TUI. Headless/desktop-listener sessions get the
  transcript in the `/done` output instead, which the summary says explicitly.
  Set `DICTATION_COMPOSER=output` to force that behaviour everywhere.

This is the only route into the input box that exists in letta-code 0.33.2. If a
first-class prefill API ever appears, `deliverToComposer` is the single function
to change.

---

## Install

Ships as a first-class repo mod (`factories/sudo-letta/mods/dictation/`) and is
installed by `factories/sudo-letta/bin/up.sh` from the `COMM_MODS` array:

```
"mods/dictation|npm:@letta-ai/dictation@0.1.0"
```

Bump `version` here **and** that verify string together.

## Self-test

```
node test/selftest.mjs      # from this directory
```

Runs the state machine against fake recorders (multi-utterance, silent, crashing,
ignoring the stop), checks the no-time-limit property, the double-`/listen`
refusal, the "stop command failed" surfacing, and asserts the exact bytes the
composer delivery writes. No letta process required.
