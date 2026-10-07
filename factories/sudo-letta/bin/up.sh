#!/usr/bin/env bash
set -uo pipefail

# bin/up.sh — Deploy a sudo-letta agent to Kubernetes
# Usage: bash bin/up.sh --name

NAME=""
GLIMOR_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-glimor) GLIMOR_DIR="$2"; shift 2 ;;
    --name|--*)    NAME="${1#--}"; shift ;;
    *)             echo "Usage: bash bin/up.sh --name [--from-glimor <dir>]" >&2; exit 1 ;;
  esac
done

if [[ -z "$NAME" ]]; then
  echo "Usage: bash bin/up.sh --name" >&2
  echo "Example: bash bin/up.sh --alice" >&2
  exit 1
fi

if [[ "${NAME,,}" == "all" ]]; then
  echo "'--ALL' is reserved. Pick a different name." >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_DIR/.sudo-letta/.env"
YAML_DIR="$REPO_DIR/deployments"
DEPLOY="sudo-$NAME"
YAML="$YAML_DIR/$NAME.yaml"

# Hostname used for the pod's /etc/hosts hostAliases entry — lets sudo resolve the
# host's own hostname (avoids `sudo: unable to resolve host <name>` under hostNetwork).
# hostAliases.hostnames MUST be a lowercase RFC 1123 subdomain: lowercase, only
# [a-z0-9.-], and must start/end with [a-z0-9]. A raw hostname with uppercase
# letters (e.g. "LaptopOfBlake") makes kubectl apply reject the Deployment, so
# normalize here — once, at capture — so every downstream use is already safe.
NODE_HOSTNAME="$(hostname | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9.-' '-' | sed -E 's/^[-.]+//; s/[-.]+$//')"

# Per-agent MCP server port. Every sudo-letta pod runs hostNetwork:true, so all
# pods share the node's network namespace and a single fixed port would collide.
# Derive a stable, unique port from the agent name (stays below the ephemeral
# range, 32768+). The Service below exposes a stable port 8000 and forwards
# (targetPort) to this unique per-agent port.
MCP_PORT=$(( 8000 + $(printf '%s' "$NAME" | cksum | cut -d' ' -f1) % 24768 ))

# Per-agent WATCH (observer sidecar) port — same hostNetwork collision rules
# as MCP_PORT, but hashed from a DIFFERENT string ("$NAME-watch") so it never
# collides with the MCP port. Guard bumps by 1 in the (astronomically rare) case
# the two hashes land on the same port.
WATCH_PORT=$(( 8000 + $(printf '%s-watch' "$NAME" | cksum | cut -d' ' -f1) % 24768 ))
if [[ "$WATCH_PORT" == "$MCP_PORT" ]]; then
  WATCH_PORT=$(( MCP_PORT + 1 ))
fi

# Docker-socket group gid (runtime, per-node). The image no longer bakes a
# hardcoded docker gid (the old `groupadd --gid 109` only matched hosts whose
# docker group happened to be gid 109; it silently broke the comm host bridge —
# list-siblings / message-agent / check-agent — on hosts with a different gid,
# e.g. Blake's 986). We read the REAL gid off the host socket here and grant it
# to the pod via securityContext.supplementalGroups. That is the Letta-side
# equivalent of the sudo-agent a4df988 runtime gid-arm: unlike the Hermes side
# there is no s6-setuidgid privilege drop in this container (it runs directly as
# the image USER node), so a pod-level supplemental group is NOT wiped by
# initgroups() and works as intended. Emitted only when the socket is present.
DOCKER_SOCK_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || true)"
if [[ -n "$DOCKER_SOCK_GID" ]]; then
  POD_SECURITY_CONTEXT="      securityContext:
        supplementalGroups: [${DOCKER_SOCK_GID}]"
else
  POD_SECURITY_CONTEXT=""
fi

# If repo is root-owned and we're not root, bail early
if [[ ! -w "$REPO_DIR" ]] && [[ "$(id -u)" != "0" ]]; then
  echo "Repo is root-owned. Run with: sudo bash bin/up.sh --$NAME" >&2
  exit 1
fi

mkdir -p "$YAML_DIR" 2>/dev/null || true

# Auto-detect kubeconfig (sudo changes HOME, kubectl can lose it)
if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in "/etc/rancher/k3s/k3s.yaml" "/home/world15/.kube/config" "$HOME/.kube/config"; do
    if [[ -f "$cfg" ]]; then export KUBECONFIG="$cfg"; break; fi
  done
  if [[ -z "${KUBECONFIG:-}" ]]; then
    echo "No kubeconfig found. Is k3s running? Try: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >&2
    exit 1
  fi
fi

echo "→ sudo-$NAME starting up..."

