// @letta-ai/dictation
//
//   /listen   start dictating from a microphone that lives on ANOTHER machine
//             (their Mac, their Windows box, a WSL2 host) over SSH
//   /done     stop the recorder, take the transcript, and put it in the
//             operator's composer UN-SENT (they edit it, then press Enter)
//
// There is NO time limit anywhere in this mod. A dictation runs as long as the
// operator talks; the only timers are shutdown watchdogs.
//
// ---------------------------------------------------------------------------
// Why /done does not return { type: "prompt" }
// ---------------------------------------------------------------------------
// `prompt` calls handleIncomingMessage, i.e. it SENDS to the agent. /done must
// never do that. It returns `output` and places the text in the composer via
// the TUI input pipeline (see deliverToComposer).
//
// ---------------------------------------------------------------------------
// Why there is no turn_start veto
// ---------------------------------------------------------------------------
// The turn_start veto CANNOT do this job. Verified against letta-code 0.33.2
// (dist bundle, letta.js):
//
//   1. The composer only restores text when onSubmit returns
//      { submitted: false }:
//          setValue("");
//          const result = await onSubmit(previousValue);
//          if (!result.submitted) setValue(previousValue);
//      and it restores `previousValue` — what the operator submitted — not any
//      text of ours.
//   2. A mod command ALWAYS resolves to { submitted: true }: the whole mod
//      branch ends in `return { submitted: true }`, including after a `prompt`
//      result. A plain typed message ends the same way, after
//      `await processConversation(...)`.
//   3. The veto path inside processConversation only writes the reason into a
//      status buffer, clears userCancelledRef and returns early. It does not
//      call setRestoredInput and does not touch the composer.
//
// So an armed veto would (a) still not put a single character in the input box
// and (b) silently swallow the operator's NEXT submitted turn — a real message
// lost. It is not one-shot-able either: the composer never contains our
// transcript, so there is no content to match against and no way to tell "the
// turn I must veto" from "the turn the operator actually pressed Enter on".
// The input box is filled instead through the one path the TUI really reads:
// its stdin paste parser.

import { spawn } from "node:child_process";

const PANEL_ID = "dictation";
const PANEL_ORDER = 60; // > DEFAULT_PRODUCT_STATUS_ORDER (1) => above the status row
const PANEL_MAX_LINES = 6;
const PANEL_LOG_LINES = 2;

// The command runtime kills a mod command after MOD_COMMAND_TIMEOUT_MS (30000
// in letta-code 0.33.2) and reports a failure. /done must therefore finish well
// inside that window on its own terms, so the operator gets a real answer
// instead of a generic timeout.
//
// These are SHUTDOWN watchdogs only. Nothing here bounds a recording: while the
// operator is talking there is no timer at all.
const timings = {
  commandBudgetMs: 25000,
  stopCmdBudgetMs: 8000,
  doneWaitMs: 20000,
  exitGraceMs: 2000,
  killGraceMs: 1500,
  injectGapMs: 60,
  listenGraceMs: 250,
};

// The TUI's input parser (Ink, patched) turns a bracketed paste into one
// { isPasted: true } input event; the composer then inserts its payload. Chunks
// of more than 5 newlines or 500 chars are collapsed by the composer into a
// "[Pasted text #N +M lines]" placeholder, so we chunk below both thresholds to
// keep the transcript inline and editable.
const PASTE_START = "\u001b[200~";
const PASTE_END = "\u001b[201~";
const PASTE_MAX_LINES = 5;
const PASTE_MAX_CHARS = 500;
// SSH hygiene. NEVER StrictHostKeyChecking=no: accept-new trusts a host on
// first contact and still refuses a changed key.
const SSH_OPTS = [
  "-o",
  "BatchMode=yes",
  "-o",
  "StrictHostKeyChecking=accept-new",
  "-o",
  "ConnectTimeout=10",
  "-o",
  "ServerAliveInterval=15",
  "-o",
  "ServerAliveCountMax=4",
];

const SETUP_HINT =
  "set DICTATION_CMD (a shell command that runs your recorder) — see the dictation setup skill";

// ---------------------------------------------------------------------------
// configuration
// ---------------------------------------------------------------------------

