# Dictation recorder contract

The normative interface between the `@letta-ai/dictation` mod and a **recorder**
— the program that actually captures a microphone and produces text.

- **Audience:** whoever writes, packages, or debugs a recorder for a fleet agent.
- **Scope:** the wire protocol, the transcript-assembly rule, the shutdown
  handshake, and the exit codes. Everything a recorder must do to be driven by
  `/listen` and `/done`.
- **Not in scope:** how to pick an ASR engine, or how to install the mod. The
  operator-facing guide is `factories/sudo-letta/mods/dictation/README.md`; the
  procedure for wiring one deployment is the `dictation-setup` skill
  (`factories/sudo-letta/skills/dictation-setup/`).

**Source of truth.** This document specifies the behaviour of the mod as
implemented in `factories/sudo-letta/mods/dictation/mods/index.mjs` at package
version **0.1.0** (letta-code `>=0.33.0`). The parser, the timings and the
delivery rules below were read out of that file, not restated from prose. If the
mod and this document ever disagree, the mod wins and this document is the bug.

The mod is a **thin client**. It contains nothing machine-specific: no audio
code, no Mac script, no whisper call. It spawns your recorder and parses what
comes back. That split is the whole reason the contract exists — a recorder for
a Mac, a WSL2 box, a Windows OpenSSH server and the CLI's own host are the same
program from the mod's point of view.

## 1. The two channels

A recorder is an ordinary program, spawned by the mod with `/bin/sh -c`
(shape A) or `ssh <target> <remote-cmd>` (shape B).

| Channel | Carries | Parsed? |
| --- | --- | --- |
| **stdout** | newline-delimited JSON, one object per line | **yes** — this is the protocol |
| **stderr** | human logs, progress, warnings | no — kept only as the tail quoted on failure |
| **stdin** | the mod's stop signal (`stop\n`, then EOF) | your recorder must honour it |

Consequences that bite people:

- **stdout is for the protocol only.** A stray `echo "listening..."` becomes a
  log line (see §3), but a stray multi-line dump becomes N log lines and the
  operator's panel fills with noise. Log to stderr.
- **Flush every line.** The live panel updates on *arrival*, one line at a time.
  A recorder that buffers stdout (block-buffered because it is a pipe, not a
  TTY) shows nothing until exit, which looks exactly like a broken mod.
- **One object per line, no pretty-printing.** `JSON.stringify(obj) + "\n"`.
  A multi-line JSON object cannot be parsed and every line degrades to a log
  line.
- **Never `exit()` out from under a pending write.** In Node, `process.exit()`
  immediately after `process.stdout.write()` can truncate the buffered tail when
  stdout is a pipe (which it always is here) — the classic symptom is a missing
  `done`, which makes `/done` sit out its full 20 s wait and then report an
  unconfirmed stop. Exit from the write callback, or set `process.exitCode` and
  let the loop drain.

## 2. The five message types

`type` is required and is the only field the mod dispatches on. **Extra fields
are allowed and ignored** — add whatever you like to any message (timings,
confidence, utterance ids); old clients keep working.

### `status`

```json
{"type":"status","message":"connecting to whisper"}
```

Human-readable progress, shown in the live panel, **no effect on the
transcript**. Use it to make a slow ssh login or model warm-up visible — that is
what stops an operator concluding the mic is dead and typing `/done` into a
half-open recorder. Emit as many as you like.

### `partial`

```json
{"type":"partial","text":"hello and welcome to the"}
```

The in-progress transcript of the **current** utterance. It **replaces** the
previous partial; it is not appended. The panel redraws the moment a line
arrives, so send one per recognised token or segment — not on a fixed interval —
and the operator watches words appear as they speak.

Send `{"type":"partial","text":""}` to clear the line (e.g. after a
false-positive wake, or when re-decoding an utterance from scratch).

### `final`

```json
{"type":"final","text":"hello and welcome to the show."}
```

A **completed** utterance. It is appended to the transcript as its own segment
and clears the current partial. `text` is trimmed and **an empty or
whitespace-only `final` is dropped** — a phantom final cannot corrupt the
transcript.

Emit one `final` per utterance as soon as that utterance is settled. Do not hold
utterances back to emit them in a batch at the end: if the recorder is killed,
only what was already emitted is kept.

### `done`

```json
{"type":"done"}
```

The recorder is finished and is no longer recording. **Emit it once, as the last
message, then exit 0.** `done` is the mod's proof that the last words are in —
`/done` waits for it instead of guessing with a sleep, which is why the tail of
the final sentence is never truncated. A `done` that arrives after other output
is fine; output after `done` is not part of the contract.

### `error`

```json
{"type":"error","message":"whisper server unreachable at 10.0.0.5:8080"}
```

Fatal and operator-visible. It is recorded, surfaced in the panel and log, and
included in the `/done` summary if the shutdown handshake later fails to
confirm. Emit it when the recorder cannot do its job — an **absent** `error`
line plus a non-zero exit is a worse experience, because the operator sees only
an exit code. Emit `error`, then `done` if you can still shut down cleanly, or
just exit non-zero.

