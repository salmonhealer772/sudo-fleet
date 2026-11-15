# sudo-upwork-mcp — fleet-shared Upwork MCP gateway.
#
# Fronts Upwork's OFFICIAL MCP server (mcp.upwork.com/mcp) as an MCP client,
# re-exposing its tools to the fleet over streamable HTTP. OAuth 2.1 is CIMD
# (client_id = public metadata URL) + PKCE; the single access/refresh token
# lives on the PVC mounted at /data so it survives restarts.
#
# Transport: streamable HTTP (FastAPI + uvicorn). Endpoints:
#   /mcp               MCP endpoint (initialize, tools/list, tools/call)
#   /health            liveness/readiness probe
#   /authorize         returns the one-time authorization URL
#   /authorize/complete  receives the code captured by the Mac helper
#   /status            token status
FROM python:3.12-slim

WORKDIR /app

# curl for the healthcheck + ca-certificates for TLS to mcp.upwork.com.
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY oauth.py server.py /app/

# Non-root user; owns the token-file dir (the PVC mounts here).
RUN useradd --create-home --shell /bin/bash app \
    && mkdir -p /data \
    && chown -R app:app /data

USER app
ENV UPWORK_TOKEN_FILE=/data/tokens.json

EXPOSE 9232

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -fsS http://127.0.0.1:9232/health || exit 1

ENTRYPOINT ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "9232"]
