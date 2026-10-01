# sudo-letta — Letta Code with full root inside a privileged container
FROM node:22-bookworm-slim

# Stamped at build time so setup.sh can detect source changes and rebuild
# instead of skipping on a stale image (see factories/sudo-letta/setup.sh).
ARG SOURCE_HASH=unknown

LABEL sudo-letta="true" description="Letta Code with sudo + native memory" \
      sudo-fleet.source-hash="${SOURCE_HASH}"

# Install build deps + tools (node-pty compile deps, etc.)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    sudo \
    ca-certificates \
    curl \
    git \
    make \
    g++ \
    python3 \
    python3-pip \
    ripgrep \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI from Docker's own apt repo. Debian bookworm's docker.io is
# 20.10 / API 1.41, which is too old to talk to a modern host daemon
# (needs API >= 1.44). docker-ce-cli tracks the daemon so they always match.
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

# Passwordless sudo for node user
RUN echo "node ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/node && \
    chmod 0440 /etc/sudoers.d/node

# Docker-socket access is armed at RUNTIME, not baked here. The host docker
# group gid varies across nodes (lima = 109, Blake's laptop = 986, ...), and a
# hardcoded gid breaks the comm host bridge (list-siblings / message-agent /
# check-agent) on every node whose gid differs. The agent container runs with
# runAsUser: 0 (see kube-scripts/up.sh) so its entrypoint (mcp_entrypoint.sh)
# starts as root, reads the REAL gid off /var/run/docker.sock, adds `node` to
# it, then drops to node — the same runtime gid-arm the sudo-agent side uses
# (a4df988). `USER node` below stays: it is the default for the watch sidecar
# (which never touches the socket).

# Install Letta Code globally.
# PINNED to 0.33.2 (exact pin, not ^/latest): letta-code 0.33.0 silently broke
# loading of .ts-entry mods - the official web-search mod's tool never
# registered, with zero diagnostics. 0.33.2 is verified working with
# web_search (verified live 2026-09). Do NOT unpin without testing web_search
# on a recreated pod after any CLI upgrade.
RUN npm install -g @letta-ai/letta-code@0.33.2 && \
    npm cache clean --force

# Pre-seed Letta config
RUN mkdir -p /home/node/.letta && \
    echo '{"lastAgent":null,"tokenStreaming":false,"globalSharedBlockIds":{},"preferredBackendMode":"local"}' > /home/node/.letta/settings.json && \
    chown -R node:node /home/node

# Pre-install the official web-search mod so every FRESH agent is born with it
# (tool: web_search). Existing agents' PVCs already carry the mod and the PVC
# mounts over image contents, so this matters for NEW agents/PVCs only.
# MOD PIN: the mod is installed at an EXACT version (@0.1.0), never
# latest/^, so a breaking upstream release cannot silently kill
# web_search across the fleet. Bump deliberately and re-test live.
RUN su node -c 'HOME=/home/node letta install npm:@letta-ai/web-search@0.1.0'

# Create /.letta so the process can write local project settings without EACCES
RUN mkdir -p /.letta && chown -R node:node /.letta

# Per-pod MCP server: a streamable-HTTP wrapper over letta-p's prompt logic.
# letta_prompt.py is the single source of truth shared with kube-scripts/letta-p.py;
# mcp_server.py runs inside the pod and prompts THIS agent directly (no kubectl).
# mcp_entrypoint.sh starts the MCP server and keeps the pod alive (the CMD below).
COPY kube-scripts/letta_prompt.py /opt/letta-mcp/letta_prompt.py
COPY kube-scripts/mcp_server.py /opt/letta-mcp/mcp_server.py
COPY kube-scripts/mcp_entrypoint.sh /opt/letta-mcp/mcp_entrypoint.sh
# Observer sidecar daemon: monitors the agent container's processes, captures
# every prompt/reply/thinking/tool event from the Letta message store into a
# durable JSONL log on the agent PVC, and serves a live HTTP tap.
COPY kube-scripts/watch_sidecar.py /opt/letta-watch/watch_sidecar.py
RUN chmod +x /opt/letta-mcp/mcp_entrypoint.sh && \
    pip3 install --no-cache-dir --break-system-packages fastmcp==4.0.9 redis==5.2.1 && \
    chown -R node:node /opt/letta-mcp

# Rich full-fidelity tap for stream.sh RICH mode: stdlib-only, read-only
# file placed OUTSIDE the agent PVC mount (/home/node/.letta) so the PVC can
# never shadow it. Driven only by kube-scripts/stream.sh via `kubectl exec -c
# watch`; the watch sidecar is unaffected. Shipped exactly like
# watch_sidecar.py (kept as its OWN layer, after the pip RUN, so adding it
# does not invalidate the cached image layers).
COPY --chmod=0755 kube-scripts/rich_tap.py /opt/letta-watch/rich_tap.py

USER node

WORKDIR /home/node/.letta

CMD ["sh", "/opt/letta-mcp/mcp_entrypoint.sh"]
