# sudo-gmail-mcp — fleet-shared Gmail MCP service (Gmail REST API)
#
# Wraps taylorwilsdon/google_workspace_mcp (PyPI `workspace-mcp`) the same way
# sudo-gws does, but registers ONLY the Gmail surface (`--tools gmail`). The
# workspace-mcp image is tool-agnostic — the service surface is a runtime flag,
# so this Dockerfile is byte-for-byte the sudo-gws image recipe, pinned to the
# same exact version (2.1.0) so the fleet cannot drift.
#
# Accounts: single-user OAuth 2.0 mode, but MULTI-account in practice: the
# credential dir holds one <email>.json per consented account, and each tool's
# `user_google_email` parameter selects which account's token to use. See the
# `get_credentials` single-user branch (auth/google_auth.py) — a requested user
# with no credential returns "authorization required" rather than falling back.
#
# Transport: streamable-http (FastMCP). Endpoints served on WORKSPACE_MCP_PORT:
#   /mcp              MCP endpoint (tools/list, tools/call, initialize)
#   /health           liveness/readiness probe
#   /oauth2callback   OAuth consent callback (the browser redirect target)
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

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD sh -c 'curl -f http://localhost:${WORKSPACE_MCP_PORT:-8000}/health || exit 1'

# Args (--transport/--single-user/--tools) are supplied by the k8s deployment.
ENTRYPOINT ["workspace-mcp"]
