#!/usr/bin/env bash
# stream.sh — the operator's daily driver: the WHOLE agent, live, at full fidelity.
#
# Usage:
#   bash bin/stream.sh --<name>             RICH (default): merge-tail the
#                                                    agent's message store across ALL
#                                                    conversations, full fidelity
#   bash bin/stream.sh <name>               same, bare spelling
#   bash bin/stream.sh --<name> --raw       the events.jsonl tape (the
#                                                    sidecar's normalized events)
#   bash bin/stream.sh --<name> -t          transcript mode: the plain-text
#                                                    chat log (transcript.txt), live
#   bash bin/stream.sh --<name> --truncate N  cap each rendered line to N
#                                                    chars (opt-in; default OFF)
#   bash bin/stream.sh --<name> --no-color  plain output (also auto-off when
#                                                    stdout is not a TTY)
#   bash bin/stream.sh --list               list running sudo-letta agents
#   bash bin/stream.sh --help               this text
#
# WHAT RICH MODE SHOWS (everything Letta persists, full fidelity):
#   [HH:MM:SS] USER: <full text>             (SYS> prefix kept for reminder msgs)
#   [HH:MM:SS] ASSISTANT: <full text>
#                   └ provider/model · stop=<reason> · N out · N in · $cost
#   [HH:MM:SS] TOOL <name>: <FULL JSON args>
#   [HH:MM:SS] RESULT <name>: <FULL body, multi-line preserved verbatim>
#   [HH:MM:SS] PROC: <state> pids=N          (liveness beat: the one honest signal)
#   [HH:MM:SS] SESSION: <conversation id>
#
# RICH MODE SOURCE
#   A tiny stdlib-only tap (rich_tap.py) runs INSIDE the `watch` container: it
#   merge-tails lc-local-backend/conversations/*/messages.jsonl with a
#   {path: (inode, offset)} watermark, discovers new conversations live, and
#   prints one normalized record per new message. This script runs that tap via
#   `kubectl exec` and renders it here — tap in the pod, renderer on the host.
#
# THE HONEST LIMIT (C1)
#   Letta Code has NO plugin/hook system, and the local backend persists a
#   message only when it is COMPLETE; the assistant record is text + toolCall
#   only (usage.reasoning is always 0). There is NO token-delta lane and NO
#   reasoning lane. "The entire agent" here means EVERYTHING LETTA PERSISTS, at
#   full fidelity. This view never implies it shows more than that.
#
# IT DOES NOT MISS
#   A chain of guards, each with its OWN loud message, then an automatic fallback
#   that is never a blank screen:
#     deploy exists -> pod Ready -> watch sidecar present -> rich tap present
#     (else ONE loud [fallback] banner -> the events.jsonl tape) -> tape non-empty.
#
# Ctrl-C returns to the prompt INSTANTLY (background children + `wait -n` +
# self-SIGINT); no hanging children, no leftover /tmp/stream-fifo.*.
#
# No HTTP, no port-forward: it reads the pod's own files via `kubectl exec`.
set -u

# ── state initialised BEFORE any function can run (D1) ─────────────────────
# die()/cleanup() reference these; under `set -u` an unset reference aborts the
# whole error path with "unbound variable" garbage instead of the real message.
# The operator hit exactly that with `bash stream.sh -sudo-agent-maintainer-l`.
FIFO=""
FILTER=""
KCTL_PID=""
FILTER_PID=""

EVENTS_FILE="/home/node/.letta/watch/events.jsonl"
TRANSCRIPT_FILE="/home/node/.letta/watch/transcript.txt"
CONV_ROOT="/home/node/.letta/lc-local-backend/conversations"
RICH_TAP="/opt/letta-watch/rich_tap.py"

MODE="rich"          # rich | raw | transcript | fallback
TRUNCATE=0           # 0 = full text (default)
NO_COLOR=0

# ── cleanup / die ──────────────────────────────────────────────────────────
_rm() { for _f in "$@"; do [ -n "$_f" ] && rm -f "$_f" 2>/dev/null; done; }

