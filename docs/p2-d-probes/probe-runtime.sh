#!/bin/sh
# probe-runtime.sh — READ-ONLY runtime checks for one sudo-agent pod.
#
# Runs INSIDE the agent container (via `kubectl exec ... -c <container> -- sh -s`),
# or against any host that has the same HERMES_HOME. It only reads: no file is
# created, no hook is invoked, nothing is mutated except a read-only SQLite open.
#
# Usage (from a host that has kubectl):
#   kubectl -n <ns> exec <pod> -c <container> -- sh -s < probe-runtime.sh
#
# Every number this prints is one the report cites. Secret-free by construction:
# it prints counts, hashes and daemon-wide plugin state — never message bodies,
# never env, never config values outside the memory budget.
set -u
H="${HERMES_HOME:-/opt/data}"
PY="${HERMES_PY:-/opt/hermes/.venv/bin/python}"
[ -x "$PY" ] || PY="$(command -v python3 || echo /usr/bin/python3)"

echo "=== probe-runtime.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "HERMES_HOME=$H"

echo "--- version ---"
hermes --version 2>&1 | head -5

echo "--- watch/plugin.json (loading) ---"
if [ -f "$H/watch/plugin.json" ]; then
  cat "$H/watch/plugin.json"
  echo
else
  echo "MISSING $H/watch/plugin.json"
fi

echo "--- watch tape (size / rows) ---"
if [ -f "$H/watch/stream.jsonl" ]; then
  wc -lc "$H/watch/stream.jsonl"
else
  echo "MISSING $H/watch/stream.jsonl"
fi

echo "--- watch dir (plugin error surfaces) ---"
ls -la "$H/watch/" 2>&1

echo "--- memory budget (config.yaml) ---"
grep -nE '^[[:space:]]*(memory_char_limit|user_char_limit|memory_enabled|user_profile_enabled):' "$H/config.yaml" 2>&1

echo "--- state.db counts ---"
"$PY" - "$H/state.db" <<'EOF' 2>&1
import sqlite3, sys
p = sys.argv[1]
try:
    c = sqlite3.connect("file:%s?mode=ro" % p, uri=True)
except Exception as e:
    print("OPEN FAILED:", e); raise SystemExit
for t in ("sessions", "messages"):
    try:
        print(t, c.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0])
    except Exception as e:
        print(t, "ERR", e)
try:
    print("app_schema_version", c.execute("SELECT version FROM schema_version").fetchone()[0])
except Exception as e:
    print("app_schema_version ERR", e)
EOF

echo "--- identity ---"
md5sum "$H/SOUL.md" 2>&1
wc -c "$H/SOUL.md" 2>&1
echo "skills_dirs $(ls "$H/skills/" 2>/dev/null | wc -l)"
ls "$H/skills/" 2>&1

echo "--- gate ledger (must be writable) ---"
ls -la "$H/skills/.usage.json" 2>&1

echo "--- memories (byte counts only) ---"
wc -c "$H/memories/"*.md 2>&1

echo "--- comm seed markers ---"
ls -la "$H/.comm-seeded" 2>&1
# Match the CURRENT persona text (h3's memory contract). Do NOT grep the old
# config.yaml comment wording ("durable facts about the environment", plural) —
# that string never appears in the persona block, so it reads as a false negative.
grep -c '^## Your memory' "$H/SOUL.md" 2>/dev/null || echo 0
grep -c 'One entry is one fact' "$H/SOUL.md" 2>/dev/null || echo 0
grep -rl '^## Your memory' "$H/skills/" 2>/dev/null || echo "SKILLS: no memory-instruction text (expected: the persona is the carrier)"

echo "=== end ==="