/** ssh argv: options first, then host, then the remote command (last). */
function sshArgs(host, remoteCmd, key, port) {
  const args = [...SSH_OPTS];
  if (key) args.push("-i", key);
  if (port) args.push("-p", port);
  args.push(host, remoteCmd);
  return args;
}

/**
 * Resolve the recorder contract from the environment. Nothing here knows about
 * any particular machine: either the deployment hands us one shell command, or
 * it hands us an ssh target plus a remote command and we build the ssh call
 * with the hygiene flags baked in.
 */
function readConfig(env = process.env) {
  const val = (name) => String(env[name] || "").trim();

  const cmd = val("DICTATION_CMD");
  const stopCmd = val("DICTATION_STOP_CMD");
  const host = val("DICTATION_HOST");
  const remoteCmd = val("DICTATION_REMOTE_CMD");
  const remoteStopCmd = val("DICTATION_REMOTE_STOP_CMD");
  const key = val("DICTATION_SSH_KEY");
  const port = val("DICTATION_SSH_PORT");

  let listen = null;
  let stop = null;
  let display = null;

  if (cmd) {
    listen = { file: "/bin/sh", args: ["-c", cmd] };
    if (stopCmd) stop = { file: "/bin/sh", args: ["-c", stopCmd] };
    display = "DICTATION_CMD";
  } else if (host && remoteCmd) {
    listen = { file: "ssh", args: sshArgs(host, remoteCmd, key, port) };
    if (remoteStopCmd) stop = { file: "ssh", args: sshArgs(host, remoteStopCmd, key, port) };
    display = `ssh ${host}`;
  }

  // A hand-written command is the operator's own business — except for this:
  // StrictHostKeyChecking=no turns the mic link into a machine-in-the-middle
  // target. The ssh shape above bakes in accept-new; shape A is checked here.
  const unsafe = [cmd, stopCmd].find((value) =>
    /StrictHostKeyChecking\s*=\s*no/i.test(value || ""),
  );

  return {
    listen,
    stop,
    display,
    configured: Boolean(listen),
    hygiene: unsafe
      ? "DICTATION_CMD uses StrictHostKeyChecking=no. Use " +
        "StrictHostKeyChecking=accept-new (plus BatchMode=yes, ConnectTimeout, " +
        "ServerAliveInterval) — refusing to start a recorder that disables host " +
        "key verification."
      : null,
    composer: val("DICTATION_COMPOSER").toLowerCase() || "auto",
  };
}

// ---------------------------------------------------------------------------
// session (exactly one owner)
// ---------------------------------------------------------------------------

/**
 * One session at a time, for the lifetime of the process. `phase` is the only
 * thing that decides whether a command is allowed:
 *
 *   idle       nothing running; /listen allowed
 *   recording  recorder live; /listen refused, /done collects
 *   stopping   /done in flight; /listen refused
 *   ended      recorder died on its own with a transcript still uncollected;
 *              /listen refused until /done takes it (nothing is ever dropped)
 */
function newSession(config) {
  return {
    phase: "idle",
    config,
    child: null,
    stopChild: null,
    partial: "",
    segments: [],
    log: [],
    lastError: null,
    exited: null, // { code, signal }
    doneLine: false,
    delivered: false,
    panel: null,
    waiters: new Set(),
    queue: [],
    timers: new Set(),
  };
}

let session = null;

function note(s, message) {
  const text = String(message || "").trim();
  if (!text) return;
  s.log.push(text.slice(0, 300));
  while (s.log.length > 20) s.log.shift();
}

function emitEvent(s, evt) {
  if (s.waiters.size > 0) {
    const waiters = [...s.waiters];
    s.waiters.clear();
    for (const waiter of waiters) waiter(evt);
    return;
  }
  s.queue.push(evt);
}

/** Wait for the next recorder event (done / exit) or for `ms` to elapse. */
function waitEvent(s, ms) {
  if (s.queue.length > 0) return Promise.resolve(s.queue.shift());
  return new Promise((resolve) => {
    let settled = false;
    const waiter = (evt) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      s.timers.delete(timer);
      s.waiters.delete(waiter);
      resolve(evt);
    };
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      s.timers.delete(timer);
      s.waiters.delete(waiter);
      resolve({ kind: "timeout" });
    }, Math.max(0, ms));
    s.timers.add(timer);
    s.waiters.add(waiter);
  });
}

