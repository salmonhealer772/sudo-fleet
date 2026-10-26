// Self-test for @letta-ai/dictation.
//
//   node test/selftest.mjs
//
// Drives the REAL mod entry point (activate -> commands) against fake recorders.
// No letta process, no microphone, no network. Exits non-zero on the first
// failed assertion.

import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const mod = await import("../mods/index.mjs");
const activate = mod.default;
const { __test } = mod;

const results = [];
function check(name, fn) {
  return Promise.resolve()
    .then(fn)
    .then(() => {
      results.push({ name, ok: true });
      console.log(`  ok   ${name}`);
    })
    .catch((error) => {
      results.push({ name, ok: false, error });
      console.log(`  FAIL ${name}\n       ${error && error.message}`);
    });
}

// ---------------------------------------------------------------------------
// fake letta runtime
// ---------------------------------------------------------------------------

function fakeLetta({ panels = true } = {}) {
  const commands = new Map();
  const panelsOpened = [];
  const notifications = [];
  const events = new Map();
  const diagnostics = [];

  const letta = {
    capabilities: {
      tools: false,
      commands: true,
      events: { lifecycle: false, tools: false, turns: true, compact: false, llm: false },
      permissions: false,
      providers: false,
      ui: { panels },
    },
    commands: {
      register(command) {
        commands.set(command.id, command);
        return () => commands.delete(command.id);
      },
    },
    events: {
      on(name, handler) {
        if (!events.has(name)) events.set(name, []);
        events.get(name).push(handler);
        return () => {
          const list = events.get(name) || [];
          const index = list.indexOf(handler);
          if (index !== -1) list.splice(index, 1);
        };
      },
    },
    ui: {
      openPanel(options) {
        const handle = {
          id: options.id,
          renders: [],
          closed: false,
          update() {
            handle.renders.push(options.render({ width: 80, columns: 80 }));
          },
          close() {
            handle.closed = true;
          },
        };
        panelsOpened.push(handle);
        handle.update();
        return handle;
      },
      notify(message) {
        notifications.push(message);
      },
    },
    diagnostics: {
      report(entry) {
        diagnostics.push(entry);
      },
    },
  };

  return { letta, commands, panelsOpened, notifications, events, diagnostics };
}

function clearDictationEnv() {
  for (const key of Object.keys(process.env)) {
    if (key.startsWith("DICTATION_")) delete process.env[key];
  }
}

const recorderDirs = [];
process.on("exit", () => {
  for (const dir of recorderDirs) {
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch {
      /* best effort */
    }
  }
});

