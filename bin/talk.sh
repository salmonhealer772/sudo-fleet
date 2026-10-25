#!/usr/bin/env bash
set -euo pipefail

# bin/talk.sh — Talk to any sudo agent (sudo-agent/hermes OR sudo-letta)
# v3 of talk-ALL.sh: v2's letta input fixes + question menus take typing
# without first arrowing down to "Type something."
# Usage: sudo bash bin/talk.sh --name
#
# Routes on the deployment's container: `sudo-agent` -> hermes, `sudo-letta`
# -> letta. Same flag handling as the per-factory talk.sh scripts.
#
# Why not plain `kubectl exec -it`? Every keystroke and every screen redraw is
# proxied through the API server stream: typing lags, escape sequences (arrow
# keys, Delete) get split or dropped, the TUI starts at 0x0 / 80 cols before
# the first resize lands, and the session gets TERM=xterm + the POSIX locale.
# Instead, when run as root on the node, we nsenter straight into the
# container's namespaces with YOUR terminal attached — the TUI talks to the
# real tty, so keys, resize and rendering behave like a local program.
# If that path is unavailable (not root, pod on another node), we fall back
# to kubectl exec with the size/TERM/locale fixed up.

NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name|--*)  NAME="${1#--}"; shift ;;
    *)           echo "Usage: bash bin/talk.sh --name" >&2; exit 1 ;;
  esac
done
if [[ -z "$NAME" ]]; then
  echo "Usage: bash bin/talk.sh --name" >&2
  echo "Example: bash bin/talk.sh --alice" >&2
  exit 1
fi
if [[ "${NAME,,}" == "all" ]]; then
  echo "Use rm-containers.sh --ALL instead." >&2; exit 1
fi

if [[ ! -t 0 || ! -t 1 ]]; then
  echo "talk.sh needs an interactive terminal." >&2; exit 1
fi

# Auto-detect kubeconfig (sudo changes $HOME, so kubectl loses ~/.kube/config)
if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in "/etc/rancher/k3s/k3s.yaml" "${SUDO_USER:+/home/$SUDO_USER/.kube/config}" "$HOME/.kube/config"; do
    if [[ -n "$cfg" && -r "$cfg" ]]; then export KUBECONFIG="$cfg"; break; fi
  done
fi

# --- Find the deployment (any namespace) and work out which agent type it is
DEPLOY="sudo-$NAME"
DJSON="$(kubectl get deploy --all-namespaces -o json \
  | jq -c --arg n "$DEPLOY" '[.items[] | select(.metadata.name == $n)][0] // empty')"
if [[ -z "$DJSON" ]]; then
  echo "No deployment named $DEPLOY. Agents:" >&2
  kubectl get deploy --all-namespaces -o json \
    | jq -r '.items[] | select(.spec.template.spec.containers | map(.name) | index("sudo-agent") or index("sudo-letta")) | "  --" + (.metadata.name | sub("^sudo-"; ""))' >&2
  exit 1
fi
NS="$(jq -r '.metadata.namespace' <<<"$DJSON")"
CONTAINERS="$(jq -r '.spec.template.spec.containers[].name' <<<"$DJSON")"
if grep -qx 'sudo-agent' <<<"$CONTAINERS"; then
  KIND="hermes"; CONTAINER="sudo-agent"; CMD=(hermes); EXTRA_ENV=()
