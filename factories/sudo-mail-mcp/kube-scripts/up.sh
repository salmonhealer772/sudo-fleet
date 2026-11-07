#!/usr/bin/env bash
# sudo-mail-mcp — fleet-shared IMAP/SMTP email MCP server (OAuth2/XOAUTH2).
#
# Idempotent deploy: build the image, import into k3s/containerd, generate the
# config.toml from the operator's EXISTING ortie OAuth refresh tokens, store it
# in a k8s Secret (never in git), then apply PVC/Service/Deployment and wait.
#
#   - ClusterIP  sudo-mail-mcp:8000  (fleet -mcp convention)
#   - host LAN   http://192.168.5.15:29543/mcp  (baked fleet address)
#
# Env overrides:
#   MAIL_MCP_CONFIG_FILE  path to a ready config.toml (skip Mac token pull)
#   MAIL_MCP_TOKEN_DIR    dir holding the ortie token JSONs (skip Mac pull)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORY_DIR="$(dirname "$SCRIPT_DIR")"
MANIFESTS="$FACTORY_DIR/manifests"

NAME="mail"
DEPLOY="sudo-mail-mcp"
NAMESPACE="default"
MCP_PORT=29543                      # 8000 + cksum("mail") % 22000 (fleet convention)
IMAGE="sudo-mail-mcp:latest"
SECRET="sudo-mail-mcp-config"
MAC_HOST="aidanmcohen@192.168.5.2"
MAC_TOKENS="~/.config/ortie/tokens"
MAC_ACCOUNTS="aidan aidan77223 aidansteam77223 sbaco neu"

if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"; do
    [[ -f "$cfg" ]] && export KUBECONFIG="$cfg" && break
  done
fi
[[ -z "${KUBECONFIG:-}" ]] && { echo "✗ no kubeconfig" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "✗ kubectl required" >&2; exit 1; }
command -v docker  >/dev/null 2>&1 || { echo "✗ docker required" >&2; exit 1; }

echo "→ sudo-mail-mcp deploy: image=$IMAGE port=$MCP_PORT"

echo "→ building $IMAGE ..."
docker build -t "$IMAGE" "$FACTORY_DIR"

echo "→ importing into k3s/containerd ..."
docker save "$IMAGE" | k3s ctr images import - >/dev/null 2>&1 || \
  docker save "$IMAGE" | sudo -S -p '' k3s ctr images import - >/dev/null

# ── config.toml (secrets) ──────────────────────────────────────────────────
CFG=""
if [[ -n "${MAIL_MCP_CONFIG_FILE:-}" && -f "$MAIL_MCP_CONFIG_FILE" ]]; then
  CFG="$MAIL_MCP_CONFIG_FILE"
else
  TMPD="$(mktemp -d)"
  if [[ -n "${MAIL_MCP_TOKEN_DIR:-}" && -d "$MAIL_MCP_TOKEN_DIR" ]]; then
    cp "$MAIL_MCP_TOKEN_DIR"/*.json "$TMPD/" 2>/dev/null || true
  else
    echo "→ pulling ortie tokens from the Mac ($MAC_HOST) ..."
    for a in $MAC_ACCOUNTS; do
      ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$MAC_HOST" \
        "cat $MAC_TOKENS/$a.json" > "$TMPD/$a.json"
    done
  fi
  chmod 600 "$TMPD"/*.json
  python3 "$SCRIPT_DIR/gen-config.py" "$TMPD" "$TMPD/config.toml"
  CFG="$TMPD/config.toml"
fi

if kubectl get secret "$SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  kubectl delete secret "$SECRET" -n "$NAMESPACE" >/dev/null
fi
echo "→ creating secret $SECRET from $CFG"
kubectl create secret generic "$SECRET" -n "$NAMESPACE" --from-file=config.toml="$CFG"

echo "→ applying PVC / Service / Deployment ..."
kubectl apply -f "$MANIFESTS/pvc.yaml"
kubectl apply -f "$MANIFESTS/service.yaml"
kubectl apply -f "$MANIFESTS/deployment.yaml"

echo "→ waiting for $DEPLOY to become Ready ..."
kubectl rollout status "deploy/$DEPLOY" -n "$NAMESPACE" --timeout=180s

echo "→ probing :$MCP_PORT (tcp) ..."
if kubectl exec "deploy/$DEPLOY" -n "$NAMESPACE" -- \
    sh -c "command -v node >/dev/null && node -e \"require('net').createConnection($MCP_PORT,'127.0.0.1').on('connect',()=>process.exit(0)).on('error',()=>process.exit(1))\"" 2>/dev/null; then
  echo "✓ sudo-mail-mcp Ready, MCP port answers."
else
  echo "⚠ MCP port probe failed; check: kubectl -n $NAMESPACE logs deploy/$DEPLOY"
fi

echo
echo "sudo-mail-mcp up."
echo "  MCP: http://sudo-mail-mcp:8000/mcp  (ClusterIP)"
echo "  MCP: http://192.168.5.15:$MCP_PORT/mcp  (host LAN)"