function clearTimers(s) {
  for (const timer of s.timers) clearTimeout(timer);
  s.timers.clear();
}

function isAlive(child) {
  return Boolean(child) && child.exitCode === null && child.signalCode === null;
}

/** SIGTERM, then SIGKILL, to the recorder's whole process group.
 *
 * The recorder is spawned detached so it leads its own group: a `sh -c "ssh …"`
 * pipeline must not survive as an orphaned ssh with the microphone still hot
 * just because we signalled the shell it was started from. */
function signalTree(child, signal) {
  if (!isAlive(child)) return;
  const pid = child.pid;
  try {
    if (typeof pid === "number") {
      process.kill(-pid, signal);
      return;
    }
  } catch {
    /* ESRCH, or no group: fall through to the direct child */
  }
  try {
    child.kill(signal);
  } catch {
    /* already gone */
  }
}

function terminate(s, child) {
  if (!isAlive(child)) return;
  signalTree(child, "SIGTERM");
  const timer = setTimeout(() => {
    if (!isAlive(child)) return;
    signalTree(child, "SIGKILL");
  }, timings.killGraceMs);
  s.timers.add(timer);
}

// A detached recorder outlives its parent by design, so make sure a crash or a
// normal exit of the CLI never leaves a microphone recording.
let exitHookInstalled = false;
function installExitHook() {
  if (exitHookInstalled) return;
  exitHookInstalled = true;
  process.once("exit", () => {
    if (!session) return;
    signalTree(session.child, "SIGKILL");
    signalTree(session.stopChild, "SIGKILL");
  });
}

// ---------------------------------------------------------------------------
// recorder output -> session
// ---------------------------------------------------------------------------

/**
 * One stdout line of the recorder protocol:
 *   { "type": "status",  "message": "..." }
 *   { "type": "partial", "text": "..." }   replaces the running partial
 *   { "type": "final",   "text": "..." }   appended to the transcript
 *   { "type": "done" }                     clean stop; last line
 *   { "type": "error",   "message": "..." } fatal
 * Anything that is not JSON is treated as a human-readable log line; unknown
 * JSON types are ignored so recorders can add fields without breaking us.
 */
function handleLine(s, rawLine) {
  const line = String(rawLine || "").trim();
  if (!line) return;

  let message;
  try {
    message = JSON.parse(line);
  } catch {
    note(s, line);
    refreshPanel(s);
    return;
  }
  if (!message || typeof message !== "object" || Array.isArray(message)) return;

  switch (message.type) {
    case "status":
      note(s, message.message);
      break;
    case "partial":
      s.partial = typeof message.text === "string" ? message.text : "";
      break;
    case "final": {
      const text = String(message.text || "").trim();
      if (text) s.segments.push(text);
      s.partial = "";
      break;
    }
    case "done":
      s.doneLine = true;
      note(s, "recorder reported done");
      emitEvent(s, { kind: "done" });
      break;
    case "error":
      s.lastError = String(message.message || "recorder error");
      note(s, `error: ${s.lastError}`);
      break;
    default:
      break;
  }

  refreshPanel(s);
}

/** The text the operator gets: every final, plus a trailing partial if the
 *  recorder never finalised it (better to hand over the words than lose them). */
function transcriptOf(s) {
  const parts = s.segments.slice();
  const partial = s.partial.trim();
  if (partial) parts.push(partial);
  return parts.join("\n").trim();
}

