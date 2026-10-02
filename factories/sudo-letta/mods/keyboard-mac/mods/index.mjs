// @letta-ai/keyboard-mac
//
// Registers ONE agent-callable tool: `keyboard_mode`.
//
// It switches the operator's Mac keyboard between PC mode (Ctrl/Alt act as
// Command, so Ctrl+C / Ctrl+V / Alt+Tab work) and native Mac mode, scoped to
// his EXTERNAL keyboard only (the built-in keyboard is never touched). It does
// this by running the repo's factories/mac/keyboard-mode.sh script on the lima
// host over the docker-socket + nsenter host bridge:
//
//   docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest \
//     nsenter -t 1 -m -u -i -n -p -- \
//     bash /opt/0-0/sudo-fleet/factories/mac/keyboard-mode.sh --<mode>
//
// No skill gate: the tool just works in one call. `mode` is "pc" | "mac" |
// "status" (status is read-only and reports the current mode + mappings).

import { spawn } from "node:child_process";

// The keyboard-mode script on the lima host (reached via the host bridge).
const SCRIPT_PATH = "/opt/0-0/sudo-fleet/factories/mac/keyboard-mode.sh";

// How long the host bridge is allowed to take before we give up. The script
// ships helpers to the Mac over scp and applies via hidutil/launchd, which is
// fast, but leave headroom.
const BRIDGE_TIMEOUT_MS = 90000;

/** Build the host-bridge argv for one mode ("pc" | "mac" | "status"). */
function bridgeArgs(mode) {
  return [
    "docker", "run", "--rm", "--privileged", "--pid=host", "--net=host",
    "-v", "/:/host", "alpine:latest",
    "nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--",
    "bash", SCRIPT_PATH, "--" + mode,
  ];
}

/**
 * Run the host bridge once; always resolves, never throws. Returns
 * { ok, code, stdout, stderr, error }.
 */
function runBridge(mode, timeoutMs = BRIDGE_TIMEOUT_MS) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn("docker", bridgeArgs(mode).slice(1), {
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      resolve({
        ok: false,
        error: error && error.message ? error.message : String(error),
        stdout: "",
        stderr: "",
      });
      return;
    }

    let stdout = "";
    let stderr = "";
    let settled = false;

    const finish = (payload) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(payload);
    };

    const timer = setTimeout(() => {
      try {
        child.kill("SIGKILL");
      } catch {
        /* ignore */
      }
      finish({
        ok: false,
        error: `host bridge timed out after ${timeoutMs}ms`,
        stdout,
        stderr,
      });
    }, timeoutMs);

    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      finish({
        ok: false,
        error: error && error.message ? error.message : String(error),
        stdout,
        stderr,
      });
    });
    child.on("close", (code) => {
      finish({ ok: code === 0, code, stdout, stderr });
    });
  });
}

export default function activate(letta) {
  if (!letta.capabilities.tools) return;

  const disposers = [];

  disposers.push(
    letta.tools.register({
      name: "keyboard_mode",
      description:
        "Switch the operator's Mac keyboard between PC mode (Ctrl/Alt act as Command so Ctrl+C, Ctrl+V, Alt+Tab work) and native Mac mode. Scoped to his external keyboard; the built-in keyboard is unaffected. " +
        "mode='pc' enables PC muscle-memory (Ctrl/Alt/Win act as Command); mode='mac' restores native Mac behaviour; mode='status' reports the current mode and mappings (read-only).",
      parameters: {
        type: "object",
        properties: {
          mode: {
            type: "string",
            enum: ["pc", "mac", "status"],
            description:
              "'pc' = PC mode (Ctrl/Alt act as Command, persisted); 'mac' = native Mac mode (no remap, persisted); 'status' = report the current mode and mappings.",
          },
        },
        required: ["mode"],
        additionalProperties: false,
      },
      requiresApproval: false,
      parallelSafe: true,
      async run(ctx) {
        const args = (ctx && ctx.args) || {};
        const mode = args.mode;
        if (!mode) {
          return "keyboard_mode requires `mode` (pc | mac | status).";
        }

        const bridge = await runBridge(mode);
        const out = (bridge.stdout || "").trim();
        if (bridge.ok) {
          return out || "keyboard_mode: done (no output).";
        }

        const detail = (bridge.stderr || bridge.error || "").trim();
        return out
          ? `${out}\nkeyboard_mode failed: ${detail}`
          : `keyboard_mode failed: ${detail || "unknown error"}`;
      },
    }),
  );

  return () => disposers.reverse().forEach((dispose) => dispose());
}

export const __test = { SCRIPT_PATH, bridgeArgs, runBridge };