# Bounded reap: never block forever on a wedged kubectl. The old unbounded
# `wait` could hang the shell after Ctrl-C and strand the FIFO.
_reap_children() {
  local i=0
  while [ "$i" -lt 20 ]; do
    if { [ -z "${KCTL_PID:-}" ] || ! kill -0 "$KCTL_PID" 2>/dev/null; } && \
       { [ -z "${FILTER_PID:-}" ] || ! kill -0 "$FILTER_PID" 2>/dev/null; }; then
      return 0
    fi
    i=$((i + 1)); sleep 0.05
  done
}

# die() tears down the temp files and exits non-zero.
die() { cleanup; printf '%s\n' "$*" >&2; exit 1; }

# cleanup() implements the exit-code/Ctrl-C contract: it removes the FIFO/FILTER
# FIRST (so Ctrl-C can never strand them, even if a child is wedged), then
# terminates the children by pid (kubectl's remote reader dies with the exec
# session; the renderer gets EOF once the FIFO's writer goes away) and reaps
# them with a BOUNDED wait. Idempotent, so it is safe from both the trap and the
# normal end-of-stream path.
cleanup() {
  trap - INT TERM EXIT
  _rm "$FIFO" "$FILTER"
  for pid in ${KCTL_PID:-} ${FILTER_PID:-}; do
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
  done
  pkill -TERM -P $$ 2>/dev/null
  _reap_children
  for pid in ${KCTL_PID:-} ${FILTER_PID:-}; do
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
  done
  pkill -KILL -P $$ 2>/dev/null
  _rm "$FIFO" "$FILTER"
}
trap 'cleanup' INT TERM EXIT

# ── kubeconfig: stream.sh runs on the HOST; sudo changes HOME/kubectl context ──
if [ -z "${KUBECONFIG:-}" ]; then
  for cfg in "/etc/rancher/k3s/k3s.yaml" "/home/world15/.kube/config" "$HOME/.kube/config"; do
    if [ -f "$cfg" ]; then export KUBECONFIG="$cfg"; break; fi
  done
fi

# ── listing / usage / name resolution ──────────────────────────────────────
# list_agents prints the bare names (deploy name minus ONE leading `sudo-`) and
# returns kubectl's rc, so callers can tell "kubectl broken" from "no agents"
# (D8). kubectl errors go to stderr, never into the name list.
list_agents() {
  local out rc
  if ! command -v kubectl >/dev/null 2>&1; then
    printf 'error: kubectl not found in PATH\n' >&2
    return 127
  fi
  out="$(kubectl get deploy -l app=sudo-letta \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'error: kubectl failed to list sudo-letta deployments (rc=%d) — is k3s up / KUBECONFIG set?\n' "$rc" >&2
    return "$rc"
  fi
  printf '%s' "$out" | sed -n 's/^sudo-//p' | sort
  return 0
}

# usage() reprints THIS file's header doc (lines 2 .. line before `set -u`) so
# `--help` can never drift from the comment block (D6: the old fixed range
# '2,17p' silently truncated the docs).
usage() {
  local end
  end="$(grep -n '^set -u$' "$0" 2>/dev/null | head -1 | cut -d: -f1)"
  case "$end" in ''|*[!0-9]*) end=200 ;; esac
  [ "$end" -gt 1 ] && end=$((end - 1))
  sed -n "2,${end}p" "$0" | sed 's/^# \{0,1\}//'
}

