---
name: dictation-setup
description: Wire up /listen and /done so speech from a microphone on another machine (Mac, Windows, WSL2, or the CLI's own host) lands in a Letta agent's composer, unsent. Use when dictation "is not configured", when /listen fails or refuses to start, when a recorder starts but no words appear, or when you must point an agent's dictation at a new mic host without hardcoding that machine into the mod.
---

# dictation-setup

`@letta-ai/dictation` adds two operator commands to a Letta Code agent:

- **`/listen`** — spawns a *recorder* and shows a live panel of partials.
- **`/done`** — stops it, waits for its `done` line, and puts the transcript in
  the composer **unsent** (the operator edits it, then presses Enter).

The mod ships installed on every `sudo-letta` deploy (`COMM_MODS` in
`factories/sudo-letta/bin/up.sh`). It contains **no recorder**: no audio code, no
Mac script, nothing machine-specific. It is a thin client of a program you point
it at, so "dictation does not work" almost always means "there is no recorder
configured", not "the mod is missing".

The authority for what a recorder must print is
**`factories/sudo-letta/docs/dictation-recorder-contract.md`**. Read it before
writing one; this skill is the wiring procedure around it.

## The starting state: no recorder, by design

Nothing in this repo sets a `DICTATION_*` variable, and `up.sh` injects only a
closed list of env vars (LLM creds, web-search keys, `HCLOUD_TOKEN`, `HOME`,
`LETTA_HOME`, `MCP_PORT`, …). So on a fresh deploy `/listen` answers:

```
Dictation is not configured: no recorder command is set. set DICTATION_CMD
(a shell command that runs your recorder) — see the dictation setup skill.
```

That message is the mod's `SETUP_HINT` and it names **this skill by name** — do
not rename the `dictation-setup` directory, or the hint sends operators nowhere.

## Step 0 — confirm the mod is actually installed

```bash
# on the host
kubectl get pods | grep '^sudo-.*-l-'          # find the letta pod
kubectl exec <pod> -- bash -c 'HOME=/home/node node /usr/local/lib/node_modules/@letta-ai/letta-code/letta.js mods list' | grep -i dictation
```

Expect:

```
enabled  npm:@letta-ai/dictation@0.1.0    commands, events.turns, ui.panels
```

- **absent** → the deploy's mod install did not run or failed; run the deploy
  (`bin/up.sh`) and read its output. Do not hand-install a different version:
  `up.sh` verifies `npm:@letta-ai/dictation@0.1.0` and aborts the deploy on a
  mismatch.
- **disabled** → re-enable it and restart the CLI process.

Config is resolved **on each `/listen`** (not at mod load), but `process.env` is
fixed when the CLI process starts — so a new env value needs a fresh process.

## Step 1 — pick a shape

Both shapes are env-only. Nothing is hardcoded; the same mod serves every host.

| Shape | Use when | Variables |
| --- | --- | --- |
| **A — one command** | the recorder is reachable as a shell command (mic on the CLI's own machine, or a wrapper script you already trust) | `DICTATION_CMD` (+ optional `DICTATION_STOP_CMD`) |
| **B — ssh to the mic** | the microphone is on your Mac / a Windows or WSL2 box, and the agent runs elsewhere | `DICTATION_HOST` + `DICTATION_REMOTE_CMD` (+ optional `DICTATION_REMOTE_STOP_CMD`, `DICTATION_SSH_KEY`, `DICTATION_SSH_PORT`) |

`DICTATION_CMD` **wins** if both are set. In shape B the mod builds ssh itself
with `BatchMode=yes`, `StrictHostKeyChecking=accept-new`, `ConnectTimeout=10`,
`ServerAliveInterval=15`, `ServerAliveCountMax=4` — do not try to improve on
that. A hand-written command containing `StrictHostKeyChecking=no` is **refused
and never run**; that flag makes the mic link a man-in-the-middle target.

Also decide delivery (`DICTATION_COMPOSER`): `auto` (default), `inject`,
`output`, `off`. See step 4 — in a headless pod the difference is visible.

## Step 2 — get a recorder that speaks the contract

Either use an existing one (`--json-lines` style ASR wrappers) or write one from
the skeleton in `docs/dictation-recorder-contract.md` §10. The four things that
break real setups, in order of frequency:

1. **stdout must be one JSON object per line, flushed.** Log to stderr. A
   recorder writing to stdout through a pipe block-buffers and shows nothing
   until exit — indistinguishable from a dead mic.
2. **`partial` replaces, `final` appends.** Repeating a settled utterance in the
   next `partial` duplicates it in the transcript; the mod does not de-duplicate.
3. **Honour both `stop\n` on stdin and EOF**, and trap `SIGTERM` to flush and
   print `done`. Otherwise the mod's 20 s wait expires and it kills the process
   group — losing the last utterance.
4. **No maximum duration.** No wall clock, no `--maxdur`. The only timers are
   shutdown watchdogs.

For shape B, key-based auth is mandatory (`BatchMode=yes` never prompts). The
key file must exist **inside the pod** at `DICTATION_SSH_KEY`, with pod-local
permissions — a host path means nothing there.

## Step 3 — put the values in the pod's environment

This is the part that has no durable home yet. Two routes:

**Temporary (verification only):**

```bash
kubectl set env deploy/<deploy> \
  DICTATION_HOST='aidan@192.0.2.2' \
  DICTATION_SSH_KEY='/home/node/.ssh/id_ed25519_mac' \
  DICTATION_REMOTE_CMD='/usr/local/bin/dictate --whisper http://10.0.0.5:8080 --json-lines' \
  DICTATION_REMOTE_STOP_CMD='pkill -f /usr/local/bin/dictate || true'
```

**Durable:** the values must be emitted by the deployment generator, i.e. added
to `ENV_YAML` in `factories/sudo-letta/bin/up.sh` (which `kubectl apply`s a
regenerated Deployment every deploy — so anything set with `kubectl set env`
disappears on the next deploy). `bin/up.sh` is **not** owned by this skill:
raise it with the planner / the `up.sh` owner rather than editing it from here.
The shape to add, next to the other optional keys:

```bash
for _opt in DICTATION_HOST DICTATION_REMOTE_CMD DICTATION_REMOTE_STOP_CMD \
            DICTATION_SSH_KEY DICTATION_SSH_PORT DICTATION_CMD \
            DICTATION_STOP_CMD DICTATION_COMPOSER; do
  _val=$(grep "^${_opt}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | head -1 || true)
  [[ -n "$_val" ]] && ENV_YAML+="
        - name: ${_opt}
          value: \"${_val}\""
done
```

Verify the value landed inside the pod, not just on the Deployment:

```bash
kubectl exec <pod> -- printenv | grep DICTATION_
```

## Step 4 — prove it, in this order

**a) No microphone needed.** Point the mod at a fake recorder and check that
text arrives. In an attached TUI session:

```
expose DICTATION_CMD: printf '%s\n' '{"type":"status","message":"fake"}' '{"type":"partial","text":"hello"}' '{"type":"final","text":"hello world"}' '{"type":"done"}'
```

then `/listen`, then `/done`. "hello world" appears in the composer, unsent. That
recorder exits immediately, so the session goes to `ended` and `/done` collects
it — that is correct behaviour, not a bug.

**b) The mod's own state machine.** On the host, from the package directory:

```bash
docker run --rm -v /opt/0-0/sudo-fleet/factories/sudo-letta/mods/dictation:/mod \
  -w /mod node:22-alpine node test/selftest.mjs
```

Expect `19/19 checks passed`. It covers the no-time-limit property, the
double-`/listen` refusal, a failing stop command, a recorder that ignores
stop, and the exact paste bytes delivered.

**c) The real microphone.** `/listen`, speak, `/done`. Watch the panel: it must
update on every `partial`, not once at the end (if it only appears at the end,
your recorder is buffering stdout).

**d) Know where the text can land.** Composer insertion needs an **interactive
TUI**: a TTY stdin whose `readable` handler is attached. A `kubectl exec -it`
session into the CLI qualifies; a headless/desktop-listener process, a cron job,
or the MCP server does not. When it cannot insert, the mod says so and the
transcript still appears in the `/done` output — verify the *words*, not the box.
Use `DICTATION_COMPOSER=output` to make that explicit everywhere.

## Failure table

| Operator sees | Cause | Fix |
| --- | --- | --- |
| `Dictation is not configured: no recorder command is set` | no `DICTATION_CMD`, and no `DICTATION_HOST`+`DICTATION_REMOTE_CMD` | step 3 |
| `Dictation is not configured` **despite** setting it in `.sudo-letta/.env` | the deploy does not forward `DICTATION_*` | step 3 durable route |
| `Already recording. Stop this dictation with /done` | a session is live | `/done`, then `/listen` |
| `The previous dictation ended before its transcript was collected` | recorder died; transcript held | run `/done` to collect it, then `/listen` |
| `Nothing is recording` | `/done` with no session | start with `/listen` |
| `DICTATION_CMD uses StrictHostKeyChecking=no …` | unsafe flag in the command | use `accept-new` + `BatchMode=yes`; the mod will not run it |
| `exited immediately: <stderr>` | recorder died within 250 ms with no words (bad path, ssh auth, missing key) | fix what stderr says; fail fast, don't retry-loop |
| recorder runs, panel never updates | recorder buffering stdout | flush per line; log to stderr |
| `/done` says the recorder never confirmed, words may be short | recorder ignores `stop\n`/EOF/`SIGTERM` | trap them, flush, print `done`, exit 0 |
| transcript duplicated | a `partial` repeated already-finalised text | clear the partial after each `final` |
| `/done` says the text went to output, not the composer | no interactive TUI | expected; use a TUI session or `DICTATION_COMPOSER=inject` where a TTY exists |

## Rules

- **Never** put `StrictHostKeyChecking=no` in any `DICTATION_*` command. It is
  refused, and it is how a mic link becomes an MITM target.
- **Never** add a maximum duration or a truncation timer to a recorder, and
  never add one to the mod.
- **Never** hardcode a host, user, key path, or ASR URL into
  `mods/dictation/mods/index.mjs` — that is what the env vars are for.
- Bump `mods/dictation/package.json` **and** the `COMM_MODS` verify string in
  `bin/up.sh` (`"mods/dictation|npm:@letta-ai/dictation@0.1.0"`) together, or
  deploys either skip the install or abort.
- `DICTATION_SSH_KEY` and any token are secrets: never echo them, never commit
  them, and keep them out of recorder stderr (stderr is quoted to the operator
  on failure).
