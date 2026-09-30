#!/bin/sh
# Per-pod MCP supervisor for sudo-agent.
#
# The sudo-agent image has NO own CMD/entrypoint: up.sh runs the BASE image's
# entrypoint with `args: ["gateway", "run"]`, and `gateway run` (a long-running
# Hermes gateway) IS the pod's main process. So, unlike sudo-letta, there is no
# `tail -f /dev/null` to swap in — we must ADD the MCP server alongside the
# gateway WITHOUT replacing it.
#
# This script is the image ENTRYPOINT. It:
#   1. NO-OP when REDIS_URL (shared sudo-agent-redis, injected by up.sh) is set —
#      the distributor then uses the SHARED fleet Redis. Only when REDIS_URL is
#      UNSET does it start a per-pod localhost Redis (offline fallback, AOF on)
#      here;
#   2. starts the MCP server (the FastMCP streamable-HTTP wrapper over
#      hermes-p) in the background, in a restart loop so a crash doesn't take
#      the endpoint down permanently;
#   3. execs the base image's entrypoint dispatcher with the original args
#      (`gateway run`), so the gateway starts EXACTLY as before under the
#      s6-overlay supervision tree.
#
# The MCP server (and its drain worker) runs as the hermes user (uid 10000,
# HOME=/opt/data) so its `hermes -z` subprocesses and any files it writes are
# uid-aligned with the supervised gateway — the same ownership the existing
# `kubectl exec ... hermes -z` flow relies on. MCP_PORT is the per-agent port
# (unique because every sudo-agent pod runs hostNetwork:true and would
# otherwise collide); it defaults to 8000 and is normally injected by up.sh.
#
# PORTS IN THIS POD ARE NODE-GLOBAL. With hostNetwork:true the pod shares the
# node's network namespace, so "localhost" is the NODE's loopback and every
# listener is visible to every other hostNetwork pod on the node. That is why
# every port here is per-agent-unique: MCP_PORT (cksum of the agent name),
# WATCH_PORT (cksum of "<name>-watch"), and the fallback Redis port below —
# which must never be 6379 (owned by the sudo-letta fleet's Redis) or 6380
# (owned by our shared sudo-agent-redis).
#
# Redis data dir: /opt/data/redis/ (the agent PVC) — the fallback queue then
# survives container restarts and pod recreation as long as the PVC persists;
# only losing the PVC loses it.

set -u

# Comm layer: two distinct concerns, split on purpose.
#
#   (1) SKILLS — seeded into $HERMES_HOME/skills (the PVC) on FIRST boot only,
#       guarded by a .comm-seeded marker. The tool backends are baked into the
#       image (Dockerfile COPY -> /opt/comm-tools/), but Hermes reads skills
#       from the PVC and the agent may edit them later, so a re-seed every
#       boot would clobber its edits. Safe no-ops when a dir/file is absent:
#       every seeding step is `|| true`, so a missing source or an unwritable
#       PVC can never block first boot — worst case the agent starts unseeded.
#
#   (2) PERSONA — the fleet-comm awareness snippet, applied to SOUL.md as a
#       FACTORY-MANAGED BLOCK on EVERY boot (not first-boot-only). It lives
#       between fixed BEGIN/END markers; on each boot we replace the content
#       between the markers (or insert the block if absent) so the agent can
#       never permanently lose or stale its fleet awareness, and a rebuilt
#       image ships a fresh snippet on the next restart. Nothing outside the
#       markers is ever touched.
if [ ! -f /opt/data/.comm-seeded ]; then
  mkdir -p /opt/data/skills 2>/dev/null || true
  if [ -d /opt/comm-skills ]; then
    cp -a /opt/comm-skills/. /opt/data/skills/ 2>/dev/null || true
  fi
  chown -R 10000:10000 /opt/data/skills 2>/dev/null || true
  touch /opt/data/.comm-seeded 2>/dev/null || true
fi

# Fleet-comm awareness block: applied to SOUL.md on EVERY boot (managed block).
# _apply_fleet_block <target> <snippet>: replace the content between the
# BEGIN/END markers in place, or append the whole block if absent. Idempotent;
# never touches anything outside the markers.
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
_apply_fleet_block /opt/data/SOUL.md /opt/comm/PERSONA-SNIPPET.md
chown 10000:10000 /opt/data/SOUL.md 2>/dev/null || true

