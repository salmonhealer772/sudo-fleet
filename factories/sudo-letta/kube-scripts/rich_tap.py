#!/usr/bin/env python3
"""rich_tap.py — in-pod FULL-FIDELITY message tap for sudo-letta `stream.sh` RICH mode.

Runs INSIDE the `watch` container (stdlib only; Python 3.11 from the image).
It is a small, dedicated alternative to `watch_sidecar.py`'s capture thread: the
sidecar TRUNCATES tool-result bodies (result_truncate_bytes, default 4096) and
flattens messages into its own tape; `stream.sh` needs the WHOLE thing.

What it does
------------
1. Merge-tails every `lc-local-backend/conversations/*/messages.jsonl`.
2. Keeps a `{path: (inode, byte_offset)}` watermark so each file is read once,
   from where it left off (never re-emits an old record).
3. Discovers NEW conversation directories as they appear (a fresh conversation
   must be picked up live).
4. Handles truncation / rotation: a file smaller than its offset, or whose inode
   changed, resets that file's watermark to 0.
5. Emits ONE normalized JSON record per line to stdout, ordered by record
   timestamp (merged across conversations), tagged with the source conversation.
6. Emits `process_state` liveness beats by polling /proc (the pod shares a PID
   namespace). This is the honest "the agent is doing something" signal, because
   Letta persists a message only when it is COMPLETE. The always-on infrastructure
   in this image (mcp_server.py, mcp_entrypoint.sh, watch_sidecar.py) is excluded
   — their paths contain "letta", so a naive match would report "active" forever.
7. Caps the FIRST pass at RICHTAP_BACKLOG (default 200) events so `stream.sh` on
   a long-lived agent shows recent history, not the entire archive.
8. NEVER raises: any parse/IO error becomes a `{"event":"tap_error", ...}` line.

Schema
------
The emitted records use the SAME `{"ts","conversation","event",...}` keys
`watch_sidecar.py` writes to events.jsonl, extended with full-fidelity fields:

  {"ts": <epoch float>, "conversation": "<decoded conv id>", "event": "...", ...}

  event=user         {text, reminder}
  event=assistant    {text, provider, model, stopReason, usage, msg, meta, last}
  event=thinking     {text, ...}                      (see C1 note below)
  event=tool_call    {name, args (FULL), toolCallId, msg, meta}
  event=tool_result  {text (FULL, never truncated), toolName, toolCallId, isError}
  event=session      {id, cwd}
  event=process_state{state, processes}
  event=tap_ready / tap_warn / tap_error

Because the schema matches the sidecar's, `stream.sh` renders BOTH the RICH tap
and the FALLBACK events.jsonl tape through ONE renderer, and never truncates.

C1 — HONESTY CONSTRAINT (do not paper over)
-------------------------------------------
There is NO reasoning lane and NO token-delta lane on the Letta side. Letta Code
has no plugin/hook system, and the local backend persists a message only when it
is complete. The persisted assistant record for a deepseek turn is
`content: [{"type":"text"},{"type":"toolCall"}]` with `usage.reasoning: 0`.
"THE ENTIRE AGENT" therefore means everything Letta PERSISTS, at full fidelity —
not token deltas and not reasoning. This tap never implies otherwise.
"""

import base64
import calendar
import json
import os
import sys
import time

CONV_ROOT = os.environ.get(
    "RICHTAP_CONV_ROOT", "/home/node/.letta/lc-local-backend/conversations")
POLL = float(os.environ.get("RICHTAP_POLL", "0.25"))
PROC_EVERY = float(os.environ.get("RICHTAP_PROC_EVERY", "1.0"))
# First pass: cap the backlog so `stream.sh` on a long-lived agent does not dump
# the whole history. Live records after the first pass are unbounded.
BACKLOG = int(os.environ.get("RICHTAP_BACKLOG", "200"))

# Cmdlines that are ALWAYS present and must NOT count as "the agent is working":
# the same image hosts the MCP server and the observer sidecar, and their paths
# contain "letta", so a naive substring match would report "active" forever.
DAEMON_MARKERS = ("mcp_server.py", "mcp_entrypoint.sh", "watch_sidecar.py",
                  "rich_tap.py")


# ── output ────────────────────────────────────────────────────────────────

def emit(obj):
    """One JSON object per line; never raise (a dead tap must not kill stream)."""
    try:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    except Exception:
        pass


def now():
    return time.time()


# ── helpers ───────────────────────────────────────────────────────────────