function startRecorder(s, spec) {
  installExitHook();
  const child = spawn(spec.file, spec.args, {
    stdio: ["pipe", "pipe", "pipe"],
    // Own process group so /done can stop the whole recorder pipeline (see
    // signalTree) instead of orphaning an ssh with the mic still open.
    detached: true,
  });
  s.child = child;

  // A recorder that dies before 'spawn' resolves must not throw asynchronously.
  child.on("error", (error) => {
    s.lastError = error && error.message ? error.message : String(error);
    note(s, `could not start the recorder: ${s.lastError}`);
    s.exited = { code: null, signal: null, failed: true };
    if (s.phase === "recording") s.phase = "ended";
    emitEvent(s, { kind: "exit", ...s.exited });
    refreshPanel(s);
  });

  child.stdin.on("error", () => {
    /* recorder already gone; /done reports it */
  });
  child.stderr.on("error", () => {
    /* ignore */
  });

  let buffer = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    let index;
    while ((index = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, index);
      buffer = buffer.slice(index + 1);
      handleLine(s, line);
    }
  });

  let stderrBuffer = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderrBuffer = (stderrBuffer + chunk).slice(-4000);
  });

  child.on("exit", (code, signal) => {
    if (buffer.trim()) handleLine(s, buffer);
    buffer = "";
    s.exited = { code, signal };
    if (s.phase === "recording") {
      // Died on its own: keep the transcript, say so, and leave it for /done.
      s.phase = "ended";
      const detail = stderrBuffer.trim();
      note(
        s,
        `recorder exited unexpectedly (${signal ? `signal ${signal}` : `code ${code}`})${
          detail ? `: ${detail.slice(-300)}` : ""
        }`,
      );
    }
    emitEvent(s, { kind: "exit", code, signal });
    refreshPanel(s);
  });

  s.phase = "recording";
}

// ---------------------------------------------------------------------------
// /done: stop, collect, place in the composer
// ---------------------------------------------------------------------------

function remaining(deadline) {
  return Math.max(0, deadline - Date.now());
}

/** Run the deployment's stop command; its exit status is NEVER swallowed. */
function runStopCommand(s, budgetMs) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(s.config.stop.file, s.config.stop.args, {
        stdio: ["ignore", "pipe", "pipe"],
        // Own process group: the timeout path must be able to kill the stop
        // command's children too (`pkill -f …` wrappers, ssh, …).
        detached: true,
      });
    } catch (error) {
      resolve({ ok: false, describe: "could not start", detail: String(error && error.message) });
      return;
    }
    s.stopChild = child;

    let stderr = "";
    let stdout = "";
    child.stdout.on("data", (chunk) => {
      stdout = (stdout + chunk).slice(-2000);
    });
    child.stderr.on("data", (chunk) => {
      stderr = (stderr + chunk).slice(-2000);
    });

    let settled = false;
    const finish = (payload) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      s.timers.delete(timer);
      s.stopChild = null;
      resolve(payload);
    };

    const timer = setTimeout(() => {
      if (isAlive(child)) {
        try {
          child.kill("SIGKILL");
        } catch {
          /* ignore */
        }
      }
      finish({
        ok: false,
        describe: `timed out after ${Math.round(budgetMs / 1000)}s`,
        detail: stderr.trim() || stdout.trim(),
      });
    }, Math.max(500, budgetMs));
    s.timers.add(timer);

    child.on("error", (error) =>
      finish({ ok: false, describe: "could not start", detail: String(error && error.message) }),
    );
    child.on("exit", (code, signal) => {
      const detail = stderr.trim() || stdout.trim();
      finish({
        ok: code === 0,
        describe: signal ? `killed by ${signal}` : `exit ${code}`,
        detail,
      });
    });
  });
}

/** Chunk text so the composer keeps it inline (see PASTE_MAX_* above). */
function chunkForPaste(text, maxLines = PASTE_MAX_LINES, maxChars = PASTE_MAX_CHARS) {
  const chunks = [];
  let current = "";
  let lines = 0;
  for (const char of Array.from(String(text || ""))) {
    if (current.length >= maxChars || (char === "\n" && lines >= maxLines)) {
      chunks.push(current);
      current = "";
      lines = 0;
    }
    current += char;
    if (char === "\n") lines += 1;
  }
  if (current) chunks.push(current);
  return chunks.length > 0 ? chunks : [""];
}

/**
 * Put text in the operator's input box, unsent and editable.
 *
 * The composer's value is React state inside the input component and no mod API
 * reaches it — but the TUI's input component reads its keys from `props.stdin`,
 * which is the process's stdin, and it understands bracketed paste. Pushing a
 * paste sequence onto that stream is therefore received exactly like a terminal
 * paste: the composer inserts the text and sends nothing. We only ever emit
 * paste bytes, never a newline/Enter key, so the agent cannot see the text
 * before the operator presses Enter themselves.
 *
 * Preconditions are checked rather than assumed: a TTY stdin that actually has
 * the TUI's "readable" input handler attached. Anything else degrades to
 * output-only (the desktop listener has no composer to fill).
 */