# ── Env vars ──
if [[ -f "$ENV_FILE" ]] && [[ -r "$ENV_FILE" ]]; then
  # Read env file for API key and provider
  LLM_PROVIDER=$(grep '^LLM_PROVIDER=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | head -1 || true)
  API_KEY=$(grep '^API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | head -1 || true)
  LLM_BASE_URL=$(grep '^LLM_BASE_URL=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | head -1 || true)
  # LLM_MODEL: the model to pin on the agent AFTER `letta connect` (see the
  # provider/model wiring below). Read from the same source as the provider and
  # base-url so a custom OpenAI-compatible endpoint's exact model id is
  # available at deploy time instead of relying on the endpoint's first
  # discovered model. Never echoed.
  LLM_MODEL=$(grep '^LLM_MODEL=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | head -1 || true)
  # Optional web_search provider keys (read but never echoed/committed).
  # Any that are set AND non-empty are injected into the pod env below;
  # unset ones are skipped entirely (no empty-value env vars).
  for _opt in EXA_API_KEY TAVILY_API_KEY PARALLEL_API_KEY PERPLEXITY_API_KEY; do
    _val=$(grep "^${_opt}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | head -1 || true)
    [[ -n "${_val}" ]] && eval "${_opt}="\${_val}"" || true
  done
  unset _opt _val
  # Web-search provider key gate: a deployed agent MUST have at least one of
  # the search provider keys (fleet env above or agent-scoped /secret). If we
  # are injecting none at all, fail the deploy LOUDLY — the web-search mod
  # would install but every web_search call would fail at runtime.
  _have_key=0
  for _opt in EXA_API_KEY TAVILY_API_KEY PARALLEL_API_KEY PERPLEXITY_API_KEY; do
    [[ -n "${!_opt:-}" ]] && _have_key=1
  done
  unset _opt
  if [[ "$_have_key" -ne 1 ]]; then
    echo "✗ FATAL: no web-search provider key found in $ENV_FILE." >&2
    echo "  Add at least one of: EXA_API_KEY, TAVILY_API_KEY, PARALLEL_API_KEY, PERPLEXITY_API_KEY" >&2
    echo "  (the web-search mod cannot search without one; refusing to deploy a blind agent)" >&2
    exit 1
  fi
fi

# Prompt for credentials if missing
if [[ -z "${LLM_PROVIDER:-}" || -z "${API_KEY:-}" ]]; then
  echo "No credentials found. Run setup.sh first." >&2
  exit 1
fi

# NOTE: SUDO_PASSWORD was intentional dead code and has been removed. The `node`
# account is locked and sudo elevation is via the NOPASSWD sudoers rule
# (/etc/sudoers.d/node) only — no password is ever set, so the SUDO_PASSWORD env
# var never did anything.

# ── Generate YAML ──
# Build env lines for YAML — API keys reference a per-deployment
# Kubernetes Secret (created below from the fleet .env). The secret
# keeps keys out of the Deployment manifest and out of `kubectl apply`
# audit logs. Non-secret env vars are still inlined.
ENV_YAML="        - name: LLM_PROVIDER
          value: \"${LLM_PROVIDER}\"
        - name: API_KEY
          valueFrom:
            secretKeyRef:
              name: ${DEPLOY}-api-key
              key: api-key
        - name: LETTA_API_KEY
          valueFrom:
            secretKeyRef:
              name: ${DEPLOY}-api-key
              key: api-key"
[[ -n "${LLM_BASE_URL:-}" ]] && ENV_YAML+="
        - name: LLM_BASE_URL
          value: \"${LLM_BASE_URL}\""
# Pin the exact model on the agent record (critical for Featherless/OpenAI-compatible
# endpoints where the handle and wire id differ - see patch-featherless-deepseek.cjs).
[[ -n "${LETTA_MODEL:-}" ]] && ENV_YAML+="
        - name: LETTA_MODEL
          value: "${LETTA_MODEL}""
# Optional web_search provider keys: inject only the ones that are set and
# non-empty (fleet-wide fallback; agent-scoped /secret takes precedence per
# the mod). Never echo the values.
for _opt in EXA_API_KEY TAVILY_API_KEY PARALLEL_API_KEY PERPLEXITY_API_KEY; do
  _val="${!_opt:-}"
  if [[ -n "$_val" ]]; then
    ENV_YAML+="
        - name: ${_opt}
          value: \"${_val}\""
  fi
done
unset _opt _val

ENV_YAML+="
        - name: USER
          value: \"node\"
        - name: HOME
          value: \"/home/node\"
        - name: LETTA_HOME
          value: \"/home/node/.letta\"
        - name: MCP_PORT
          value: \"${MCP_PORT}\""

# ── Optional glimor seed (initContainer seeds the PVC BEFORE the agent runs) ──
# When --from-glimor <dir> is given, an initContainer copies <dir>/letta/ into
# /home/node/.letta BEFORE the letta process starts, so a fork wakes as the
# seeded agent (never a blank Tutor). Idempotent: a .glimor-seeded marker skips
# re-seeding on restarts (preserving the fork's runtime changes). A missing or
# invalid glimor fails the initContainer (and the deploy) loudly — never a
# silent blank-agent fallback.
SEED_INITCONTAINERS=""
SEED_VOLUME=""
if [[ -n "${GLIMOR_DIR:-}" ]]; then
  if [[ ! -d "$GLIMOR_DIR/letta" ]] || [[ ! -f "$GLIMOR_DIR/letta/settings.json" ]]; then
    echo "✗ --from-glimor $GLIMOR_DIR: missing letta/ or letta/settings.json (a valid Letta glimor needs both)" >&2
    exit 1
  fi
  GLIMOR_ABS="$(cd "$GLIMOR_DIR" && pwd)"
  SEED_INITCONTAINERS="      initContainers:
      - name: seed-glimor
        image: sudo-letta:latest
        imagePullPolicy: IfNotPresent
        securityContext:
          runAsUser: 0
        command: [\"sh\", \"-c\", \"if test -f /home/node/.letta/.glimor-seeded; then exit 0; fi; if ! test -d /seed/letta; then exit 1; fi; if ! test -f /seed/letta/settings.json; then exit 1; fi; cp -a /seed/letta/. /home/node/.letta/ && echo Y29uc3QgZnMgPSByZXF1aXJlKCJmcyIpOwpjb25zdCBwYXRoID0gcmVxdWlyZSgicGF0aCIpOwpjb25zdCBob21lID0gIi9ob21lL25vZGUvLmxldHRhIjsKY29uc3Qgc2VydmVyID0gImxvY2FsOi9ob21lL25vZGUvLmxldHRhL2xjLWxvY2FsLWJhY2tlbmQiOwpjb25zdCBzZXR0aW5nc1BhdGggPSBwYXRoLmpvaW4oaG9tZSwgInNldHRpbmdzLmpzb24iKTsKY29uc3QgbG9jYWxTZXR0aW5nc1BhdGggPSBwYXRoLmpvaW4oaG9tZSwgIi5sZXR0YSIsICJzZXR0aW5ncy5sb2NhbC5qc29uIik7Cgp0cnkgewogIGNvbnN0IGQgPSBKU09OLnBhcnNlKGZzLnJlYWRGaWxlU3luYyhzZXR0aW5nc1BhdGgsICJ1dGY4IikpOwogIGNvbnN0IGFncyA9IChkLmFnZW50cyB8fCBbXSkuZmlsdGVyKGEgPT4gYSAmJiAoYS5tZW1mcyA9PT0gdHJ1ZSB8fCBhLnBpbm5lZCA9PT0gdHJ1ZSkpOwogIGNvbnN0IHQgPSBhZ3MuZmluZChhID0+IGEucGlubmVkID09PSB0cnVlKSB8fCBhZ3NbMF07CiAgaWYgKHQgJiYgdC5hZ2VudElkKSB7CiAgICAvLyAxLiBnbG9iYWwgc2V0dGluZ3MuanNvbjogcmVzdW1lIHRhcmdldCAtPiBzZWVkZWQgcGlubmVkL21lbWZzIGFnZW50LCAiZGVmYXVsdCIgY29udmVyc2F0aW9uCiAgICBkLmxhc3RBZ2VudCA9IHQuYWdlbnRJZDsKICAgIGQuc2Vzc2lvbnNCeVNlcnZlciA9IGQuc2Vzc2lvbnNCeVNlcnZlciB8fCB7fTsKICAgIGQuc2Vzc2lvbnNCeVNlcnZlcltzZXJ2ZXJdID0geyBhZ2VudElkOiB0LmFnZW50SWQsIGNvbnZlcnNhdGlvbklkOiAiZGVmYXVsdCIgfTsKICAgIGZzLndyaXRlRmlsZVN5bmMoc2V0dGluZ3NQYXRoLCBKU09OLnN0cmluZ2lmeShkLCBudWxsLCAyKSArICJcbiIpOwoKICAgIC8vIDIuIHNldHRpbmdzLmxvY2FsLmpzb246IHRoZSBmaWxlIGBsZXR0YSAtcGAgYWN0dWFsbHkgdXNlcyBmb3IgcmVzdW1lIChsYXN0QWdlbnQgKyBsYXN0U2Vzc2lvbikKICAgIGZzLm1rZGlyU3luYyhwYXRoLmRpcm5hbWUobG9jYWxTZXR0aW5nc1BhdGgpLCB7IHJlY3Vyc2l2ZTogdHJ1ZSB9KTsKICAgIGxldCBsZCA9IHt9OwogICAgdHJ5IHsgbGQgPSBKU09OLnBhcnNlKGZzLnJlYWRGaWxlU3luYyhsb2NhbFNldHRpbmdzUGF0aCwgInV0ZjgiKSk7IH0gY2F0Y2ggKGUpIHt9CiAgICBsZC5sYXN0QWdlbnQgPSB0LmFnZW50SWQ7CiAgICBsZC5zZXNzaW9uc0J5U2VydmVyID0geyBbc2VydmVyXTogeyBhZ2VudElkOiB0LmFnZW50SWQsIGNvbnZlcnNhdGlvbklkOiAiZGVmYXVsdCIgfSB9OwogICAgbGQubGFzdFNlc3Npb24gPSB7IGFnZW50SWQ6IHQuYWdlbnRJZCwgY29udmVyc2F0aW9uSWQ6ICJkZWZhdWx0IiB9OwogICAgZnMud3JpdGVGaWxlU3luYyhsb2NhbFNldHRpbmdzUGF0aCwgSlNPTi5zdHJpbmdpZnkobGQsIG51bGwsIDIpICsgIlxuIik7CgogICAgY29uc29sZS5sb2coInNlZWQtbm9ybWFsaXplOiByZXN1bWUgdGFyZ2V0IC0+ICIgKyB0LmFnZW50SWQgKyAiIChkZWZhdWx0KSBbc2V0dGluZ3MuanNvbiArIHNldHRpbmdzLmxvY2FsLmpzb25dIik7CiAgfSBlbHNlIHsKICAgIGNvbnNvbGUubG9nKCJzZWVkLW5vcm1hbGl6ZTogbm8gcGlubmVkL21lbWZzIGFnZW50IGZvdW5kOyBsZWZ0IHNldHRpbmdzIGFzLWlzIik7CiAgfQp9IGNhdGNoIChlKSB7CiAgY29uc29sZS5sb2coInNlZWQtbm9ybWFsaXplOiBza2lwcGVkICgiICsgZS5tZXNzYWdlICsgIikiKTsKfQo= | base64 -d | node && cd /home/node/.letta/lc-local-backend/memfs/*/memory && git init -q -b main && git -c safe.directory='*' add -A && git -c safe.directory='*' -c user.email=glimor@localhost -c user.name=glimor commit -q -m seed-fork-state && chown -R 1000:1000 /home/node/.letta && touch /home/node/.letta/.glimor-seeded\"]
        volumeMounts:
        - name: data
          mountPath: /home/node/.letta
        - name: seed
          mountPath: /seed
          readOnly: true"
  SEED_VOLUME="      - name: seed
        hostPath:
          path: $GLIMOR_ABS
          type: Directory"
fi

cat > "$YAML" <<YAMLEOF
# Per-deployment API key Secret — created before the Deployment so
# kubectl apply succeeds on the first run. The Secret is owned by
# the same labels as the Deployment for consistent cleanup.
apiVersion: v1
kind: Secret
metadata:
  name: ${DEPLOY}-api-key
  labels:
    app: sudo-letta
    agent: $NAME
type: Opaque
data:
  api-key: $(printf '%s' "${API_KEY}" | base64 -w0)
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $DEPLOY-data
  labels:
    app: sudo-letta
    agent: $NAME
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY
  labels:
    app: sudo-letta
    agent: $NAME
spec:
  replicas: 1
  # Recreate, NOT RollingUpdate: every agent pod runs hostNetwork:true and
  # binds a per-agent fixed port (MCP_PORT), so a rolling update brings the NEW
  # pod up beside the OLD one and the new pod crash-loops (port already in use
  # in the shared node netns) while the rollout hangs. The old pod MUST
  # terminate before the new one starts (the same reason redis-up.sh uses
  # Recreate).
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: sudo-letta
      agent: $NAME
  template:
    metadata:
      labels:
        app: sudo-letta
        agent: $NAME
    spec:
      shareProcessNamespace: true
      hostNetwork: true
$POD_SECURITY_CONTEXT
      hostAliases:
      - ip: "127.0.0.1"
        hostnames:
        - "$NODE_HOSTNAME"
$SEED_INITCONTAINERS
      containers:
      - name: sudo-letta
        image: sudo-letta:latest
        imagePullPolicy: IfNotPresent
        securityContext:
          privileged: true
        env:
$ENV_YAML
        volumeMounts:
        - name: data
          mountPath: /home/node/.letta
        - name: docker-sock
          mountPath: /var/run/docker.sock
        # ── Self-repair probes: restart on crash/hang ───────────────────────
        # The agent's MCP server (mcp_server.py) listens on MCP_PORT (0.0.0.0).
        # startupProbe gives it a generous boot window; livenessProbe restarts a
        # hung-but-alive agent; readinessProbe gates Service rotation. Process
        # crash is already handled by restartPolicy: Always (the default).
        startupProbe:
          tcpSocket:
            port: $MCP_PORT
          periodSeconds: 5
          failureThreshold: 30
        readinessProbe:
          tcpSocket:
            port: $MCP_PORT
          periodSeconds: 5
          failureThreshold: 3
        livenessProbe:
          tcpSocket:
            port: $MCP_PORT
          periodSeconds: 20
          failureThreshold: 3
      # ── Observer sidecar container ────────────────────────────────────────
      # Monitors the agent container (shared PID namespace), captures every
      # message from the Letta store into <PVC>/watch/events.jsonl, and serves
      # the HTTP tap on WATCH_PORT. Same image; no docker socket; unprivileged.
      - name: watch
        image: sudo-letta:latest
        imagePullPolicy: IfNotPresent
        command: ["python3", "/opt/letta-watch/watch_sidecar.py"]
        env:
        - name: WATCH_PORT
          value: "$WATCH_PORT"
        - name: AGENT_NAME
          value: "$NAME"
        - name: DEPLOY_NAME
          value: "$DEPLOY"
        - name: HOME
          value: "/home/node"
        volumeMounts:
        - name: data
          mountPath: /home/node/.letta
        - name: watch-config
          mountPath: /etc/watch-config
        # ── Self-repair probes: the sidecar serves GET /healthz -> 200 on
        # WATCH_PORT (binds 0.0.0.0). livenessProbe restarts a hung sidecar;
        # readinessProbe gates Service rotation on the tap being up.
        startupProbe:
          httpGet:
            path: /healthz
            port: $WATCH_PORT
          periodSeconds: 3
          failureThreshold: 10
        readinessProbe:
          httpGet:
            path: /healthz
            port: $WATCH_PORT
          periodSeconds: 5
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /healthz
            port: $WATCH_PORT
          periodSeconds: 15
          failureThreshold: 3
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: $DEPLOY-data
$SEED_VOLUME
      - name: docker-sock
        hostPath:
          path: /var/run/docker.sock
          type: Socket
      - name: watch-config
        configMap:
          name: $DEPLOY-watch-config
---
# ── Observer sidecar (watch) ──────────────────────────────────────────────
# ConfigMap consumed by the watch container at /etc/watch-config/config.json.
apiVersion: v1
kind: ConfigMap
metadata:
  name: $DEPLOY-watch-config
  labels:
    app: sudo-letta
    agent: $NAME
data:
  config.json: |
    {
      "agent_name": "$NAME",
      "deploy_name": "$DEPLOY",
      "watch_port": $WATCH_PORT,
      "poll_interval_sec": 2,
      "log_dir": "/home/node/.letta/watch"
    }
---
apiVersion: v1
kind: Service
metadata:
  name: $DEPLOY-mcp
  labels:
    app: sudo-letta
    agent: $NAME
spec:
  type: ClusterIP
  selector:
    app: sudo-letta
    agent: $NAME
  ports:
  - name: mcp
    port: 8000
    targetPort: $MCP_PORT
---
# Observer sidecar Service: stable port 8000 -> per-agent WATCH_PORT
# (hostNetwork pods share the node's network namespace, so the sidecar itself
# listens on a unique per-agent port; the Service gives it a stable name).
apiVersion: v1
kind: Service
metadata:
  name: $DEPLOY-watch
  labels:
    app: sudo-letta
    agent: $NAME
spec:
  type: ClusterIP
  selector:
    app: sudo-letta
    agent: $NAME
  ports:
  - name: watch
    port: 8000
    targetPort: $WATCH_PORT
YAMLEOF

if [[ ! -s "$YAML" ]]; then
  echo "✗ Failed to write $YAML" >&2; exit 1
fi
echo "→ YAML written: $YAML"

# ── Import image into containerd ──
# The pod runs `sudo-letta:latest` with imagePullPolicy: IfNotPresent, so a
# silent import failure poisons the deploy: the pod comes up with a MISSING
# image and hits ImagePullBackOff / ErrImageNeverPull. Import must be LOUD and
# absence FATAL. No `sudo` (up.sh already runs as root via `$SUDO bash`) and no
# `2>/dev/null` swallowing the real error.
_ctr_images() {
  k3s ctr images ls -q 2>/dev/null || ctr -n k8s.io images ls -q 2>/dev/null || true
}

_image_present() {
  local img="$1" refs
  refs="$(_ctr_images)"
  grep -Fxq "$img" <<<"$refs" && return 0
  grep -Fxq "docker.io/library/$img" <<<"$refs" && return 0
  return 1
}

# _retry N "description" cmd [args...] — run cmd up to N times with backoff.
# The import can transiently fail (containerd busy during a concurrent import,
# a slow disk, a just-started k3s) — retry before declaring it fatal.
_retry() {
  local n="$1" desc="$2"; shift 2
  local i=1
  while (( i <= n )); do
    if "$@"; then return 0; fi
    echo "⚠ ($desc) attempt $i/$n failed — retrying in ${i}s..." >&2
    sleep "$i"
    (( i++ ))
  done
  return 1
}

_import_once() {
  local img="$1"
  docker save "$img" | k3s ctr image import - \
    || docker save "$img" | ctr -n k8s.io image import -
}

# _ensure_image_built IMG — build IMG from this factory's Dockerfile when it is
# missing. k8s-up.sh drives a DEPLOY, not a build, so a deploy whose image is
# absent used to hard-fail ("nothing to import. Build it first: bash setup.sh")
# and leave the operator to re-run a setup step mid-deploy. Build it HERE and
# fail ONLY if the build itself fails.
_ensure_image_built() {
  local img="$1"
  docker image inspect "$img" >/dev/null 2>&1 && return 0
  echo "→ docker image $img is missing locally — building it now..." >&2
  _retry 3 "docker build $img" docker build -t "$img" -f "$REPO_DIR/Dockerfile" "$REPO_DIR" || return 1
  docker image inspect "$img" >/dev/null 2>&1
}

_import_image() {
  local img="$1"
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    _ensure_image_built "$img" || {
      echo "✗ FATAL: docker image $img is missing and could not be built — nothing to import." >&2
      echo "  Build it manually:  bash setup.sh" >&2
      exit 1
    }
  fi
  _retry 3 "image import $img" _import_once "$img" \
    || echo "⚠ all image-import attempts reported failure for $img — verifying containerd..." >&2
  if ! _image_present "$img"; then
    echo "✗ FATAL: $img is NOT in containerd after import." >&2
    echo "  The pod would come up with a missing image (imagePullPolicy: IfNotPresent) and hit ImagePullBackOff." >&2
    echo "  Deploy aborted. Import manually or fix containerd, then re-run." >&2
    exit 1
  fi
  echo "→ $img present in containerd"
}

# Shared Redis for the prompt distributor queue (idempotent kubectl apply; LOUD on failure)
if ! kubectl apply -f "${SCRIPT_DIR}/redis.yaml" --validate=false; then
  echo "✗ FAILED to apply ${SCRIPT_DIR}/redis.yaml (shared Redis for the prompt distributor queue). Fix Redis provisioning before deploying agents. Deploy aborted." >&2
  exit 1
fi
echo "→ Shared Redis (redis.yaml) applied"
echo "→ Importing images..."
_import_image sudo-letta:latest

# ── Apply ──
echo "→ Deploying..."
if ! kubectl apply -f "$YAML" --validate=false; then
  echo "✗ kubectl apply failed. Check: kubectl cluster-info" >&2
  exit 1
fi

echo ""
echo "✓ $DEPLOY deployed"

# ── Wait for pod and configure Letta ──
echo "→ Waiting for pod to be ready..."
kubectl wait --for=condition=ready pod -l agent=$NAME --timeout=60s 2>/dev/null || true

echo "→ Configuring Letta provider..."
POD=$(kubectl get pods -l agent=$NAME -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$POD" ]]; then
  # ── Provider + model wiring (custom OpenAI-compatible endpoints) ──────────
  # `letta connect` only accepts the CLI's OWN provider names. A custom
  # OpenAI-compatible endpoint named in LLM_PROVIDER (e.g. "featherless") is NOT
  # one of them: verified live on the pinned letta-code 0.33.2,
  #   letta --backend local connect featherless --api-key ...
  #   -> "Unknown provider: featherless. Supported providers: ..."
  # so the connect silently failed and the deployed agent had no working model
  # ("No model selected") until it was hand-patched. The CLI's supported
  # provider for an arbitrary OpenAI-compatible endpoint is `openai-compatible`
  # (verified: `letta connect openai-compatible --base-url <url> --api-key <key>`
  # -> "Connected OpenAI-compatible API (openai-compatible) in local storage"),
  # and its models are then provider-qualified as
  # `openai-compatible/<model-id>` (e.g. openai-compatible/deepseek-ai/DeepSeek-V4-Pro).
  #
  # Strategy: try the configured provider first (a real built-in such as
  # deepseek / anthropic / openai / zai connects as-is, unchanged behaviour),
  # and fall back to `openai-compatible` ONLY when the CLI rejects the name.
  # Self-verifying — no hard-coded provider list to drift out of date.
  CONNECT_PROVIDER="${LLM_PROVIDER:-}"

  # ── Known-stale built-in provider: deepseek ────────────────────────────
  # letta-code's built-in `deepseek` provider ships a static catalog whose
  # upstream name for `deepseek-v4-pro` is the OLD string
  # "deepseek-ai/DeepSeek-V4-Pro". api.deepseek.com now rejects that and every
  # prompt dies with a 400:
  #   400: {"message":"The supported API model names are deepseek-flash,
  #         deepseek-v4-pro, but you passed deepseek-ai/DeepSeek-V4-Pro."}
  # (verified live, 2026-10-07: `deepseek/deepseek-v4-pro` and the bare id both
  # route through the stale catalog entry and 400). DeepSeek's API IS
  # OpenAI-compatible, and the `openai-compatible` provider passes the model id
  # through VERBATIM — so connecting it that way works and needs no catalog:
  #   letta connect openai-compatible --base-url https://api.deepseek.com/v1
  #   model = openai-compatible/deepseek-v4-pro   ->  "PONG" (verified live)
  # Only do this when a base URL was configured (a bare `deepseek` provider with
  # no endpoint keeps the built-in path). LLM_CONNECT_PROVIDER overrides either
  # way for an endpoint that really does need its own built-in provider.
  if [[ -n "${LLM_CONNECT_PROVIDER:-}" ]]; then
    CONNECT_PROVIDER="$LLM_CONNECT_PROVIDER"
    echo "→ provider overridden by LLM_CONNECT_PROVIDER=$CONNECT_PROVIDER"
  elif [[ "$CONNECT_PROVIDER" == "deepseek" && -n "${LLM_BASE_URL:-}" ]]; then
    echo "→ connecting deepseek's OpenAI-compatible API as 'openai-compatible' (letta's built-in deepseek catalog maps deepseek-v4-pro to the stale upstream name deepseek-ai/DeepSeek-V4-Pro, which the API now 400s)"
    CONNECT_PROVIDER="openai-compatible"
  fi

  _connect_letta() {  # $1 = provider name as `letta connect` should see it
    local cmd="letta --backend local connect $1 --api-key $API_KEY"
    [[ -n "${LLM_BASE_URL:-}" ]] && cmd="$cmd --base-url $LLM_BASE_URL"
    kubectl exec "$POD" -- bash -c "$cmd" 2>&1
  }

  CONNECT_OUT="$(_connect_letta "$CONNECT_PROVIDER" || true)"
  if printf '%s' "$CONNECT_OUT" | grep -qi 'unknown provider'; then
    echo "⚠ '$CONNECT_PROVIDER' is not a letta built-in provider — connecting the custom endpoint as 'openai-compatible' (${LLM_BASE_URL:-no base-url set})"
    CONNECT_PROVIDER="openai-compatible"
    CONNECT_OUT="$(_connect_letta "$CONNECT_PROVIDER" || true)"
  fi
  printf '%s\n' "$CONNECT_OUT" | tail -3
  printf '%s' "$CONNECT_OUT" | grep -qi 'connected' \
    || echo "⚠ Letta connect failed (may need manual config)"

  # ── Select the model (LLM_MODEL), when one is configured ─────────────────
  # `letta connect` wires the PROVIDER only; the agent's model stays whatever it
  # already was. The confirmed non-interactive selection command on letta-code
  # 0.33.2 is:
  #   letta --backend local model set <handle> [--agent <id>]
  # (from `letta model set` usage; verified live against a mock
  # OpenAI-compatible endpoint: it writes model +
  # model_settings.provider_type into the pod's agent record under
  # /home/node/.letta/lc-local-backend/agents/<base64-id>.json). The handle must
  # be provider-qualified — `letta model list --byok` prints the endpoint's exact
  # handles — so a bare LLM_MODEL gets the effective provider prefixed here.
  #
  # `model set` needs a TARGET agent (it errors with "Set AGENT_ID or pass
  # --agent/--conversation to select configuration" otherwise), so resolve the
  # pod's agent id from settings.json (same resolution as letta_prompt.py), then
  # fall back to `letta agents list`. A truly fresh PVC has no agent yet — the
  # first prompt creates it; the warning below says exactly what to run then.
  if [[ -n "${LLM_MODEL:-}" ]]; then
    case "$LLM_MODEL" in
      "$CONNECT_PROVIDER"/*) MODEL_HANDLE="$LLM_MODEL" ;;                       # already qualified
      *)                     MODEL_HANDLE="$CONNECT_PROVIDER/$LLM_MODEL" ;;     # bare id -> qualify
    esac

    AGENT_ID_RESOLVED="$(kubectl exec "$POD" -- bash -c 'python3 - << "PYEOF"
import json, sys
try:
    with open("/home/node/.letta/settings.json") as f:
        s = json.load(f)
except Exception:
    sys.exit(0)
last = s.get("lastAgent")
if isinstance(last, str) and last:
    print(last); sys.exit(0)
if isinstance(last, dict):
    for k in ("id", "agentId"):
        if last.get(k):
            print(last[k]); sys.exit(0)
for r in s.get("agents") or []:
    if isinstance(r, dict) and (r.get("memfs") is True or r.get("pinned") is True):
        for k in ("id", "agentId"):
            if r.get(k):
                print(r[k]); sys.exit(0)
PYEOF' 2>/dev/null | tr -d '\r' | tail -1)"

    if [[ -z "$AGENT_ID_RESOLVED" ]]; then
      # No agent record in settings.json yet (fresh PVC) — ask the CLI itself.
      AGENT_ID_RESOLVED="$(kubectl exec "$POD" -- bash -c 'letta --backend local agents list 2>/dev/null' 2>/dev/null \
        | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
        | sed 's/.*"\([^"]*\)"$/\1/')"
    fi

    # `letta model set` qualifies its argument with the CONNECTED provider
    # itself. Passing the already-qualified handle therefore double-prefixes it
    # ("deepseek/deepseek/deepseek-v4-pro") and every prompt then dies with:
    #   Unknown model "deepseek/deepseek/deepseek-v4-pro" for provider "deepseek"
    # (verified live on a fresh box, 2026-10-07). So pass the BARE model id
    # first — letta prefixes the provider — and fall back to the
    # provider-qualified handle only for an endpoint whose reported id is not
    # the same string as the handle.
    _mset() {
      if [[ -n "$AGENT_ID_RESOLVED" ]]; then
        kubectl exec "$POD" -- bash -c "letta --backend local model set '$1' --agent '$AGENT_ID_RESOLVED'" 2>&1 || true
      else
        kubectl exec "$POD" -- bash -c "letta --backend local model set '$1'" 2>&1 || true
      fi
    }
    echo "→ Selecting model '$LLM_MODEL' (bare id; letta qualifies it) for agent ${AGENT_ID_RESOLVED:-<none yet>}..."
    MODEL_SET_OUT="$(_mset "$LLM_MODEL")"
    printf '%s\n' "$MODEL_SET_OUT" | tail -3
    if ! printf '%s' "$MODEL_SET_OUT" | grep -q '"model"'; then
      echo "→ retrying with the provider-qualified handle '$MODEL_HANDLE'..."
      MODEL_SET_OUT="$(_mset "$MODEL_HANDLE")"
      printf '%s\n' "$MODEL_SET_OUT" | tail -3
    fi
    unset -f _mset

    if [[ -z "$AGENT_ID_RESOLVED" ]]; then
      echo "⚠ No agent exists in the pod yet, so LLM_MODEL could not be pinned. After the"
      echo "  first prompt creates it, run:  kubectl exec $POD -- letta --backend local model set '$LLM_MODEL' --agent <agent-id>"
    elif ! printf '%s' "$MODEL_SET_OUT" | grep -q '"model"'; then
      echo "⚠ Model selection did not confirm — check: kubectl exec $POD -- letta --backend local model list --byok"
    fi

    # ── Normalize the record's model handle ────────────────────────────────
    # Belt and braces: whatever `model set` wrote, the agent RECORD is the
    # source of truth, and a handle that repeats the provider
    # ("prov/prov/id") is never valid. Collapse it (fixing an already-broken
    # PVC from a previous deploy too) and report the final value.
    NORM_OUT="$(kubectl exec -i "$POD" -c sudo-letta -- python3 - "$CONNECT_PROVIDER" "$MODEL_HANDLE" <<'PYNORM' 2>&1 || true
import glob, json, os, sys
prov, handle = sys.argv[1], sys.argv[2]
bad_prefix = prov + "/" + prov + "/"
for p in sorted(glob.glob("/home/node/.letta/lc-local-backend/agents/*.json")):
    try:
        d = json.load(open(p))
    except Exception as e:
        print("skip", p, e); continue
    m = d.get("model") or ""
    fixed = m
    # collapse prov/prov/... -> prov/...  (however many times it repeats)
    while fixed.startswith(bad_prefix):
        fixed = fixed[len(prov) + 1:]
    if not fixed or fixed.count("/") == 0:
        fixed = handle
    ms = d.setdefault("model_settings", {})
    changed = fixed != m or ms.get("provider_type") != prov
    d["model"] = fixed
    ms["provider_type"] = prov
    if changed:
        tmp = p + ".tmp"
        with open(tmp, "w") as f:
            json.dump(d, f, indent=2); f.write("\n")
        os.replace(tmp, p)
    print(("normalized " if changed else "ok         "), os.path.basename(p), "model=", fixed, "provider_type=", ms.get("provider_type"))
PYNORM
)"
    printf '%s\n' "$NORM_OUT" | tail -3
  fi

  # Create settings with permissions
  kubectl exec "$POD" -- bash -c '
    SETTINGS_FILE="/home/node/.letta/settings.json"
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    if [ ! -f "$SETTINGS_FILE" ] || [ ! -s "$SETTINGS_FILE" ]; then
      cat > "$SETTINGS_FILE" << "SETTINGS"
{
  "tokenStreaming": true,
  "preferredBackendMode": "local",
  "globalSharedBlockIds": {},
  "permissions": {
    "bash": "allow",
    "read": "allow",
    "write": "allow"
  }
}
SETTINGS
      chown node:node "$SETTINGS_FILE"
    fi
  ' 2>/dev/null || true

  # Agent-record hygiene: strip GHOST agent records (memfs:false, unpinned
  # duplicates left by historical CLI runs). When a session binds to a ghost,
  # the official web-search mod's tools never attach -> agent reports no
  # web_search. Runs on EVERY up.sh (create + recreate). Never bricks the
  # agent: parse failure leaves settings.json untouched; sessionsByServer
  # and all other keys are preserved verbatim; backup written to .bak-ghosts.
  kubectl exec "$POD" -- bash -c 'python3 - << "PYEOF"
import json, shutil, os, sys

path = "/home/node/.letta/settings.json"

try:
    with open(path) as f:
        data = json.load(f)
except Exception as exc:
    print("ghost-hygiene: parse failed, settings.json left untouched (%s)" % exc)
    sys.exit(0)

agents = data.get("agents") or []
if not agents:
    sys.exit(0)

def is_pinned(rec):
    return isinstance(rec, dict) and (rec.get("memfs") is True or rec.get("pinned") is True)

keep = [a for a in agents if is_pinned(a)]
removed = len(agents) - len(keep)

if removed and not keep:
    print("ghost-hygiene: WARNING no pinned (memfs) record found — leaving settings.json untouched")
    sys.exit(0)

if removed:
    shutil.copy2(path, path + ".bak-ghosts")
    data["agents"] = keep
    last = data.get("lastAgent")
    last_id = last if isinstance(last, str) else (last.get("id") if isinstance(last, dict) else None)
    keep_ids = {a.get("id") for a in keep}
    if last_id is not None and last_id not in keep_ids and keep[0].get("id") is not None:
        data["lastAgent"] = keep[0]["id"]
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)
    print("ghost-hygiene: removed %d ghost agent record(s), kept %d pinned" % (removed, len(keep)))
PYEOF' || true

  # Official mod set: install EVERY standard mod, pinned to EXACT versions,
  # idempotently, on EVERY deploy. The image pre-installs web-search, but a
  # fresh PVC shadows /home/node/.letta — brand-new agents deploy WITHOUT the
  # mods unless we install them here. Exact-version check per mod: a missing
  # or WRONG version forces reinstall. LOUD failure: any install or verify
  # failure aborts the deploy (the agent would silently lack tools).
  #
  # Standard set + versions (mirrors ya-glm-l's verified ~/.letta/mods):
  #   npm:@letta-ai/web-search@0.1.0        (tool: web_search)
  #   npm:@letta-ai/memfs-search@0.1.1
  #   npm:@letta-ai/plan-mode@0.1.1
  #   npm:@letta-ai/image-understanding@0.1.0
  # Official npm mods (published to the npm registry): the install specifier and
  # the verify string are the same `npm:<name>@<version>`.
  NPM_MODS=(
    "npm:@letta-ai/web-search@0.1.0"
    "npm:@letta-ai/memfs-search@0.1.1"
    "npm:@letta-ai/plan-mode@0.1.1"
    "npm:@letta-ai/image-understanding@0.1.0"
  )

  # Comm-layer mods (list-siblings / message-agent / check-agent). NOT on the
  # public npm registry: they ship as local packages in this repo's mods/ dir,
  # are copied into the pod at deploy time, and installed via `letta install
  # <path>`. letta records a local install's source as `npm:<name>` (from
  # package.json "name") and its version from package.json "version", so
  # `mods list` renders exactly `npm:<name>@<version>` — the SAME exact-version
  # check the npm mods use. Each entry is "<local-package-dir>|<verify-string>".
  # Canonical source + packaging spec: sudo-fleet/docs/comm-mods-PACKAGING.md.
  COMM_MODS=(
    "mods/list-siblings|npm:@letta-ai/list-siblings@0.2.0"
    "mods/check-agent|npm:@letta-ai/check-agent@0.2.0"
    "mods/message-agent|npm:@letta-ai/message-agent@0.2.0"
    "mods/keyboard-mac|npm:@letta-ai/keyboard-mac@0.1.0"
  )

  LETTA_JS="/usr/local/lib/node_modules/@letta-ai/letta-code/letta.js"

  # Ship the comm mod packages into the pod once (the pod cannot see the host's
  # repo). Idempotent: re-copied every deploy, installed only if missing/wrong.
  if [[ ! -d "$REPO_DIR/mods" ]]; then
    echo "✗ FATAL: $REPO_DIR/mods missing — comm mods cannot be installed; aborting deploy" >&2
    exit 1
  fi
  kubectl exec "$POD" -- bash -c "rm -rf /tmp/letta-mods; mkdir -p /tmp/letta-mods" 2>/dev/null || true
  if ! kubectl cp "$REPO_DIR/mods/." "$POD:/tmp/letta-mods/"; then
    echo "✗ FATAL: could not copy comm mods into pod — aborting deploy" >&2
    exit 1
  fi

  for _entry in "${NPM_MODS[@]}" "${COMM_MODS[@]}"; do
    _spec="${_entry%%|*}"
    _verify="${_entry##*|}"
    # comm mods live under mods/ on the host -> /tmp/letta-mods/ in the pod
    [[ "$_spec" == mods/* ]] && _spec="/tmp/letta-mods/${_spec#mods/}"
    if ! kubectl exec "$POD" -- bash -c "HOME=/home/node node $LETTA_JS mods list" 2>&1 \
        | grep -Fq "$_verify"; then
      echo "→ installing mod $_verify (missing or wrong version)"
      if ! kubectl exec "$POD" -- bash -c "HOME=/home/node node $LETTA_JS install '$_spec'" 2>&1; then
        echo "✗ FATAL: mod install failed: $_verify — agent will lack its tools; aborting deploy" >&2
        exit 1
      fi
    fi
  done
  # Verify: every mod must now list at its exact pinned version.
  _modlist=$(kubectl exec "$POD" -- bash -c "HOME=/home/node node $LETTA_JS mods list" 2>&1) || {
    echo "✗ FATAL: could not read mods list from pod — aborting deploy" >&2; exit 1; }
  for _entry in "${NPM_MODS[@]}" "${COMM_MODS[@]}"; do
    _verify="${_entry##*|}"
    echo "$_modlist" | grep -Fq "$_verify" || {
      echo "✗ FATAL: mod not present after install: $_verify — aborting deploy" >&2; exit 1; }
  done
  echo "→ mod set verified: ${NPM_MODS[*]} ${COMM_MODS[*]}"
  unset _entry _spec _verify _modlist NPM_MODS COMM_MODS LETTA_JS

  # Comm-layer skills (list-siblings / message-agent / check-agent). The mods
  # above register the TOOLS into the agent's tool schema; these are the
  # per-agent MemFS procedure docs that make the agent actually reach for them.
  # They ship as first-class files in this repo's factories/sudo-letta/skills/
  # dir (the canonical source on main), and are copied into the pod at deploy
  # time exactly like mods/, and dropped into the agent's MemFS skills/
  # dir — the dir Letta auto-loads skills from, and the same dir the
  # --from-glimor seed populates from the glimor. Idempotent: re-copied every
  # deploy, and the MemFS is git-committed so the seeded skills actually load
  # (an uncommitted MemFS is silently ignored — the same reason the glimor seed
  # initContainer commits). On a brand-new no-glimor deploy the MemFS does not
  # exist until the agent is first created, so a missing dir is a WARN here, not
  # a fatal (the skills land on the next deploy or the first --from-glimor fork).
  # NOTE: this repo's skills/ dir also carries a top-level README.md (repo docs).
  # It MUST NOT be copied into the MemFS skills/ dir: the MemFS pre-commit hook
  # rejects a bare file under skills/ ("skills must be folders") and silently
  # aborts the git commit, leaving the skills + persona uncommitted (lost on
  # glimor save). So the copy below uses the `*/` glob to take ONLY the skill
  # subdirectories, never the loose files.
  if [[ ! -d "$REPO_DIR/skills" ]]; then
    echo "✗ FATAL: $REPO_DIR/skills missing — comm skills cannot be seeded; aborting deploy" >&2
    exit 1
  fi
  kubectl exec "$POD" -- bash -c "rm -rf /tmp/comm-skills; mkdir -p /tmp/comm-skills" 2>/dev/null || true
  if ! kubectl cp "$REPO_DIR/skills/." "$POD:/tmp/comm-skills/"; then
    echo "✗ FATAL: could not copy comm skills into pod — aborting deploy" >&2
    exit 1
  fi
  _memfs_memory="$(kubectl exec "$POD" -- bash -c 'for d in /home/node/.letta/lc-local-backend/memfs/*/memory; do [ -d "$d" ] && { echo "$d"; break; }; done' 2>/dev/null)"
  if [[ -n "$_memfs_memory" ]]; then
    if ! kubectl exec "$POD" -- bash -c "mkdir -p '$_memfs_memory/skills' && cp -a /tmp/comm-skills/*/ '$_memfs_memory/skills/' && chown -R node:node '$_memfs_memory/skills'"; then
      echo "✗ FATAL: could not seed comm skills into agent MemFS — aborting deploy" >&2
      exit 1
    fi
    # Commit the MemFS so the seeded skills load (best-effort: a no-op commit on
    # an already-clean tree is fine, and never a reason to fail the deploy).
    kubectl exec "$POD" -- bash -c "git -C '$_memfs_memory' init -q -b main 2>/dev/null; git -C '$_memfs_memory' add -A 2>/dev/null && git -C '$_memfs_memory' -c user.email=factory@localhost -c user.name=factory commit -q -m 'seed comm skills' >/dev/null 2>&1 || true"
    echo "→ comm skills seeded into agent MemFS: list-siblings message-agent check-agent"
  else
    echo "⚠ no MemFS memory dir found (agent not created yet) — comm skills will land on the next deploy or the first --from-glimor fork" >&2
  fi

  # Fleet-comm awareness: the shared persona snippet, applied as a
  # factory-managed block (fixed BEGIN/END markers) to the agent's
  # system/persona.md on EVERY deploy — the SAME snippet (byte-identical) the
  # Hermes sudo-agent side bakes into its image and applies to SOUL.md. The
  # snippet is the ONE shared source at factories/sudo-agent/comm/
  # PERSONA-SNIPPET.md, copied into the pod here exactly like mods/ and
  # skills/. It is ALSO persisted to the PVC (not /tmp) so the boot-time
  # entrypoint can re-apply the same block on a plain restart. Idempotent:
  # replaces the content between the markers in place, or appends the block if
  # absent; never touches anything outside the markers. The MemFS is
  # git-committed after the write (an uncommitted MemFS is silently ignored —
  # the same reason the glimor seed initContainer and the skills seed above
  # commit). A missing MemFS is a WARN, not a fatal (the same brand-new
  # no-glimor case as the skills seed).
  _fc_snippet="$REPO_DIR/../sudo-agent/comm/PERSONA-SNIPPET.md"
  _fc_pod_snippet="/home/node/.letta/fleet-comm-snippet.md"
  if [[ ! -f "$_fc_snippet" ]]; then
    echo "✗ FATAL: shared fleet-comm snippet missing at $_fc_snippet — aborting deploy" >&2
    exit 1
  fi
  kubectl exec "$POD" -- bash -c "rm -f '$_fc_pod_snippet'" 2>/dev/null || true
  if ! kubectl cp "$_fc_snippet" "$POD:$_fc_pod_snippet"; then
    echo "✗ FATAL: could not copy fleet-comm snippet into pod — aborting deploy" >&2
    exit 1
  fi
  if [[ -n "$_memfs_memory" ]]; then
    kubectl exec -i "$POD" -- bash -s -- "$_memfs_memory" <<'FLEETBLOCK'
_memfs_memory="$1"
_persona="$_memfs_memory/system/persona.md"
_snippet="/home/node/.letta/fleet-comm-snippet.md"
_begin='<!-- FLEET-COMM-AWARENESS-BEGIN -->'
_end='<!-- FLEET-COMM-AWARENESS-END -->'
if [ -f "$_persona" ] && [ -f "$_snippet" ]; then
  if ! grep -qF "$_begin" "$_persona" || ! grep -qF "$_end" "$_persona"; then
    { printf '\n'; printf '%s\n' "$_begin"; cat "$_snippet"; printf '%s\n' "$_end"; } >> "$_persona"
  else
    awk -v b="$_begin" -v e="$_end" -v s="$_snippet" '
      $0 == b { print; skip=1; emitted=0; next }
      $0 == e { print; skip=0; next }
      skip { if (!emitted) { while ((getline l < s) > 0) print l; close(s); emitted=1 } next }
      { print }
    ' "$_persona" > "$_persona.tmp" && mv "$_persona.tmp" "$_persona"
  fi
  chown node:node "$_persona" 2>/dev/null || true
fi
git -C "$_memfs_memory" init -q -b main 2>/dev/null
git -C "$_memfs_memory" add -A 2>/dev/null && git -C "$_memfs_memory" -c user.email=factory@localhost -c user.name=factory commit -q -m 'seed fleet-comm persona' >/dev/null 2>&1 || true
FLEETBLOCK
    echo "→ fleet-comm persona block seeded into agent MemFS"
  else
    echo "⚠ no MemFS memory dir found (agent not created yet) — fleet-comm persona will land on the next deploy" >&2
  fi
  unset _fc_snippet _fc_pod_snippet

  unset _memfs_memory

  echo "→ Letta configured"
fi
# ── Paperclip auto-hire ──────────────────────────────────────────────────────
# Standing an agent up ALSO hires it. sudo-fleet ships with Paperclip (the
# control plane), and an agent that exists in the cluster but not in Paperclip
# is a wiring bug — so the hire happens here, automatically, right after the
# deployment is Ready. Non-fatal on purpose: a fleet without the control plane
# still deploys, and bin/paperclip-adopt.sh (also run on every boot, and at the
# end of bin/k8s-up.sh) reconciles anything that was missed.
_FLEET_HOME="$(cd "$REPO_DIR/../.." && pwd)"
if [[ -x "$_FLEET_HOME/bin/paperclip-hire.sh" && -f /logs/paperclip/paperclip.env ]]; then
  echo ""
  echo "→ hiring $DEPLOY in Paperclip (auto-hire)"
  bash "$_FLEET_HOME/bin/paperclip-hire.sh" --name "${NAME^}" --deploy "$DEPLOY" \
    || echo "⚠ Paperclip auto-hire failed for $DEPLOY (non-fatal; run bin/paperclip-adopt.sh)" >&2
fi
unset _FLEET_HOME

echo "  Talk:   kubectl exec -it deploy/$DEPLOY -- bash -c 'letta'"
echo "  Shell:  kubectl exec -it deploy/$DEPLOY -- bash"
echo "  MCP:    http://$DEPLOY-mcp:8000/mcp"
echo "  Watch:  http://$DEPLOY-watch:8000/status  (also /ps /events /stream /healthz)"
echo "  Logs:   kubectl logs deploy/$DEPLOY -f"
echo "  Stop:   bash bin/down.sh --$NAME"
