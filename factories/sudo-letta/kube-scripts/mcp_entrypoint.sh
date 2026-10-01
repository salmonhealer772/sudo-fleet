#!/bin/sh
# Per-pod MCP supervisor: keep the MCP HTTP server running and the pod alive.
#
# This is the sudo-letta container CMD. It starts the MCP server (the FastMCP
# streamable-HTTP wrapper over letta-p) in the background, then execs
# `tail -f /dev/null` so the container stays up for the other exec-based flows
# (up.sh's `letta connect`, interactive shells, `kubectl exec ... letta`).
#
# The MCP server is (re)started in a loop so a crash doesn't take the endpoint
# down permanently. MCP_PORT is the per-agent port (unique because every
# sudo-letta pod runs hostNetwork:true and would otherwise collide); it defaults
# to 8000 and is normally injected by up.sh.

set -u

PORT="${MCP_PORT:-8000}"

(
  while :; do
    HOME=/home/node MCP_PORT="$PORT" python3 /opt/letta-mcp/mcp_server.py || true
    sleep 2
  done
) &

# Fleet-comm awareness block: re-applied to the agent's system/persona.md on
# EVERY boot (this entrypoint runs on each restart). The snippet is persisted
# to the PVC at /home/node/.letta/fleet-comm-snippet.md by up.sh at deploy
# time; here we re-apply it so a plain restart (no redeploy) also refreshes
# the factory-managed block. Graceful no-op when the agent/MemFS or the
# snippet is absent (e.g. a fresh no-glimor pod before up.sh's `letta connect`
# has created the agent) — worst case the block is applied by up.sh on the
# next deploy.
_apply_fleet_block() {
  _fc_target="$1"; _fc_snippet="$2"
  _fc_begin='<!-- FLEET-COMM-AWARENESS-BEGIN -->'
  _fc_end='<!-- FLEET-COMM-AWARENESS-END -->'
  [ -f "$_fc_target" ] || return 0
  [ -f "$_fc_snippet" ] || return 0
  if ! grep -qF "$_fc_begin" "$_fc_target" || ! grep -qF "$_fc_end" "$_fc_target"; then
    { printf '\n'; printf '%s\n' "$_fc_begin"; cat "$_fc_snippet"; printf '%s\n' "$_fc_end"; } >> "$_fc_target"
  else
    awk -v b="$_fc_begin" -v e="$_fc_end" -v s="$_fc_snippet" '
      $0 == b { print; skip=1; emitted=0; next }
      $0 == e { print; skip=0; next }
      skip { if (!emitted) { while ((getline l < s) > 0) print l; close(s); emitted=1 } next }
      { print }
    ' "$_fc_target" > "$_fc_target.tmp" && mv "$_fc_target.tmp" "$_fc_target"
  fi
}
_fc_snippet="/home/node/.letta/fleet-comm-snippet.md"
if [ -f "$_fc_snippet" ]; then
  for _fc_mem in /home/node/.letta/lc-local-backend/memfs/*/memory; do
    [ -d "$_fc_mem" ] || continue
    _fc_persona="$_fc_mem/system/persona.md"
    if [ -f "$_fc_persona" ]; then
      _apply_fleet_block "$_fc_persona" "$_fc_snippet"
      chown node:node "$_fc_persona" 2>/dev/null || true
      git -C "$_fc_mem" init -q -b main 2>/dev/null
      git -C "$_fc_mem" add -A 2>/dev/null && git -C "$_fc_mem" -c user.email=factory@localhost -c user.name=factory commit -q -m 'seed fleet-comm persona' >/dev/null 2>&1 || true
    fi
  done
fi
unset _fc_snippet _fc_mem _fc_persona

exec tail -f /dev/null