function deliverToComposer(text, input = process.stdin) {
  if (!input || typeof input.push !== "function" || typeof input.emit !== "function") {
    return { ok: false, reason: "stdin is not a readable stream" };
  }
  if (!input.isTTY) {
    return { ok: false, reason: "stdin is not a TTY, so there is no interactive composer" };
  }
  if (typeof input.listenerCount !== "function" || input.listenerCount("readable") === 0) {
    return { ok: false, reason: "the TUI is not reading stdin (no input handler attached)" };
  }

  const chunks = chunkForPaste(text);
  let index = 0;

  const step = () => {
    if (index >= chunks.length) return;
    const sequence = PASTE_START + chunks[index] + PASTE_END;
    index += 1;
    try {
      input.push(Buffer.from(sequence, "utf8"));
      // push() schedules a "readable" emit; emitting here as well makes
      // delivery synchronous when the stream is already flowing. A second
      // handler pass just reads null, which is a no-op.
      input.emit("readable");
    } catch (error) {
      return;
    }
    if (index < chunks.length) {
      const timer = setTimeout(step, timings.injectGapMs);
      if (typeof timer.unref === "function") timer.unref();
    }
  };

  step();
  return { ok: true, chunks: chunks.length };
}

// ---------------------------------------------------------------------------
// panel (live, incremental)
// ---------------------------------------------------------------------------

function panelLines(s, width) {
  const usable = Math.max(20, (width || 80) - 2);
  const label =
    s.phase === "recording"
      ? "🎙 listening"
      : s.phase === "stopping"
        ? "🎙 stopping"
        : s.phase === "ended"
          ? "🎙 ended"
          : "🎙 dictation";
  const chars = transcriptOf(s).length;
  const lines = [`${label} — ${s.segments.length} segment(s), ${chars} char(s) — /done to finish`];

  if (s.partial) {
    const tail = s.partial.split(/\r?\n/).pop() || "";
    lines.push(`… ${tail.length > usable ? tail.slice(-usable) : tail}`);
  }
  for (const entry of s.log.slice(-PANEL_LOG_LINES)) {
    lines.push(`  ${entry.length > usable ? entry.slice(0, usable) : entry}`);
  }
  return lines.slice(0, PANEL_MAX_LINES);
}

function refreshPanel(s) {
  if (!s || !s.panel) return;
  try {
    s.panel.update();
  } catch {
    /* stale handle after a reload; the next /listen reopens it */
  }
}

function openPanel(letta, s) {
  if (!letta.capabilities || !letta.capabilities.ui || !letta.capabilities.ui.panels) return;
  try {
    s.panel = letta.ui.openPanel({
      id: PANEL_ID,
      order: PANEL_ORDER,
      render: (ctx) => panelLines(s, ctx && ctx.width).join("\n"),
    });
  } catch {
    s.panel = null;
  }
}

function closePanel(s) {
  if (!s || !s.panel) return;
  try {
    s.panel.close();
  } catch {
    /* ignore */
  }
  s.panel = null;
}

// ---------------------------------------------------------------------------
// results
// ---------------------------------------------------------------------------

function output(text, success = true) {
  return { type: "output", output: text, success };
}

function describeTranscript(s, delivered, notes) {
  const text = transcriptOf(s);
  const lines = [];
  const hardFailure = notes.some((n) => n.fatal);

  if (!text) {
    lines.push("Nothing was captured. The recorder produced no speech.");
  } else if (delivered.ok) {
    lines.push("✓ inserted into your composer — edit it, then press Enter to send.");
  } else {
    lines.push(`Composer insertion unavailable (${delivered.reason}).`);
    lines.push("Transcript (copy or retype it):");
  }

  for (const entry of notes) lines.push(entry.text);

  if (text) {
    lines.push("");
    lines.push(text);
  }
  return { text: lines.join("\n"), success: !hardFailure };
}