elif grep -qx 'sudo-letta' <<<"$CONTAINERS"; then
  KIND="letta"; CONTAINER="sudo-letta"
  # --new: fresh conversation each launch; works around the letta-code <=0.33.2
  # double-mod-engine bug on the resume path (see sudo-letta/bin/talk.sh).
  # Use /resume inside the session to continue an older chat.
  CMD=(letta --new)
  # letta-code's TUI (Ink + React) has input bugs that make typing drop or
  # scramble characters. A preload fixes them at load time — no image change;
  # it removes itself from the env so letta's child processes never see it.
  #  1. Stale state: every input handler (prompt, question menu, approval
  #     prompts) computes from the value/cursor of the LAST render. Two keys
  #     that land before React re-renders → the second overwrites the first
  #     (dropped chars, Backspace deleting the wrong thing, Enter submitting
  #     text missing its last letters). Fix: hand Ink exactly ONE key per
  #     event-loop turn, so React always renders in between (~1ms per key).
  #  2. Ink treats each stdin read as ONE keypress, so "Left Left Left" or
  #     "\x7f\x7f" in one read collapse or vanish, and the menus' text field
  #     only accepts input.length === 1, so "ab" arriving together (normal
  #     for fast typing over ssh) is silently dropped. Fix: split every read
  #     into keys, and short typed runs into single characters. Bracketed
  #     pastes and long unbracketed pastes stay whole.
  #  3. After Home / Ctrl-A / Ctrl-E / Alt-B / history, TextInput re-applies
  #     the forced cursor position on EVERY render until it clears, so the
  #     next arrow/Backspace snaps back. A loader hook narrows that effect to
  #     fire only when the forced offset changes, and lets the menu text field
  #     accept multi-char input. Exact-string patches: on another letta
  #     version they're no-ops.
  # LETTA_DISABLE_KITTY: letta turns on the kitty keyboard protocol on every
  # terminal ("best-effort"), so on Ghostty/kitty/WezTerm/iTerm2 keys arrive
  # in a second encoding with its own handling. Keep the one legacy path.
  KEYSPLIT_JS="$(cat <<'JS'