def decode_conv(dirname):
    """'Y29udmVyc2F0aW9uOmxvY2FsLWNvbnYtMQ' -> 'conversation:local-conv-1'."""
    try:
        return base64.b64decode(
            dirname + "=" * (-len(dirname) % 4)).decode("utf-8", "replace")
    except Exception:
        return dirname


def parse_ts(record, msg):
    """Best-effort epoch-seconds from record.timestamp (ISO) or msg.timestamp (ms)."""
    for src in (msg.get("timestamp"), record.get("timestamp")):
        if isinstance(src, bool):
            continue
        if isinstance(src, (int, float)):
            v = float(src)
            if v > 1e12:          # epoch millis
                v /= 1000.0
            return v
        if isinstance(src, str) and src.strip():
            s = src.strip()
            try:
                if s.endswith("Z"):
                    base = s[:-1]
                    fmt = "%Y-%m-%dT%H:%M:%S.%f" if "." in base else "%Y-%m-%dT%H:%M:%S"
                    return float(calendar.timegm(time.strptime(base, fmt)))
                return float(time.mktime(time.strptime(s, "%Y-%m-%dT%H:%M:%S.%f")))
            except Exception:
                continue
    return now()


def _read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return b""


# ── normalization ─────────────────────────────────────────────────────────

def normalize(record, conv):
    """Turn one messages.jsonl record into a list of normalized events."""
    out = []
    if not isinstance(record, dict):
        return out
    rtype = record.get("type")
    if rtype == "session":
        out.append({"event": "session", "ts": parse_ts(record, {}),
                    "conversation": conv, "id": record.get("id"),
                    "cwd": record.get("cwd")})
        return out
    if rtype != "message":
        return out
    msg = record.get("message")
    if not isinstance(msg, dict):
        return out
    role = msg.get("role")
    ts = parse_ts(record, msg)
    mid = record.get("id")
    content = msg.get("content")
    if not isinstance(content, list):
        content = []

    if role == "user":
        for blk in content:
            if isinstance(blk, dict) and blk.get("type") == "text":
                txt = blk.get("text", "")
                out.append({"event": "user", "ts": ts, "conversation": conv,
                            "msg": mid, "text": txt,
                            "reminder": "<system-reminder>" in txt})

    elif role == "assistant":
        meta = {}
        for k in ("provider", "model", "stopReason"):
            if msg.get(k):
                meta[k] = msg[k]
        if isinstance(msg.get("usage"), dict):
            meta["usage"] = msg["usage"]
        n = len(content)
        for i, blk in enumerate(content):
            if not isinstance(blk, dict):
                continue
            bt = blk.get("type")
            ev = {"conversation": conv, "ts": ts, "msg": mid,
                  "meta": meta, "last": (i == n - 1)}
            if bt == "thinking":
                ev["event"] = "thinking"
                ev["text"] = blk.get("thinking") or blk.get("text") or ""
            elif bt == "toolCall":
                ev["event"] = "tool_call"
                ev["name"] = blk.get("name")
                ev["args"] = blk.get("arguments")
                ev["toolCallId"] = blk.get("id")
            elif bt == "text":
                ev["event"] = "assistant"
                ev["text"] = blk.get("text", "")
            else:
                # unknown block type -> never silently dropped
                ev["event"] = "other"
                ev["block"] = blk
            out.append(ev)

    elif role == "toolResult":
        for blk in content:
            if isinstance(blk, dict) and blk.get("type") == "text":
                out.append({"event": "tool_result", "ts": ts,
                            "conversation": conv, "msg": mid,
                            "text": blk.get("text", ""),          # FULL, no cap
                            "toolName": msg.get("toolName"),
                            "toolCallId": msg.get("toolCallId"),
                            "isError": bool(msg.get("isError"))})
    return out


# ── process monitor (mirrors watch_sidecar.py) ────────────────────────────

def self_pid_tree():
    me = os.getpid()
    tree = {me}
    try:
        entries = os.listdir("/proc")
    except OSError:
        return tree
    for entry in entries:
        if not entry.isdigit():
            continue
        try:
            ppid = _read("/proc/%s/stat" % entry).decode(
                "utf-8", "replace").split(")")[-1].split()[1]
            if int(ppid) in tree:
                tree.add(int(entry))
        except (IndexError, ValueError):
            pass
    return tree


