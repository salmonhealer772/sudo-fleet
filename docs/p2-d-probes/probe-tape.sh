#!/bin/sh
# probe-tape.sh — READ-ONLY snapshot of the watch tape (stream.jsonl).
#
# Prints ROW COUNT, BYTE SIZE and an event-type histogram over the tail, so two
# runs either side of a driven turn give a ROW DELTA. A tape that exists but did
# not grow proves the plugin LOADED and nothing else; this probe is built to show
# the difference.
#
# It deliberately prints NO payload text: only event names, tool names and
# integer counts. On a messaging/mail agent the delta and result bodies can
# contain someone's real correspondence, and this output is committed to a public
# repo.
#
#   kubectl -n <ns> exec <pod> -c <container> -- sh -s < probe-tape.sh
#   ... optional env: TAPE_TAIL=4000  (events to histogram, default 4000)
set -u
H="${HERMES_HOME:-/opt/data}"
F="$H/watch/stream.jsonl"
TAIL_N="${TAPE_TAIL:-4000}"

echo "=== probe-tape.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

echo "--- plugin.json (LOADING state) ---"
if [ -f "$H/watch/plugin.json" ]; then
  cat "$H/watch/plugin.json"; echo
else
  echo "MISSING $H/watch/plugin.json"
fi

echo "--- tape size ---"
if [ -f "$F" ]; then wc -lc "$F"; else echo "MISSING $F"; fi

echo "--- event histogram over the last $TAIL_N rows (NO payload text) ---"
python3 - "$F" "$TAIL_N" <<'PY' 2>&1
import collections, json, os, sys
path, n = sys.argv[1], int(sys.argv[2])
if not os.path.exists(path):
    print("no tape"); raise SystemExit
# Read only the tail: on a long-lived agent this file is >100 MB.
size = os.path.getsize(path)
block = min(size, 4 * 1024 * 1024)
with open(path, "rb") as f:
    f.seek(size - block)
    raw = f.read().decode("utf-8", "replace")
lines = [l for l in raw.splitlines() if l.startswith("{")]
rows = []
for l in lines[-n:]:
    try:
        rows.append(json.loads(l))
    except ValueError:
        pass
hist = collections.Counter(r.get("event") or "?" for r in rows)
print("rows_histogrammed", len(rows))
for k, v in hist.most_common():
    print("  %-14s %d" % (k, v))

tools = sorted({r.get("tool") or "" for r in rows if r.get("event") in ("tool_call", "tool_result")})
tools = [t for t in tools if t]
if tools:
    print("tools_seen", tools)

print("--- last 12 events (names + scalars only) ---")
keep = ("event", "tool", "status", "kind", "turn_id", "session_id", "finish_reason",
        "delta_count", "text_chars", "reasoning_chars", "streamed", "error",
        "duration_ms", "synthesized", "phase")
for r in rows[-12:]:
    d = {k: r[k] for k in keep if k in r}
    if "turn_id" in d:
        d["turn_id"] = str(d["turn_id"])[:12]
    if "session_id" in d:
        d["session_id"] = str(d["session_id"])[:20]
    print("  " + json.dumps(d, ensure_ascii=False))
PY

echo "--- watch dir (the plugin's own error surface) ---"
ls -la "$H/watch/" 2>&1
echo "=== end ==="