// ---------------------------------------------------------------------------
// mod entry point
// ---------------------------------------------------------------------------

export default function activate(letta) {
  const disposers = [];
  const log = (message, level = "info") => {
    try {
      letta.diagnostics?.report?.({ message, level });
    } catch {
      /* diagnostics are best-effort */
    }
  };

  const hasCommands = Boolean(letta.capabilities && letta.capabilities.commands);
  const hasPanels = Boolean(letta.capabilities && letta.capabilities.ui && letta.capabilities.ui.panels);

  // ---- /listen ----------------------------------------------------------
  if (hasCommands) {
    disposers.push(
      letta.commands.register({
        id: "listen",
        description:
          "Start dictating from your microphone (local, or on another machine over SSH). The recorder runs for as long as you talk — there is no time limit. Finish with /done, which stops the recorder and puts the transcript in your composer, unsent.",
        // The agent may be mid-turn when the operator wants to start or stop
        // dictating; neither command needs the agent.
        runWhenBusy: true,
        showInTranscript: true,
        async run() {
          const config = readConfig();

          if (!config.configured) {
            return output(
              `Dictation is not configured: no recorder command is set. ${SETUP_HINT}.`,
              false,
            );
          }
          if (config.hygiene) {
            return output(config.hygiene, false);
          }
          if (session && (session.phase === "recording" || session.phase === "stopping")) {
            return output(
              `Already ${session.phase}. Stop this dictation with /done before starting another one.`,
              false,
            );
          }
          if (session && session.phase === "ended" && !session.delivered) {
            return output(
              "The previous dictation ended before its transcript was collected. Run /done to take it, then /listen again.",
              false,
            );
          }

          if (session) {
            closePanel(session);
            clearTimers(session);
          }

          const current = newSession(config);
          session = current;
          if (hasPanels) openPanel(letta, current);

          try {
            startRecorder(current, config.listen);
          } catch (error) {
            const detail = error && error.message ? error.message : String(error);
            session = null;
            closePanel(current);
            clearTimers(current);
            return output(`Could not start the recorder (${config.display}): ${detail}`, false);
          }

          // A dead-on-arrival recorder (missing ssh, unreadable key, command
          // not found) fails asynchronously. Wait one beat so /listen reports a
          // dead microphone instead of a cheerful "listening".
          await new Promise((resolve) => setTimeout(resolve, timings.listenGraceMs));
          if (current.phase === "ended" && !current.doneLine) {
            const captured = transcriptOf(current);
            if (!captured) {
              const detail =
                current.lastError ||
                current.log.slice(-2).join(" | ") ||
                "the recorder produced no output";
              session = null;
              closePanel(current);
              clearTimers(current);
              return output(
                `The recorder exited immediately (${config.display}): ${detail}`,
                false,
              );
            }
            return output(
              `The recorder exited immediately (${config.display}) but captured "${captured.slice(
                0,
                200,
              )}". Run /done to take the transcript.`,
            );
          }

          const stopHint = config.stop
            ? "the configured stop command"
            : "a `stop` line on the recorder's stdin";
          return output(
            `🎙 Listening via ${config.display}. Speak; run /done when you are finished.\n` +
              `No time limit. /done stops the recorder with ${stopHint} and waits for its own done line.`,
          );
        },
      }),
    );
  }

  // ---- /done ------------------------------------------------------------
  if (hasCommands) {
    disposers.push(
      letta.commands.register({
        id: "done",
        description:
          "Finish dictating: stop the microphone, wait for the recorder's own confirmation, and place the transcript in your composer unsent. Nothing is sent to the agent until you press Enter.",
        runWhenBusy: true,
        showInTranscript: true,
        async run() {
          const current = session;
          if (!current || current.phase === "idle" || current.phase === "stopping") {
            return output(
              current && current.phase === "stopping"
                ? "Dictation is already stopping."
                : "Nothing is recording. Start with /listen.",
              false,
            );
          }

          const deadline = Date.now() + timings.commandBudgetMs;
          current.phase = "stopping";
          refreshPanel(current);

          const notes = [];

          // 1. Stop the recorder. Deterministic, and a failure is reported.
          if (current.config.stop) {
            const result = await runStopCommand(
              current,
              Math.min(timings.stopCmdBudgetMs, Math.max(1000, remaining(deadline) - 5000)),
            );
            if (!result.ok) {
              notes.push({
                fatal: true,
                text: `⚠ stop command failed (${result.describe})${
                  result.detail ? `: ${result.detail}` : ""
                }`,
              });
            }
          } else if (current.child && current.child.stdin && current.child.stdin.writable) {
            try {
              current.child.stdin.write("stop\n");
              current.child.stdin.end();
            } catch (error) {
              notes.push({
                fatal: true,
                text: `⚠ could not signal the recorder to stop: ${
                  error && error.message ? error.message : String(error)
                }`,
              });
            }
          }

          // 2. Wait for the recorder's OWN done line — not for a fixed delay —
          //    so the last utterance is never truncated.
          const waitMs = Math.max(1000, Math.min(timings.doneWaitMs, remaining(deadline)));
          const first = await waitEvent(current, waitMs);

          if (first.kind === "timeout") {
            notes.push({
              fatal: true,
              text: `⚠ the recorder did not confirm shutdown within ${Math.round(
                waitMs / 1000,
              )}s and is being terminated — the last words may be missing.${
                current.lastError ? ` Last recorder error: ${current.lastError}` : ""
              }`,
            });
          } else if (first.kind === "exit" && !current.doneLine) {
            if (first.code !== 0) {
              notes.push({
                fatal: true,
                text: `⚠ the recorder exited without a done line (${first.signal ? `signal ${first.signal}` : `code ${first.code}`}).`,
              });
            } else {
              notes.push({
                fatal: false,
                text: "• the recorder exited without a done line (exit 0) — using what it captured.",
              });
            }
          } else if (first.kind === "done") {
            const grace = await waitEvent(
              current,
              Math.min(timings.exitGraceMs, Math.max(200, remaining(deadline))),
            );
            if (grace.kind === "timeout") {
              notes.push({
                fatal: false,
                text: "• recorder said done but stayed alive; terminated it.",
              });
            }
          }

          // 3. Never leave a hot mic: make sure the child is gone.
          terminate(current, current.child);
          if (isAlive(current.child)) await waitEvent(current, timings.killGraceMs);

          clearTimers(current);
          closePanel(current);

          // 4. Place the transcript in the composer (unsent) and show it.
          const transcript = transcriptOf(current);
          const mode = current.config.composer;
          let delivered = { ok: false, reason: "composer delivery is disabled" };
          if (transcript && mode !== "off" && mode !== "output") {
            delivered = deliverToComposer(transcript);
          }

          current.delivered = true;
          current.child = null;
          const summary = describeTranscript(current, delivered, notes);
          session = null;

          log(
            `dictation finished: ${current.segments.length} segment(s), ${transcript.length} char(s), composer=${
              delivered.ok ? "inserted" : "not inserted"
            }`,
          );
          return output(summary.text, summary.success);
        },
      }),
    );
  }

  // ---- turn hook --------------------------------------------------------
  // Purely observational: a recorder that dies while the agent is busy would
  // otherwise fail silently (the operator is watching the chat, not the panel).
  // It never cancels a turn and never rewrites its input.
  if (letta.capabilities && letta.capabilities.events && letta.capabilities.events.turns) {
    disposers.push(
      letta.events.on("turn_end", () => {
        if (!session || session.phase !== "ended" || session.delivered) return;
        try {
          letta.ui?.notify?.("Dictation stopped unexpectedly — run /done to keep the transcript.");
        } catch {
          /* ignore */
        }
      }),
    );
  }

  return () => {
    for (const dispose of disposers.reverse()) {
      try {
        dispose();
      } catch {
        /* ignore */
      }
    }
    if (session) {
      terminate(session, session.child);
      terminate(session, session.stopChild);
      clearTimers(session);
      closePanel(session);
      session = null;
    }
  };
}

export const __test = {
  activate,
  readConfig,
  sshArgs,
  chunkForPaste,
  deliverToComposer,
  transcriptOf,
  handleLine,
  newSession,
  panelLines,
  timings,
  setTimings(patch) {
    Object.assign(timings, patch || {});
  },
};