import { register } from "node:module";
if (process.stdin.isTTY && /letta(\.js)?$/.test(process.argv[1] || "")) {
  delete process.env.NODE_OPTIONS;

  // ---- source patches for letta.js (exact strings; no-op if absent) ----
  // Menu / approval text fields: Home, End, forward Delete, Ctrl-A/E/U/W and
  // Alt-Backspace, and Left/Right/Backspace/Delete that step over a whole
  // emoji instead of splitting it. Ink's key object can't tell Home/End/
  // Delete apart, so read the raw key the splitter below is delivering now.
  const MENU_KEYS = String.raw`    {
      const raw = globalThis.__talkKey;
      const pair = (i) => i >= 0 && i + 1 < text2.length &&
        /[\ud800-\udbff]/.test(text2[i]) && /[\udc00-\udfff]/.test(text2[i + 1]);
      const back = pair(cursorPos - 2) ? 2 : 1, fwd = pair(cursorPos) ? 2 : 1;
      if (key2.leftArrow && !key2.meta) {
        setCursorPos(Math.max(0, cursorPos - back));
        return true;
      }
      if (key2.rightArrow && !key2.meta) {
        setCursorPos(Math.min(text2.length, cursorPos + fwd));
        return true;
      }
      if (raw === "\x7f" || raw === "\b") {
        if (cursorPos > 0) {
          setText((prev) => prev.slice(0, cursorPos - back) + prev.slice(cursorPos));
          setCursorPos(cursorPos - back);
        }
        return true;
      }
      if (raw === "\x1b[H" || raw === "\x1b[1~" || raw === "\x1bOH" || raw === "\x1b[7~" || (key2.ctrl && input === "a")) {
        setCursorPos(0);
        return true;
      }
      if (raw === "\x1b[F" || raw === "\x1b[4~" || raw === "\x1bOF" || raw === "\x1b[8~" || (key2.ctrl && input === "e")) {
        setCursorPos(text2.length);
        return true;
      }
      if (raw === "\x1b[3~") {
        setText((prev) => prev.slice(0, cursorPos) + prev.slice(cursorPos + fwd));
        return true;
      }
      if (key2.ctrl && input === "u") {
        setText((prev) => prev.slice(cursorPos));
        setCursorPos(0);
        return true;
      }
      if ((key2.ctrl && input === "w") || raw === "\x17" || raw === "\x1b\x7f" || raw === "\x1b\b") {
        const left = text2.slice(0, cursorPos).replace(/\S*\s*$/, "");
        setText((prev) => left + prev.slice(cursorPos));
        setCursorPos(left.length);
        return true;
      }
    }
`;
  const QUESTION_ANCHOR =
    "        setSelectedOption((prev) => Math.min(optionsWithOther.length - 1, prev + 1));\n        return;\n      }\n      if (isOnCustomOption) {\n";
  const QUESTION_JUMP = String.raw`      if (!isOnCustomOption && showOther && input && !key2.ctrl && !key2.meta && !key2.return && !key2.escape && !key2.tab && input !== " " && !/[\x00-\x1f\x7f]/.test(input)) {
        const n = /^[1-9]$/.test(input) ? Number(input) - 1 : -1;
        if (!(n >= 0 && n < optionsWithOther.length && n !== customOptionIndex && n !== submitOptionIndex)) {
          setSelectedOption(customOptionIndex);
          if (currentQuestion.multiSelect) setSelectedMulti((prev) => new Set(prev).add(customOptionIndex));
          handleKey(input, key2);
          return;
        }
      }
`;
  const PATCHES = [
    // TextInput re-applied a forced cursor position on every render.
    ["}, [externalCursorOffset, originalValue, onCursorOffsetChange]);",
     "}, [externalCursorOffset]);"],
    // Menu text field accepted only input.length === 1.
    ["if (input && !key2.ctrl && !key2.meta && input.length === 1) {\n      setText((prev) => prev.slice(0, cursorPos) + input + prev.slice(cursorPos));\n      setCursorPos((prev) => prev + 1);",
     String.raw`if (input && !key2.ctrl && !key2.meta && !/[\x00-\x1f\x7f]/.test(input)) {` +
       "\n      setText((prev) => prev.slice(0, cursorPos) + input + prev.slice(cursorPos));\n      setCursorPos((prev) => prev + input.length);"],
    ["const handleKey = (input, key2) => {\n    if (key2.leftArrow) {",
     "const handleKey = (input, key2) => {\n" + MENU_KEYS + "    if (key2.leftArrow) {"],
    // Question menus ignored typing unless "Type something." was highlighted,
    // so answers typed while an option was highlighted vanished. Printable
    // keys now jump into the field. Option-number digits and Space (multi-
    // select toggle) keep their meaning.
    [QUESTION_ANCHOR, QUESTION_ANCHOR.replace("      if (isOnCustomOption) {\n", QUESTION_JUMP + "      if (isOnCustomOption) {\n")],
  ];
  const HOOK = `
    let patches = [];
    export function initialize(data) { patches = data; }
    export async function load(url, context, nextLoad) {
      const result = await nextLoad(url, context);
      if (url.endsWith("/letta.js") && result.source != null) {
        let src = String(result.source);
        for (const [from, to] of patches) src = src.replace(from, () => to);
        result.source = src;
      }
      return result;
    }`;
  register("data:text/javascript," + encodeURIComponent(HOOK), { data: PATCHES });

  // ---- input pacing: one key per event-loop turn ----
  const TOKEN =
    /\x1b\[200~[\s\S]*?\x1b\[201~|\x1b+(?:\[[0-?]*[ -\/]*[@-~]|O[@-~]|[^\x1b])?|[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]|[^\x00-\x08\x0b\x0c\x0e-\x1f\x7f\x1b]+/g;
  const TYPED_RUN_MAX = 32; // longer plain runs are pastes: keep them whole
  const splitKeys = (text) =>
    (text.match(TOKEN) || [text]).flatMap((t) =>
      t.length < TYPED_RUN_MAX && !t.startsWith("\x1b") ? Array.from(t) : [t]);
  const stdin = process.stdin;
  const read = stdin.read.bind(stdin);
  const queue = [];
  let paced = false, timer = null;
  const resume = () => {
    timer ??= setTimeout(() => { timer = null; paced = false; stdin.emit("readable"); }, 0);
  };
  stdin.read = (...args) => {
    if (args.length) return read(...args);
    if (paced) { resume(); return null; } // one key per turn; Ink re-reads on "readable"
    if (!queue.length) {
      const chunk = read();
      if (chunk === null) return null;
      queue.push(...splitKeys(typeof chunk === "string" ? chunk : chunk.toString("utf8")));
    }
    paced = true; resume();
    return (globalThis.__talkKey = queue.shift());
  };
}
JS
)"
  EXTRA_ENV=(LETTA_DISABLE_KITTY=1 NODE_OPTIONS="--import=data:text/javascript;base64,$(base64 -w0 <<<"$KEYSPLIT_JS")")
else
  echo "$DEPLOY is not a sudo-agent or sudo-letta deployment (containers: $(tr '\n' ' ' <<<"$CONTAINERS"))." >&2
  exit 1
fi

# --- Pick a live pod (Running, not terminating) and its container ID
SEL="$(jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")' <<<"$DJSON")"
read -r POD CID < <(kubectl -n "$NS" get pod -l "$SEL" -o json | jq -r --arg c "$CONTAINER" '
  [.items[] | select(.status.phase == "Running" and .metadata.deletionTimestamp == null)
            | {pod: .metadata.name, st: (.status.containerStatuses[] | select(.name == $c))}
            | select(.st.ready)][0]
  // empty | "\(.pod) \(.st.containerID | sub("^.*://"; ""))"') || true
if [[ -z "${POD:-}" ]]; then
  if [[ "$(jq -r '.spec.replicas // 1' <<<"$DJSON")" == 0 ]]; then
    echo "$DEPLOY is scaled to 0. Start it with: kubectl -n $NS scale deploy/$DEPLOY --replicas=1" >&2
    exit 1
  fi
  echo "$DEPLOY has no ready pod right now:" >&2
  kubectl -n "$NS" get pod -l "$SEL" >&2
  exit 1
fi

# --- Terminal hygiene: whatever the TUI does, leave the terminal usable after.
SAVED_STTY="$(stty -g)"
restore_tty() {
  stty "$SAVED_STTY" 2>/dev/null || stty sane 2>/dev/null || true
  # leave alt screen, show cursor, disable mouse tracking / bracketed paste /
  # app-cursor + keypad modes a crashed TUI may have left on
  printf '\e[?1049l\e[?25h\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?2004l\e[?1l\e>' 2>/dev/null || true
}
trap restore_tty EXIT
# Correct erase key (fixes "delete half working") before handing the tty over.
stty sane erase '^?' 2>/dev/null || true

TERM_IN="${TERM:-xterm-256color}"
case "$TERM_IN" in xterm*|screen*|tmux*) ;; *) TERM_IN="xterm-256color" ;; esac
LOCALE_ENV=(LANG=C.UTF-8 LC_ALL=C.UTF-8)