## 3. Tolerances (what the mod does with input that is not quite right)

These are guarantees you can rely on, and they are also the reason a buggy
recorder often "sort of works":

| Input | Mod behaviour |
| --- | --- |
| blank line | ignored |
| non-JSON line | treated as a human log line, shown in the panel |
| JSON that is not an object (array, string, number, `null`) | ignored entirely |
| unknown `type` | ignored — this is the forward-compatibility hatch |
| `partial` whose `text` is not a string | partial cleared |
| `final` with empty / whitespace `text` | dropped |
| missing `message` on `status`/`error` | tolerated; the line simply carries no text |
| very long line | no length cap |

Never repurpose an existing `type` with different semantics. Add a new one, or
add fields to the existing one — that is what keeps recorders and mods
independently upgradable.

## 4. Transcript assembly (normative)

The text the operator finally gets is defined exactly:

1. take every accepted `final` in arrival order;
2. if a `partial` was never finalised, append it last (better to hand over
   ragged words than to lose them);
3. join the pieces with `\n`;
4. trim the result.

So for this stream:

```
{"type":"status","message":"mic open"}
{"type":"partial","text":"so the thing is"}
{"type":"final","text":"so the thing is, we need two more weeks."}
{"type":"partial","text":"and then"}
{"type":"final","text":"and then we ship."}
{"type":"done"}
```

the transcript is:

```
so the thing is, we need two more weeks.
and then we ship.
```

**Do not repeat a settled utterance in the next `partial`.** The mod does not
de-duplicate: a `partial` carrying text that was already sent as a `final`
lands in the transcript twice.

## 5. The shutdown handshake

`/done` stops the recorder exactly one way:

1. **If a stop command is configured** (`DICTATION_STOP_CMD`, or
   `DICTATION_REMOTE_STOP_CMD` in ssh shape), it is run as its own process and
   **its exit status is checked and surfaced** — a failing stop command is
   reported, never swallowed. Budget: **8 s**.
2. **Otherwise** the mod writes one line, `stop\n`, to the recorder's stdin and
   closes it (EOF).

Then:

3. the mod waits **up to 20 s** for your `done` line, inside a **25 s** overall
   command budget (letta-code kills a mod command at 30 s);
4. if no `done` arrives it says so plainly in the summary, and terminates the
   recorder anyway — a microphone is never left hot. The recorder runs in its
   **own process group** and is stopped as a group: `SIGTERM`, then `SIGKILL`
   after a grace period. This is why an `sh -c "ssh …"` pipeline cannot survive
   as an orphaned ssh holding the mic open.

**What a recorder must implement:** treat either the line `stop` on stdin **or**
EOF on stdin as "stop now, flush the last utterance as a `final`, print `done`,
exit 0". If you are stopped by having your stdin closed, you have no way to
print anything further — so also **trap `SIGTERM`** and, if you are mid-utterance,
flush and print `done` before exiting. A recorder that ignores both signals and
blocks forever is killed, and its unflushed words are lost.

Two related timings:

- A recorder that dies within **250 ms** of `/listen` **without producing a
  word** is reported as a failed start (`exited immediately: <stderr>`), not as
  a live session. A recorder that fails its ssh login should therefore fail
  fast — do not sit in a retry loop that looks like a healthy session.
- A recorder that dies later on its own leaves the session in phase `ended` with
  its transcript intact; `/listen` refuses to start a new one until `/done` has
  collected it, so nothing is silently dropped.

## 6. Exit codes

| Exit | Meaning |
| --- | --- |
| `0` after `done` | clean shutdown; `/done` reports success |
| `0` without `done` | accepted, with a note that the recorder exited without confirming |
| non-zero, or killed by a signal | reported as a failure, with the tail of stderr |

## 7. There is no time limit

**A recorder must not impose a maximum duration.** No wall clock, no
`--maxdur`, no "10 minute" cap. A dictation runs until the operator says
`/done`. The only timers anywhere in this design bound *shutdown* (§5); none of
them run while the operator is talking, and none of them truncate a recording.
A recorder that stops itself on a timer breaks the mod's central promise.

## 8. Security requirements

- **`StrictHostKeyChecking=no` is refused.** In the ssh shape the mod builds the
  flags itself: `BatchMode=yes`, `StrictHostKeyChecking=accept-new`,
  `ConnectTimeout=10`, `ServerAliveInterval=15`, `ServerAliveCountMax=4`. A
  hand-written `DICTATION_CMD` / `DICTATION_STOP_CMD` containing
  `StrictHostKeyChecking=no` is **rejected outright and never run** — that flag
  turns the mic link into a man-in-the-middle target.
- Key-based auth only: `BatchMode=yes` means ssh will never prompt, so a
  password-protected key fails loudly instead of hanging.
- **stderr is quoted back to the operator** on failure. Do not log credentials,
  tokens, or full URLs with embedded auth to stderr.
- The recorder runs with the mod's privileges inside the agent's pod. It is a
  program the operator pointed at — not a sandbox.