# First-boot gap: on a FRESH no-glimor pod SOUL.md does not exist yet when this
# entrypoint runs — the gateway creates its default 514-byte SOUL.md only AFTER
# we exec it below, so the synchronous apply above no-oped (file absent) and the
# block would stay missing until the next restart. Close the gap with a one-shot
# background watcher: poll for SOUL.md to appear and apply the managed block the
# moment it does. Idempotent (the gateway never rewrites an existing SOUL.md, so
# one apply per boot is enough), and only spawned when the file is absent now —
# on restarts/glimes the synchronous apply above already handled it.
if [ ! -f /opt/data/SOUL.md ]; then
  (
    _fc_n=0
    while [ "$_fc_n" -lt 300 ]; do
      [ -f /opt/data/SOUL.md ] && [ -s /opt/data/SOUL.md ] && break
      sleep 1
      _fc_n=$((_fc_n+1))
    done
    if [ -f /opt/data/SOUL.md ] && [ -s /opt/data/SOUL.md ]; then
      _apply_fleet_block /opt/data/SOUL.md /opt/comm/PERSONA-SNIPPET.md
      chown 10000:10000 /opt/data/SOUL.md 2>/dev/null || true
    fi
  ) &
fi

PORT="${MCP_PORT:-8000}"

# Offline-fallback Redis port: derived from MCP_PORT so it is unique per agent.
# The formula is injective over the MCP_PORT range (8000..32767) and lands in
# 40000..59999, clear of MCP_PORT/WATCH_PORT and of both fleets' shared Redis
# ports (6379 sudo-letta-redis, 6380 sudo-agent-redis). REDIS_PORT overrides.
RPORT="${REDIS_PORT:-$(( 40000 + (PORT * 7) % 20000 ))}"

# Redis backing for the prompt distributor: by default the SHARED
# sudo-agent-redis (REDIS_URL injected by up.sh; deployed by
# kube-scripts/redis-up.sh, hostNetwork on the node loopback, PVC-backed, AOF
# on). Local per-pod Redis is only an OFFLINE FALLBACK when REDIS_URL is unset:
# bound to 127.0.0.1 ONLY (pods run hostNetwork:true, so binding anything else
# would expose the queue to every pod on the node), AOF ON, run as hermes
# (uid 10000) so the AOF files on the PVC are owned by the agent uid, in a
# restart loop so a Redis crash cannot take the distributor down permanently.
if [ -z "${REDIS_URL:-}" ]; then
  mkdir -p /opt/data/redis 2>/dev/null || true
  # Restart loop: if redis-server crashes (OOM, AOF corruption, ...) the loop
  # relaunches it after 2s, so a transient Redis death never takes the
  # prompt-distributor queue down permanently — only this offline fallback
  # path runs at all (the shared fleet Redis has no such in-pod loop).
  (
    while :; do
      HOME=/opt/data /command/s6-setuidgid hermes \
        redis-server \
          --port "$RPORT" \
          --bind 127.0.0.1 \
          --protected-mode yes \
          --appendonly yes \
          --appendfsync everysec \
          --dir /opt/data/redis \
          --dbfilename dump.rdb \
          --logfile /opt/data/redis/redis.log \
          --daemonize no || true
      sleep 2
    done
  ) &
fi

# Start the MCP server in the background, in a restart loop, because it is a
# sidecar to the gateway: if mcp_server.py crashes the loop relaunches it 2s
# later, so the endpoint is never down permanently and one bad request can't
# kill the whole pod's MCP surface.
(
  while :; do
    HOME=/opt/data HERMES_HOME=/opt/data MCP_PORT="$PORT" REDIS_PORT="$RPORT" REDIS_URL="${REDIS_URL:-}" \
      /command/s6-setuidgid hermes \
      /opt/hermes/.venv/bin/python /opt/hermes-mcp/mcp_server.py || true
    sleep 2
  done
) &

# exec (not run) the base image's entrypoint so `gateway run` REPLACES this
# shell as the pod's main process; if the gateway exits, the container exits
# with it and the background MCP loop dies as the container stops (no orphaned
# MCP server left behind).
exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