# resolve_name: exact (case-insensitive) match on the bare name, then a unique
# substring match; else a clean message on stderr and return 1. It deliberately
# does NOT call die(): resolve_name runs inside `$( )`, and die()'s exit would
# only leave the subshell (the old code papered over that with `|| die ""`,
# which then hit the unbound-$FIFO crash — D1).
resolve_name() {
  local input="$1" lowered names matches count
  lowered="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
  names="$(list_agents)" || return 1
  if [ -z "$names" ]; then
    printf 'error: no sudo-letta agents found to match against\n' >&2
    return 1
  fi
  # 1) exact match (case-insensitive)
  while IFS= read -r bare; do
    if [ "$(printf '%s' "$bare" | tr '[:upper:]' '[:lower:]')" = "$lowered" ]; then
      printf '%s' "$bare"
      return 0
    fi
  done <<< "$names"
  # 2) substring match
  matches="$(grep -i -F -- "$input" <<< "$names" 2>/dev/null || true)"
  count="$(grep -c . <<< "$matches" 2>/dev/null || true)"
  if [ "${count:-0}" -eq 1 ]; then
    printf '%s' "$matches"
    return 0
  fi
  if [ "${count:-0}" -eq 0 ]; then
    printf "no sudo-letta agent matches '%s' (try --list)\n" "$input" >&2
    return 1
  fi
  printf "multiple sudo-letta agents match '%s': %s\n" "$input" \
    "$(paste -sd, - <<< "$matches")" >&2
  return 1
}

# ── argument handling (accept both --NAME and bare NAME) ────────────────────
NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list)
      _names="$(list_agents)" || exit $?
      if [ -z "$_names" ]; then echo "no sudo-letta agents found (app=sudo-letta)"; else printf '%s\n' "$_names"; fi
      exit 0 ;;
    -t|--transcript) MODE="transcript"; shift ;;
    --raw|--events|-e) MODE="raw"; shift ;;
    --truncate)      TRUNCATE="${2:-}"; shift 2 ;;
    --truncate=*)    TRUNCATE="${1#*=}"; shift ;;
    --no-color|--no-colour) NO_COLOR=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    --*)             NAME="${1#-}"; NAME="${NAME#-}"; shift ;;
    *)               NAME="$1"; shift ;;
  esac
done
[ -z "$NAME" ] && { usage; die "error: an agent name is required"; }
case "$TRUNCATE" in ''|*[!0-9]*) die "error: --truncate needs a number (chars)";; esac

# ── resolve + guards (each with its OWN distinct message) ───────────────────
BARE="$(resolve_name "$NAME")" || exit 1
DEPLOY="sudo-${BARE}"

# guard 1: the deployment exists (defense-in-depth; resolve already read the list)
if ! kubectl get "deploy/${DEPLOY}" >/dev/null 2>&1; then
  die "error: deployment ${DEPLOY} does not exist (try --list)"
fi

# guard 2: a Ready pod exists
if ! kubectl get pods -l "agent=${BARE}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
      | grep -q '|True'; then
  die "error: agent ${BARE} has no Ready pod (deployment ${DEPLOY} exists but is not running)"
fi

# guard 3: the observer sidecar container is present
if ! kubectl get "deploy/${DEPLOY}" \
      -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null | grep -qw watch; then
  die "no watch sidecar on this agent yet (not rolled?)"
fi

# ── transcript mode: plain-text chat log, live (D5) ─────────────────────────
if [ "$MODE" = "transcript" ]; then
  if ! kubectl exec "deploy/${DEPLOY}" -c watch -- test -e "$TRANSCRIPT_FILE" >/dev/null 2>&1; then
    printf '→ %s does not exist yet — waiting for the first exchange.\n' "$TRANSCRIPT_FILE" >&2
  fi
  exec kubectl exec "deploy/${DEPLOY}" -c watch -- tail -F -n 40 "$TRANSCRIPT_FILE"
fi

# ── source selection: rich tap, or the events.jsonl tape ────────────────────
FALLBACK_REASON=""
if [ "$MODE" = "rich" ]; then
  if ! kubectl exec "deploy/${DEPLOY}" -c watch -- test -f "$RICH_TAP" >/dev/null 2>&1; then
    if kubectl exec "deploy/${DEPLOY}" -c watch -- true >/dev/null 2>&1; then
      MODE="fallback"
      FALLBACK_REASON="rich tap not present in the watch container (${RICH_TAP})"
    else
      die "cannot exec into the watch container of ${DEPLOY} — is the pod Ready?"
    fi
  fi
fi

if [ "$MODE" = "fallback" ]; then
  printf '%s\n' "[fallback] ${FALLBACK_REASON} — falling back to the events.jsonl tape (${EVENTS_FILE}); reduced fidelity (tool results may be capped by the sidecar)" >&2