## 9. Delivery is not the recorder's business

The recorder's job ends at `done`. Whether the text reaches the composer is the
mod's decision, from `DICTATION_COMPOSER` (`auto` default / `inject` / `output`
/ `off`):

- `auto` / `inject` push the transcript onto the TUI's stdin as bracketed paste
  chunks — at most **5 lines / 500 chars** per chunk, 60 ms apart, because
  larger pastes collapse into a `[Pasted text #N +M lines]` placeholder in the
  composer. Only paste bytes are written; **never a newline or Enter** — the
  agent cannot see the text until the operator presses Enter.
- insertion requires an interactive TUI on a TTY with its input handler
  attached; otherwise the mod degrades to output-only **and says so**.
- `output` never inserts and states why; `off` never inserts and stays silent.
  Any other value behaves like `auto`.

A recorder must never attempt to write to the composer, and must never print
bracketed-paste escape sequences (`ESC[200~` … `ESC[201~`) on stdout.

## 10. Reference recorder

A complete, working skeleton — the protocol wiring with the ASR left as the one
thing you plug in. Node is guaranteed present: the letta CLI is a Node program.

```js
#!/usr/bin/env node
// Reference recorder for the dictation contract (mod 0.1.0).
// Replace feed() with your ASR. Everything else is the contract.

const emit = (obj) => process.stdout.write(JSON.stringify(obj) + "\n"); // one line, flushed
const status = (message) => emit({ type: "status", message });

let current = "";                             // text of the in-progress utterance
const partial = (text) => { current = text; emit({ type: "partial", text }); };
const final = (text) => { current = ""; emit({ type: "final", text }); };

let stopping = false;
let finished = false;

function shutdown(code = 0) {
  if (finished) return;
  finished = true;
  const text = current.trim();
  if (text) final(text);  // never lose the words already recognised
  // Last line + flush. process.exit() right after a write can TRUNCATE a piped
  // stdout, which loses `done` and makes /done wait out its 20 s budget — exit
  // from the write callback instead.
  process.stdout.write(JSON.stringify({ type: "done" }) + "\n", () => {
    process.exit(code);
  });
}

function onStop() {
  if (stopping) return;
  stopping = true;
  shutdown(0);
}

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  // the mod writes exactly `stop\n`, then closes stdin
  if (chunk.split(/\r?\n/).some((line) => line.trim() === "stop")) onStop();
});
process.stdin.on("end", onStop);   // EOF means stop too
process.stdin.resume();
process.on("SIGTERM", onStop);     // the mod escalates to SIGKILL shortly after
process.on("SIGINT", onStop);

status("recorder starting");

// ---- plug your ASR in here ------------------------------------------------
// Call partial(text) on every recognised token/segment, and final(text) when
// an utterance settles. Example with a fake engine:
async function feed() {
  status("mic open");
  const utterances = [
    "so the thing is, we need two more weeks.",
    "and then we ship.",
  ];
  for (const settled of utterances) {
    if (stopping) return;
    const words = settled.split(" ");
    for (let i = 0; i < words.length; i++) {
      if (stopping) return;
      partial(words.slice(0, i + 1).join(" ")); // guess, replaced each time
      await new Promise((r) => setTimeout(r, 120));
    }
    final(settled);   // the utterance settles: ONE final, and partial is cleared
  }
  // a real recorder keeps listening here — no timer, no maximum duration
}
feed().catch((error) => {
  emit({ type: "error", message: String(error && error.message || error) });
  shutdown(1);
});
// ---------------------------------------------------------------------------
```

Run it by hand to see the protocol:

```bash
node recorder.mjs          # then type `stop` and press Enter
```

## 11. Conformance checklist

A recorder is conformant when all of these hold:

- [ ] stdout carries only newline-delimited JSON objects, one per line, flushed.
- [ ] stderr carries the human logs; nothing on stdout is prose.
- [ ] `status` used for progress; `partial` replaces; `final` appends and clears.
- [ ] a settled utterance is never repeated in a later `partial`.
- [ ] `done` is emitted exactly once, as the last line, before a `0` exit.
- [ ] the line `stop` on stdin **and** EOF on stdin both stop it cleanly.
- [ ] `SIGTERM` flushes the current utterance and prints `done`.
- [ ] no maximum duration, no truncation timer, no wall clock.
- [ ] failures produce an `error` line (and/or a non-zero exit), never silence.
- [ ] no `StrictHostKeyChecking=no`; no secrets on stderr.
- [ ] no attempt to write to the composer; no bracketed-paste bytes on stdout.

## 12. Varying the contract

- **New field on an existing type** — safe, ignore-and-go.
- **New type** — safe; older mods ignore it.
- **New semantics for an existing type** — breaking. Bump the mod's version
  (`mods/dictation/package.json`) **and** the verify string in
  `factories/sudo-letta/bin/up.sh` `COMM_MODS`
  (`"mods/dictation|npm:@letta-ai/dictation@0.1.0"`) together, or deploys either
  skip the install or abort on the version check.