def poll_processes():
    mine = self_pid_tree()
    letta = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid in mine or pid == 1:      # pid 1 == pause container
            continue
        cmdline = _read("/proc/%s/cmdline" % entry).decode(
            "utf-8", "replace").replace("\0", " ").strip()
        if not cmdline:                  # kernel thread / gone
            continue
        if "letta" not in cmdline.lower():
            continue
        if any(m in cmdline for m in DAEMON_MARKERS):
            continue                     # always-on infrastructure, not work
        letta.append({"pid": pid, "cmdline": cmdline[:300]})
    return ("active" if letta else "idle"), letta


# ── main ──────────────────────────────────────────────────────────────────

def scan_conversations():
    """Map messages.jsonl path -> decoded conversation id."""
    found = {}
    try:
        entries = os.listdir(CONV_ROOT)
    except OSError:
        return found
    for d in entries:
        p = os.path.join(CONV_ROOT, d, "messages.jsonl")
        try:
            if os.path.isfile(p):
                found[p] = decode_conv(d)
        except OSError:
            continue
    return found


def read_new(path, off):
    """Read complete new lines from `path` starting at byte `off`.

    Returns (list_of_decoded_lines, new_offset). On a partial trailing line the
    offset stops before it, so the line is completed and read next pass.
    """
    with open(path, "rb") as f:
        f.seek(off)
        buf = f.read()
    if not buf:
        return [], off
    if buf.endswith(b"\n"):
        complete, new_off = buf, off + len(buf)
    else:
        idx = buf.rfind(b"\n")
        if idx == -1:
            return [], off              # only a partial line so far
        complete = buf[:idx + 1]
        new_off = off + idx + 1
    lines = complete.decode("utf-8", "replace").splitlines()
    return lines, new_off


def main():
    watermarks = {}          # path -> [inode, offset]
    last_proc_state = None
    last_proc_emit = 0.0
    warned_missing = False
    first_pass = True

    emit({"event": "tap_ready", "ts": now(), "conv_root": CONV_ROOT,
          "poll_s": POLL})

    while True:
        try:
            convs = scan_conversations()
            if not os.path.isdir(CONV_ROOT):
                if not warned_missing:
                    emit({"event": "tap_warn", "ts": now(),
                          "message": "conversations dir not present yet: %s "
                                     "(will pick it up live)" % CONV_ROOT})
                    warned_missing = True
            else:
                warned_missing = False

            batch = []
            for path, conv in convs.items():
                try:
                    st = os.stat(path)
                except OSError:
                    continue
                wm = watermarks.get(path)
                ino = st.st_ino
                off = 0
                if wm is not None:
                    prev_ino, prev_off = wm[0], wm[1]
                    if prev_ino == ino and st.st_size >= prev_off:
                        off = prev_off
                    # else: rotated/recreated or shrunk -> reset to 0
                if st.st_size == off:
                    watermarks[path] = [ino, off]
                    continue
                try:
                    lines, new_off = read_new(path, off)
                except OSError as exc:
                    emit({"event": "tap_error", "ts": now(),
                          "message": "read failed %s: %s" % (path, exc)})
                    continue
                watermarks[path] = [ino, new_off]
                for raw in lines:
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        rec = json.loads(raw)
                    except ValueError:
                        continue
                    for ev in normalize(rec, conv):
                        batch.append(ev)

            # merged, chronological across conversations; the FIRST pass keeps
            # only the most recent BACKLOG events so a long-lived agent is not
            # dumped whole when stream.sh attaches.
            batch.sort(key=lambda e: e.get("ts") or 0)
            if first_pass and len(batch) > BACKLOG:
                batch = batch[-BACKLOG:]
            for ev in batch:
                emit(ev)
            first_pass = False

        except Exception as exc:            # never die
            emit({"event": "tap_error", "ts": now(),
                  "message": "capture loop: %r" % (exc,)})

        # liveness beats
        try:
            t = now()
            if last_proc_state is None or (t - last_proc_emit) >= PROC_EVERY:
                state, procs = poll_processes()
                if state != last_proc_state:
                    last_proc_state = state
                    last_proc_emit = t
                    emit({"event": "process_state", "ts": t, "conversation": "",
                          "state": state, "processes": procs})
        except Exception as exc:
            emit({"event": "tap_error", "ts": now(),
                  "message": "proc poll: %r" % (exc,)})

        time.sleep(POLL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as exc:                # last-ditch: report, never crash silently
        emit({"event": "tap_error", "ts": now(), "message": "fatal: %r" % (exc,)})
