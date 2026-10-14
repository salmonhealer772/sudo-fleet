# sudo-gws — fleet-shared Google Workspace MCP service (Drive + Docs + Sheets)
#
# Wraps taylorwilsdon/google_workspace_mcp (PyPI `workspace-mcp`) so the WHOLE
# fleet shares ONE OAuth token store: OAuth ONCE as operator@example.com, the
# refresh token persisted to the PVC, and every agent (Letta + Hermes) reads and
# writes the operator's Drive/Docs/Sheets through this one HTTP endpoint — no
# per-agent auth.
#
# Transport: streamable-http (FastMCP). Endpoints served on WORKSPACE_MCP_PORT:
#   /mcp              MCP endpoint (tools/list, tools/call, initialize)
#   /health           liveness/readiness probe
#   /oauth2callback   OAuth consent callback (the browser redirect target)
#
# Auth mode: LEGACY OAuth 2.0 + single-user. Deliberately NOT OAuth 2.1 — the
# spec is "OAuth ONCE, then every agent uses it without its own auth", which is
# exactly legacy single-user mode (one consent -> one refresh token in the
# credential dir). --single-user and MCP_ENABLE_OAUTH21 are mutually exclusive
# (main.py enforces it), so OAuth 2.1 is off here by construction.
#
# Surfaces in scope: --tools drive docs sheets ONLY. Gmail/Calendar/Slides/Chat/
# Forms/Tasks/Contacts/Search/Apps Script are never registered.
FROM python:3.11-slim

WORKDIR /app

# curl for the healthcheck + ca-certificates for Google API TLS.
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# workspace-mcp + the disk-backed credential-store extra. Pinned EXACT (2.1.0),
# not latest, so a breaking upstream release cannot silently change the tool
# surface or auth flow across the fleet.
RUN pip install --no-cache-dir "workspace-mcp[disk]==2.1.0"

# Non-root user; owns the credential-store volume dir (the PVC mounts here).
RUN useradd --create-home --shell /bin/bash app \
    && mkdir -p /data \
    && chown -R app:app /data

USER app

# Refresh token + credential store live on the PVC mounted at /data.
ENV WORKSPACE_MCP_CREDENTIALS_DIR="/data"

EXPOSE 8000

# k8s uses its own liveness/readiness probes; this HEALTHCHECK is for bare
# docker runs and matches the /health path the server serves.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD sh -c 'curl -f http://localhost:${WORKSPACE_MCP_PORT:-8000}/health || exit 1'

# Args (--transport/--single-user/--tools) are supplied by the k8s deployment.
ENTRYPOINT ["workspace-mcp"]