function recorderScript(body) {
  const dir = mkdtempSync(join(tmpdir(), "dictation-selftest-"));
  recorderDirs.push(dir);
  const path = join(dir, "recorder.sh");
  writeFileSync(path, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  return path;
}

const emit = (obj) => `printf '%s\\n' '${JSON.stringify(obj)}'`;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---------------------------------------------------------------------------
// 1. contract / configuration
// ---------------------------------------------------------------------------

await check("no configuration -> actionable message naming DICTATION_CMD", async () => {
  clearDictationEnv();
  const { letta, commands } = fakeLetta();
  activate(letta);
  const result = await commands.get("listen").run({});
  assert.equal(result.type, "output");
  assert.equal(result.success, false);
  assert.match(result.output, /DICTATION_CMD/);
  assert.match(result.output, /setup skill/);
});

await check("ssh form builds argv with accept-new and never StrictHostKeyChecking=no", () => {
  const args = __test.sshArgs("me@mic-host", "/opt/rec/run --json", "/k/id", "2222");
  const joined = args.join(" ");
  assert.match(joined, /StrictHostKeyChecking=accept-new/);
  assert.doesNotMatch(joined, /StrictHostKeyChecking=no/);
  assert.match(joined, /BatchMode=yes/);
  assert.match(joined, /ConnectTimeout=10/);
  assert.match(joined, /ServerAliveInterval=15/);
  assert.deepEqual(args.slice(-2), ["me@mic-host", "/opt/rec/run --json"]);
});

await check("DICTATION_CMD wins over the ssh form; stop command parsed", () => {
  process.env.DICTATION_CMD = "/opt/rec/run";
  process.env.DICTATION_STOP_CMD = "/opt/rec/stop";
  process.env.DICTATION_HOST = "ignored";
  process.env.DICTATION_REMOTE_CMD = "ignored";
  const config = __test.readConfig();
  assert.equal(config.configured, true);
  assert.deepEqual(config.listen, { file: "/bin/sh", args: ["-c", "/opt/rec/run"] });
  assert.deepEqual(config.stop, { file: "/bin/sh", args: ["-c", "/opt/rec/stop"] });
  clearDictationEnv();
});

// ---------------------------------------------------------------------------
// 2. the live session
// ---------------------------------------------------------------------------

await check("/listen starts a session, panel updates on every partial", async () => {
  clearDictationEnv();
  const recorder = recorderScript(`
${emit({ type: "status", message: "mic open" })}
${emit({ type: "partial", text: "hello and wel" })}
sleep 0.15
${emit({ type: "partial", text: "hello and welcome to the" })}
sleep 0.15
${emit({ type: "final", text: "hello and welcome to the show." })}
cat > /dev/null
${emit({ type: "done" })}
`);
  process.env.DICTATION_CMD = recorder;

  const { letta, commands, panelsOpened } = fakeLetta();
  activate(letta);

  const started = await commands.get("listen").run({});
  assert.equal(started.success, true);
  assert.match(started.output, /Listening via DICTATION_CMD/);
  assert.match(started.output, /No time limit/);
  assert.equal(panelsOpened.length, 1, "one panel opens");

  // A second /listen while recording is refused (no double spawn).
  const second = await commands.get("listen").run({});
  assert.equal(second.success, false);
  assert.match(second.output, /Already recording/);
  assert.equal(panelsOpened.length, 1, "still exactly one panel");

  await sleep(500);
  const panel = panelsOpened[0];
  const renders = panel.renders.join("\n");
  assert.match(renders, /listening/);
  assert.match(renders, /welcome to the/, "partials render as they arrive");
  assert.ok(panel.renders.length >= 4, "panel re-rendered per line, not on a timer");

  const done = await commands.get("done").run({});
  assert.equal(done.type, "output", "/done must never return type prompt");
  assert.match(done.output, /hello and welcome to the show\./);
  assert.equal(panel.closed, true, "panel closed on /done");
});

await check("no time limit: a long silent session is still recording afterwards", async () => {
  clearDictationEnv();
  // Speaks only after 1.3s. A ten-minute-style cap or any session timer would
  // have to be much larger than this; the point is that nothing truncates and
  // the late utterance still lands.
  const recorder = recorderScript(`
sleep 1.3
${emit({ type: "final", text: "late words still count" })}
cat > /dev/null
${emit({ type: "done" })}
`);
  process.env.DICTATION_CMD = recorder;
  const { letta, commands } = fakeLetta();
  activate(letta);

  await commands.get("listen").run({});
  await sleep(400);
  const midDone = await commands.get("done").run({});
  assert.match(midDone.output, /late words still count/, "the delayed utterance is captured");

  // And a session can run past a former 10-minute-style cap boundary in
  // principle: assert no session timer exists at all on a live session.
  const session = __test.newSession(__test.readConfig());
  assert.equal(session.phase, "idle");
  assert.equal(session.timers.size, 0);
});

await check("/done surfaces a failing stop command instead of swallowing it", async () => {
  clearDictationEnv();
  const recorder = recorderScript(`
${emit({ type: "final", text: "kept text" })}
cat > /dev/null
${emit({ type: "done" })}
`);
  process.env.DICTATION_CMD = recorder;
  process.env.DICTATION_STOP_CMD = "exit 3";
  const { letta, commands } = fakeLetta();
  activate(letta);

  await commands.get("listen").run({});
  await sleep(250);
  const done = await commands.get("done").run({});
  assert.match(done.output, /stop command failed \(exit 3\)/);
  assert.match(done.output, /kept text/, "transcript is still handed over");
  assert.equal(done.success, false, "a failed stop is not reported as success");
});

await check("stop via stdin: recorder that stops on the `stop` line and emits done", async () => {
  clearDictationEnv();
  const recorder = recorderScript(`
${emit({ type: "final", text: "first part" })}
while read -r line; do
  if [ "$line" = "stop" ]; then
    ${emit({ type: "final", text: "second part" })}
    ${emit({ type: "done" })}
    exit 0
  fi
done
`);
  process.env.DICTATION_CMD = recorder;
  const { letta, commands } = fakeLetta();
  activate(letta);

  await commands.get("listen").run({});
  await sleep(250);
  const done = await commands.get("done").run({});
  assert.match(done.output, /first part/);
  assert.match(done.output, /second part/, "the final utterance is not truncated");
  assert.equal(done.success, true);
});

await check("recorder that never confirms: says so plainly, kills it, keeps text", async () => {
  clearDictationEnv();
  const recorder = recorderScript(`
trap '' TERM
${emit({ type: "final", text: "captured before the freeze" })}
while true; do sleep 1; done
`);
  process.env.DICTATION_CMD = recorder;
  __test.setTimings({ doneWaitMs: 1200, exitGraceMs: 300, killGraceMs: 300 });

  const { letta, commands } = fakeLetta();
  activate(letta);

  await commands.get("listen").run({});
  await sleep(250);
  const done = await commands.get("done").run({});
  assert.match(done.output, /did not confirm shutdown/);
  assert.match(done.output, /last words may be missing/);
  assert.match(done.output, /captured before the freeze/);
  assert.equal(done.success, false);
  __test.setTimings({ doneWaitMs: 20000, exitGraceMs: 2000, killGraceMs: 1500 });
});

await check("recorder dying on its own keeps the transcript and blocks a new session", async () => {
  clearDictationEnv();
  const recorder = recorderScript(`
${emit({ type: "final", text: "orphaned words" })}
exit 7
`);
  process.env.DICTATION_CMD = recorder;
  const { letta, commands } = fakeLetta();
  activate(letta);

  await commands.get("listen").run({});
  await sleep(400);

  const relisten = await commands.get("listen").run({});
  assert.equal(relisten.success, false);
  assert.match(relisten.output, /Run \/done to take it/);

  const done = await commands.get("done").run({});
  assert.match(done.output, /orphaned words/);
  assert.match(done.output, /exited without a done line \(code 7\)|exited without a done line/);

  // After /done the state is clean again: /listen is allowed.
  const again = await commands.get("listen").run({});
  assert.equal(again.success, true, "a /listen after a failed /done is allowed");
  await commands.get("done").run({});
});

await check("DICTATION_CMD with StrictHostKeyChecking=no is refused, not run", async () => {
  clearDictationEnv();
  process.env.DICTATION_CMD =
    "ssh -o StrictHostKeyChecking=no mic-host /opt/rec/run --json";
  const { letta, commands, panelsOpened } = fakeLetta();
  activate(letta);
  const result = await commands.get("listen").run({});
  assert.equal(result.success, false);
  assert.match(result.output, /StrictHostKeyChecking=no/);
  assert.match(result.output, /accept-new/);
  assert.equal(panelsOpened.length, 0, "no session, no panel");
  clearDictationEnv();
});

await check("a recorder that cannot start is reported, not a fake 'listening'", async () => {
  clearDictationEnv();
  process.env.DICTATION_CMD = "/nonexistent/dictation-recorder --json";
  const { letta, commands, panelsOpened } = fakeLetta();
  activate(letta);
  const result = await commands.get("listen").run({});
  assert.equal(result.success, false);
  assert.match(result.output, /exited immediately/);
  assert.match(result.output, /nonexistent|not found|No such file/i);
  assert.equal(panelsOpened.at(-1).closed, true, "the panel is cleaned up");
  // The failed start left no session behind: /listen is allowed again.
  process.env.DICTATION_CMD = "cat > /dev/null";
  const retry = await commands.get("listen").run({});
  assert.equal(retry.success, true);
  await commands.get("done").run({});
  clearDictationEnv();
});

await check("/listen with a recorder that dies after speaking still yields the text", async () => {
  clearDictationEnv();
  const recorder = recorderScript(`
${emit({ type: "final", text: "spoken then gone" })}
exit 0
`);
  process.env.DICTATION_CMD = recorder;
  const { letta, commands } = fakeLetta();
  activate(letta);
  const started = await commands.get("listen").run({});
  assert.equal(started.success, true);
  assert.match(started.output, /spoken then gone/);
  const done = await commands.get("done").run({});
  assert.match(done.output, /spoken then gone/);
});

await check("/done with nothing recording is refused", async () => {
  clearDictationEnv();
  process.env.DICTATION_CMD = "/bin/true";
  const { letta, commands } = fakeLetta();
  activate(letta);
  const result = await commands.get("done").run({});
  assert.equal(result.success, false);
  assert.match(result.output, /Nothing is recording/);
});

await check("disposer kills a live recorder, closes the panel, and unregisters cleanly", async () => {
  clearDictationEnv();
  const recorder = recorderScript(`${emit({ type: "final", text: "x" })}\nsleep 30\n`);
  process.env.DICTATION_CMD = recorder;
  const first = fakeLetta();
  const dispose = activate(first.letta);

  await first.commands.get("listen").run({});
  await sleep(150);
  dispose();
  assert.equal(first.panelsOpened[0].closed, true);
  assert.equal(first.commands.size, 0, "commands unregistered");

  // A fresh activation (what a mod reload does) must not see a ghost session.
  const second = fakeLetta();
  const dispose2 = activate(second.letta);
  const again = await second.commands.get("listen").run({});
  assert.equal(again.success, true, "no session survived the reload");
  await sleep(150);
  dispose2();
  assert.equal(second.panelsOpened.at(-1).closed, true, "disposing a live session closes its panel");
});

// ---------------------------------------------------------------------------
// 3. composer delivery
// ---------------------------------------------------------------------------

await check("composer delivery writes exactly one bracketed paste, no Enter", async () => {
  const stream = new PassThrough();
  stream.isTTY = true;
  const seen = [];
  stream.on("readable", () => {
    let chunk;
    while ((chunk = stream.read()) !== null) seen.push(chunk.toString("utf8"));
  });

  const result = __test.deliverToComposer("hello world", stream);
  assert.equal(result.ok, true);
  assert.deepEqual(seen, ["\u001b[200~hello world\u001b[201~"]);
  assert.doesNotMatch(seen.join(""), /[\r\n]/, "no newline is ever written");
});

await check("long transcripts are chunked below the composer's placeholder limits", async () => {
  const stream = new PassThrough();
  stream.isTTY = true;
  const seen = [];
  stream.on("readable", () => {
    let chunk;
    while ((chunk = stream.read()) !== null) seen.push(chunk.toString("utf8"));
  });

  const text = Array.from({ length: 12 }, (_, i) => `line ${i} of a long dictation`).join("\n");
  __test.setTimings({ injectGapMs: 1 });
  const result = __test.deliverToComposer(text, stream);
  await sleep(result.chunks * 10 + 50);
  __test.setTimings({ injectGapMs: 60 });
  assert.equal(result.ok, true);
  assert.ok(result.chunks > 1, "split into several pastes");

  const payloads = seen.map((seq) => {
    assert.ok(seq.startsWith("\u001b[200~"), "starts a paste");
    assert.ok(seq.endsWith("\u001b[201~"), "ends a paste");
    return seq.slice(6, -6);
  });
  assert.equal(payloads.join(""), text, "content preserved exactly, in order");
  for (const payload of payloads) {
    const newlines = (payload.match(/\n/g) || []).length;
    assert.ok(newlines <= 5, `chunk has ${newlines} newlines (max 5)`);
    assert.ok(payload.length <= 500, `chunk is ${payload.length} chars (max 500)`);
  }
});

await check("no TUI attached -> delivery declines instead of pretending", async () => {
  const stream = new PassThrough();
  stream.isTTY = false;
  const result = __test.deliverToComposer("text", stream);
  assert.equal(result.ok, false);
  assert.match(result.reason, /not a TTY/);

  const ttyWithoutReader = new PassThrough();
  ttyWithoutReader.isTTY = true;
  const second = __test.deliverToComposer("text", ttyWithoutReader);
  assert.equal(second.ok, false);
  assert.match(second.reason, /not reading stdin/);
});

await check("chunkForPaste never exceeds the thresholds on ragged input", () => {
  const cases = [
    "",
    "short",
    "a".repeat(1200),
    Array.from({ length: 40 }, () => "x".repeat(100)).join("\n"),
    "line1\r\nline2\r\nline3",
  ];
  for (const text of cases) {
    const chunks = __test.chunkForPaste(text);
    assert.equal(chunks.join(""), text, "round-trips");
    for (const chunk of chunks) {
      assert.ok(chunk.length <= 500);
      assert.ok((chunk.match(/\n/g) || []).length <= 5);
    }
  }
});

// ---------------------------------------------------------------------------

const failed = results.filter((entry) => !entry.ok);
console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
if (failed.length > 0) {
  console.log("FAILED:");
  for (const entry of failed) console.log(`  - ${entry.name}: ${entry.error && entry.error.message}`);
  process.exit(1);
}
process.exit(0);
