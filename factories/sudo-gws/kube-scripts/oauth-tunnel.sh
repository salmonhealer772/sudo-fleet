#!/usr/bin/env bash
# One-time OAuth consent tunnel for sudo-gws.
#
# The server's redirect URI is http://localhost:8000/oauth2callback (Google
# only allows http:// for loopback hosts). The consent browser runs on the
# operator's Mac, so we forward the Mac's loopback:8000 to the pod's 27462
# via a reverse SSH tunnel (lima -> Mac), which the lima host reaches directly.
#
# Usage (on the lima host, as root):
#   bash factories/sudo-gws/kube-scripts/oauth-tunnel.sh          # start
#   bash factories/sudo-gws/kube-scripts/oauth-tunnel.sh --stop   # tear down
#
# After this tunnel is up, the operator opens the "Authorization URL" printed
# by the server (from a tool call or the logs) in his Mac browser; Google
# redirects back to http://localhost:8000/oauth2callback which lands on the pod.
set -euo pipefail

MAC_USER="aidanmcohen"
MAC_HOST="192.168.5.2"
MCP_PORT=27462

if [[ "${1:-}" == "--stop" ]]; then
  pkill -f "ssh .*-R 8000:localhost:${MCP_PORT}" 2>/dev/null && echo "tunnel stopped" || echo "no tunnel running"
  exit 0
fi

if pgrep -f "ssh .*-R 8000:localhost:${MCP_PORT}" >/dev/null 2>&1; then
  echo "tunnel already running (Mac:8000 -> pod:${MCP_PORT})"
  exit 0
fi

echo "→ starting reverse tunnel: Mac localhost:8000 -> this host localhost:${MCP_PORT} (the pod)"
nohup ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \
  -N -R 8000:localhost:${MCP_PORT} "${MAC_USER}@${MAC_HOST}" \
  >/tmp/sudo-gws-oauth-tunnel.log 2>&1 &
echo "→ tunnel pid $! (log: /tmp/sudo-gws-oauth-tunnel.log)"
echo "  Redirect URI to register in Google: http://localhost:8000/oauth2callback"