fi

# Never a blank screen: if the fallback/raw tape is empty, say so.
if [ "$MODE" != "rich" ]; then
  if ! kubectl exec "deploy/${DEPLOY}" -c watch -- test -s "$EVENTS_FILE" >/dev/null 2>&1; then
    printf '→ %s is empty — waiting for the first message (send the agent a prompt).\n' "$EVENTS_FILE" >&2
  fi
fi

# ── renderer (written to a temp file so stdin stays the pipe) ───────────────
FILTER="$(mktemp /tmp/stream-filter.XXXXXX.py)" || die "error: could not create a renderer temp file"
cat > "$FILTER" <<'PYEOF'
import json
import os
import sys
import time

COLOR = os.environ.get("STREAM_COLOR", "0") == "1"
try:
    TRUNC = int(os.environ.get("STREAM_TRUNCATE", "0") or "0")
except ValueError:
    TRUNC = 0

C = {
    "reset": "\033[0m", "dim": "\033[2m",
    "user": "\033[1;36m", "assistant": "\033[1;32m", "tool": "\033[1;33m",
    "result": "\033[2;37m", "proc": "\033[2;35m", "session": "\033[2;34m",
    "meta": "\033[2;37m", "sys": "\033[33m", "err": "\033[1;31m",
}


def col(name):
    return C.get(name, "") if COLOR else ""


def rst():
    return C["reset"] if COLOR else ""


def stamp(ts):
    try:
        return time.strftime("%H:%M:%S", time.localtime(float(ts)))
    except (TypeError, ValueError, OSError):
        return "--:--:--"


def cap(s):
    if TRUNC and len(s) > TRUNC:
        return s[:max(0, TRUNC - 1)] + "…"
    return s


def out(s):
    sys.stdout.write(s)
    sys.stdout.flush()


def lane(ts, tag, color, body):
    """Tag on the first line; the body is printed VERBATIM (multi-line kept)."""
    body = "" if body is None else str(body)
    lines = body.split("\n")
    out("%s[%s] %s:%s %s\n" % (col(color), stamp(ts), tag, rst(), cap(lines[0])))
    for ln in lines[1:]:
        out("%s%s%s\n" % (col(color), cap(ln), rst()))


def meta_parts(meta):
    parts = []
    prov, model = meta.get("provider"), meta.get("model")
    if prov and model:
        parts.append("%s/%s" % (prov, model))
    elif model:
        parts.append(str(model))
    elif prov:
        parts.append(str(prov))
    if meta.get("stopReason"):
        parts.append("stop=%s" % meta["stopReason"])
    u = meta.get("usage")
    if isinstance(u, dict):
        if u.get("output") is not None:
            parts.append("%s out" % u["output"])
        if u.get("input") is not None:
            parts.append("%s in" % u["input"])
        if u.get("cacheRead"):
            parts.append("cacheRead=%s" % u["cacheRead"])
        c = u.get("cost")
        if isinstance(c, dict) and c.get("total") is not None:
            try:
                parts.append("$%.5f" % float(c["total"]))
            except (TypeError, ValueError):
                pass
    return parts