echo "-> $KIND agent $DEPLOY (pod $POD, ns $NS)" >&2

# --- Fast path: nsenter into the container (needs root on the pod's node)
PID=""
if [[ $EUID -eq 0 ]] && command -v nsenter >/dev/null; then
  PID="$( { k3s crictl inspect "$CID" 2>/dev/null || crictl inspect "$CID" 2>/dev/null; } | jq -r '.info.pid // empty' 2>/dev/null || true)"
fi
if [[ -n "$PID" && -r "/proc/$PID/environ" ]]; then
  # Run as the same user the container's main process runs as (letta: node;
  # hermes: root, whose `hermes` shim then drops to the hermes user itself).
  read -r _ RUID _ < <(grep '^Uid:' "/proc/$PID/status")
  read -r _ RGID _ < <(grep '^Gid:' "/proc/$PID/status")
  GROUPS_CSV="$(grep '^Groups:' "/proc/$PID/status" | cut -f2 | xargs | tr ' ' ',')"
  CROOT="/proc/$PID/root"
  CHOME="$(awk -F: -v u="$RUID" '$3 == u {print $6; exit}' "$CROOT/etc/passwd" 2>/dev/null || true)"
  CHOME="${CHOME:-/root}"
  if [[ -n "$GROUPS_CSV" ]]; then GRP=(--groups="$GROUPS_CSV"); else GRP=(--clear-groups); fi
  mapfile -d '' CENV < "/proc/$PID/environ"

  set +e
  nsenter --target "$PID" --mount --uts --ipc --net --pid --cgroup \
          --root --wd -- \
    setpriv --reuid="$RUID" --regid="$RGID" \
            "${GRP[@]}" -- \
    env -i "${CENV[@]}" HOME="$CHOME" TERM="$TERM_IN" COLORTERM=truecolor "${LOCALE_ENV[@]}" "${EXTRA_ENV[@]}" \
    "${CMD[@]}"
  rc=$?
  set -e
  exit $rc
fi

# --- Fallback: kubectl exec, with the known breakages patched over
echo "(nsenter unavailable — using kubectl exec; run with sudo on the node for the smooth path)" >&2
read -r ROWS COLS < <(stty size)
kubectl -n "$NS" exec -it "$POD" -c "$CONTAINER" -- \
  env TERM="$TERM_IN" COLORTERM=truecolor "${LOCALE_ENV[@]}" "${EXTRA_ENV[@]}" \
  sh -c 'stty rows "$1" cols "$2" erase "^?" 2>/dev/null; shift 2; exec "$@"' sh "$ROWS" "$COLS" "${CMD[@]}"
