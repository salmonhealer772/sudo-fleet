# sudo-msgraph-mcp — fleet-shared Microsoft Graph MCP service (Outlook Mail)
#
# Wraps elyxlz/microsoft-mcp (a FastMCP-based Microsoft Graph server with
# device-code OAuth and multi-account support) behind a streamable-http
# transport so it fits the fleet's `mcp_servers.<name>.url` wiring, exactly like
# sudo-gws / sudo-gmail-mcp.
#
# Chosen over the official "Microsoft MCP Server for Enterprise" because that
# one is tenant-provisioned and requires Application Administrator consent in
# Entra (a university tenant where the operator is not an admin). A community
# delegated-OAuth server using the device-code flow is the cleanly-deployable
# path for a single user's mailbox.
#
# Auth: device-code flow (msal.PublicClientApplication). The operator consents
# ONCE by visiting microsoft.com/devicelogin and entering a code — no redirect
# URI to register, no client secret on the pod. The token cache persists to the
# PVC via HOME=/data.
#
# NOTE: the device-code client (MICROSOFT_MCP_CLIENT_ID) must be an Entra ID
# app registration with delegated Graph permissions Mail.Read / Mail.Send /
# Mail.ReadWrite and "Allow public client flows" enabled. The Thunderbird IMAP
# client (9e5f94bc-...) does NOT grant Graph mail scopes and cannot be reused.
FROM python:3.12-slim

WORKDIR /app

# curl for the healthcheck + ca-certificates for Graph TLS + git for the pip VCS
# install of the upstream server.
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

# elyxlz/microsoft-mcp (FastMCP server). Pinned to the upstream master commit
# hash for reproducibility; the package itself has no PyPI release yet.
ARG MICROSOFT_MCP_REF=master
RUN pip install --no-cache-dir \
    "git+https://github.com/elyxlz/microsoft-mcp.git@${MICROSOFT_MCP_REF}"

# Custom streamable-http entrypoint (upstream server.py runs stdio-only).
COPY server_http.py /app/server_http.py

# Non-root user; owns the token-cache dir. HOME=/data so msal's token cache
# (pl.Path.home()/.microsoft_mcp_token_cache.json) persists on the PVC.
RUN useradd --create-home --shell /bin/bash app \
    && mkdir -p /data \
    && chown -R app:app /data

USER app
ENV HOME=/data \
    MICROSOFT_MCP_TOKEN_CACHE_DIR=/data

EXPOSE 8000

# No /health route on the upstream FastMCP server — k8s uses a tcpSocket probe
# on the MCP port instead. This HEALTHCHECK is a bare-docker convenience.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD python3 -c "import socket,sys; s=socket.create_connection(('127.0.0.1',int(__import__('os').getenv('MCP_PORT','8000'))),2); s.close()" || exit 1

ENTRYPOINT ["python3", "/app/server_http.py"]