def main():
    last_meta_msg = None
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            ev = json.loads(raw)
        except ValueError:
            # never silently drop: show the unparseable line in full
            out("%s[--:--:--] RAW:%s %s\n" % (col("err"), rst(), raw))
            continue
        if not isinstance(ev, dict):
            continue
        ts = ev.get("ts")
        etype = ev.get("event") or "?"
        meta = ev.get("meta") if isinstance(ev.get("meta"), dict) else {}

        if etype == "user":
            pre = "SYS> " if ev.get("reminder") else ""
            lane(ts, "USER", "sys" if ev.get("reminder") else "user",
                 pre + (ev.get("text") or ""))
        elif etype == "thinking":
            lane(ts, "THINKING", "proc", ev.get("text") or "")
        elif etype == "assistant":
            lane(ts, "ASSISTANT", "assistant", ev.get("text") or "")
        elif etype == "tool_call":
            args = ev.get("args")
            try:
                args = json.dumps(args, ensure_ascii=False)
            except (TypeError, ValueError):
                args = str(args)
            lane(ts, "TOOL %s" % (ev.get("name") or "?"), "tool", args or "")
        elif etype == "tool_result":
            nm = ev.get("toolName")
            tag = ("RESULT %s" % nm) if nm else "RESULT"
            body = ev.get("text") or ""
            if ev.get("truncated"):
                body += ("\n[note: the events.jsonl tape capped this body at %d of %s bytes]"
                         % (len(body.encode("utf-8", "replace")), ev.get("full_bytes")))
            lane(ts, tag, "result", body)
        elif etype == "process_state":
            procs = ev.get("processes") if isinstance(ev.get("processes"), list) else []
            lane(ts, "PROC", "proc", "%s pids=%d" % (ev.get("state") or "?", len(procs)))
        elif etype == "session":
            sid = ev.get("id") or ev.get("conversation") or "?"
            lane(ts, "SESSION", "session", str(sid))
        elif etype == "tap_ready":
            lane(ts, "TAP", "meta", "rich tap ready (conv_root=%s)" % ev.get("conv_root", ""))
        elif etype in ("tap_warn", "tap_error"):
            lane(ts, "TAP-" + ("ERROR" if etype == "tap_error" else "WARN"),
                 "err", ev.get("message") or "")
        elif etype == "other":
            try:
                blk = json.dumps(ev.get("block"), ensure_ascii=False)
            except (TypeError, ValueError):
                blk = str(ev.get("block"))
            lane(ts, "OTHER", "meta", blk)
        else:
            # unknown event type -> printed in FULL, never silently dropped
            try:
                whole = json.dumps(ev, ensure_ascii=False)
            except (TypeError, ValueError):
                whole = str(ev)
            lane(ts, "EVENT %s" % etype, "meta", whole)

        # one dim meta line per assistant message
        if meta and ev.get("msg") and ev.get("msg") != last_meta_msg and \
                etype in ("assistant", "tool_call", "thinking", "other"):
            parts = meta_parts(meta)
            if parts:
                out("%s    └ %s%s\n" % (col("meta"), " · ".join(parts), rst()))
            last_meta_msg = ev.get("msg")


if __name__ == "__main__":
    main()
PYEOF

# ── colour policy: on a TTY unless --no-color ───────────────────────────────
USE_COLOR=0
if [ "$NO_COLOR" -eq 0 ] && [ -t 1 ]; then USE_COLOR=1; fi

# ── the stream: kubectl <source> -> FIFO -> renderer ────────────────────────
# Both children run in the BACKGROUND and we `wait` on them; this is what makes
# Ctrl-C return the prompt INSTANTLY (bash runs the INT trap right after `wait`
# is interrupted; a foreground pipeline would defer the trap until the pipeline
# ends). The trap kills kubectl (its remote reader dies with the exec session)
# and the renderer, so no hanging children and no leftover FIFO.
FIFO="$(mktemp -u /tmp/stream-fifo.XXXXXX)"
mkfifo "$FIFO" || die "error: could not create FIFO ${FIFO}"

if [ "$MODE" = "rich" ]; then
  kubectl exec "deploy/${DEPLOY}" -c watch -- python3 -u "$RICH_TAP" > "$FIFO" 2>/dev/null &
else
  kubectl exec "deploy/${DEPLOY}" -c watch -- tail -F -n 20 "$EVENTS_FILE" > "$FIFO" 2>/dev/null &
fi
KCTL_PID=$!

STREAM_COLOR="$USE_COLOR" STREAM_TRUNCATE="$TRUNCATE" python3 -u "$FILTER" < "$FIFO" &
FILTER_PID=$!

wait -n 2>/dev/null
# Deterministic teardown: Ctrl-C runs the INT trap (instant), and if the source
# ends on its own — or SIGINT was inherited-ignored (a backgrounded invocation) —
# this explicit cleanup still runs. cleanup() is idempotent.
cleanup
exit 0
