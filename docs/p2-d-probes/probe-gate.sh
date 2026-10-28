#!/bin/sh
# probe-gate.sh — READ-ONLY comm-gate probe for one sudo-agent pod.
#
# Runs INSIDE the agent container. It writes NOTHING: it reads the gate's ledger,
# checks the ledger file the gate's lifecycle hook depends on, and exercises the
# CLI half of the gate twice — once with a cold session id (must exit 69 BLOCKED)
# and once with no session at all (must be allowed: the human/script path).
#
# The plugin half (pre_tool_call veto) cannot be driven from here without a turn.
# probe-runtime.sh supplies the ledger read that proves the lifecycle hook fired,
# and the report pairs that with a driven turn.
#
#   kubectl -n <ns> exec <pod> -c <container> -- sh -s < probe-gate.sh
#
# NOTE on exit codes: every EXIT= below is captured from the command itself, NOT
# from a pipeline. `cmd | head; echo $?` reports head's status, which would make
# a blocked command look successful — the exact class of fake pass this probe is
# meant to rule out.
set -u
H="${HERMES_HOME:-/opt/data}"
T=/opt/comm-tools

echo "=== probe-gate.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

echo "--- gate ledger dir ---"
ls -la "$H/comm-gate/" 2>&1

echo "--- sessions recorded in the ledger ---"
python3 - "$H/comm-gate/state.json" <<'PY' 2>&1
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print("sessions_in_ledger", len(d))
    for sid, skills in list(d.items())[-5:]:
        print("  ", sid[:16], "->", sorted(skills))
except FileNotFoundError:
    print("state.json ABSENT -> nothing loaded yet (fail-closed side of the gate)")
except Exception as e:
    print("state.json unreadable:", e)
PY

echo "--- gate ledger prerequisite: skills/.usage.json writable ---"
ls -la "$H/skills/.usage.json" 2>&1
if test -w "$H/skills/.usage.json"; then echo "USAGE_WRITABLE=yes"; else echo "USAGE_WRITABLE=no"; fi
python3 -c "import os;print('USAGE_MTIME',os.stat(os.environ.get('HERMES_HOME','/opt/data')+'/skills/.usage.json').st_mtime)" 2>&1

echo "--- CLI half, COLD session id, list-siblings -> must BLOCK (exit 69) ---"
_out=$(HERMES_SESSION_ID=probe-cold-does-not-exist python3 "$T/list_siblings.py" 2>&1); _rc=$?
echo "$_out"
echo "EXIT=$_rc"

echo "--- CLI half, SAME cold session, message-agent -> must BLOCK too ---"
# Do NOT probe this with --help: argparse exits 0 before main() ever calls gate(),
# so --help measures nothing. A real invocation against a deliberately nonexistent
# sibling is safe: the gate runs at the top of main(), BEFORE any transport is
# built, so a working gate blocks it without sending anything anywhere.
_out=$(HERMES_SESSION_ID=probe-cold-does-not-exist python3 "$T/message_agent.py" probe-nonexistent-agent "gate probe" 2>&1); _rc=$?
echo "$_out"
echo "EXIT=$_rc"

echo "--- CLI half, SAME cold session, check-agent -> must BLOCK too ---"
_out=$(HERMES_SESSION_ID=probe-cold-does-not-exist python3 "$T/check_agent.py" probe-nonexistent-agent 2>&1); _rc=$?
echo "$_out"
echo "EXIT=$_rc"

echo "--- CLI half, NO session (human/script path) -> must be ALLOWED ---"
_out=$(env -u HERMES_SESSION_ID python3 "$T/list_siblings.py" --filter zzzz-nomatch 2>&1); _rc=$?
echo "$_out"
echo "EXIT=$_rc"

echo "--- ungated command must never be touched ---"
sh -c 'echo ungated-ok'; echo "EXIT=$?"
echo "=== end ==="
