#!/usr/bin/env bash
# sudo-gmail-mcp — fleet-shared Gmail MCP service (Gmail REST API, multi-account).
#
# Idempotent deploy: build the image (or reuse a cached one), import it into
# k3s/containerd, reuse the fleet's existing Google OAuth secret, apply the
# PVC/Service/Deployment, and wait for /health.
#
# The service is reachable at:
#   - ClusterIP  sudo-gmail-mcp:8000  (agents, via the fleet -mcp convention)
#   - host LAN   http://192.168.5.15:24659/mcp  (baked fleet address)
#
# OAuth client creds are REUSED from the fleet secret `sudo-gws-oauth` (the
# same Google OAuth client already consented for aidanmcohen@gmail.com). This
# deployment does NOT create a new client — it adds the gmail service surface
# on top of the existing client, and each additional account is consented once
# against the same client via `kube-scripts/consent.py`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORY_DIR="$(dirname "$SCRIPT_DIR")"
MANIFESTS="$FACTORY_DIR/manifests"

NAME="gmail"
DEPLOY="sudo-gmail-mcp"
NAMESPACE="default"
MCP_PORT=24659                      # 8000 + cksum("gmail") % 22000 (fleet convention)
IMAGE="sudo-gmail-mcp:latest"
SECRET="sudo-gws-oauth"             # REUSED fleet Google OAuth client (never committed)

# Auto-detect kubeconfig (sudo changes HOME, kubectl can lose it).
if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"; do
    if [[ -f "$cfg" ]]; then export KUBECONFIG="$cfg"; break; fi
  done
fi
if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "✗ No kubeconfig found. Is k3s running? Try: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >&2
  exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "✗ kubectl is required." >&2; exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "✗ docker is required to build the image." >&2; exit 1
fi

echo "→ sudo-gmail-mcp deploy: image=$IMAGE port=$MCP_PORT namespace=$NAMESPACE"

# ── Build + import the image ────────────────────────────────────────────────
# The Dockerfile is the same workspace-mcp recipe as sudo-gws, so the layers
# are cached and this is cheap after the first build. Rebuild unconditionally
# to guarantee the image matches the Dockerfile.
echo "→ building $IMAGE from $FACTORY_DIR/Dockerfile ..."
docker build -t "$IMAGE" "$FACTORY_DIR"

echo "→ importing $IMAGE into k3s/containerd ..."
docker save "$IMAGE" | k3s ctr images import - >/dev/null 2>&1 || {
  echo "⚠ k3s ctr images import failed; trying sudo fallback" >&2
  docker save "$IMAGE" | sudo k3s ctr images import - >/dev/null
}
echo "→ image imported."

# ── OAuth secret (reused, never committed) ──────────────────────────────────
if kubectl get secret "$SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "→ reusing existing secret $SECRET (fleet Google OAuth client)"
else
  echo "✗ secret $SECRET does not exist. Deploy sudo-gws first (it creates the"
  echo "  fleet Google OAuth client), or create it manually." >&2
  exit 1
fi

# ── Apply manifests (idempotent) ────────────────────────────────────────────
echo "→ applying PVC / Service / Deployment ..."
kubectl apply -f "$MANIFESTS/pvc.yaml"
kubectl apply -f "$MANIFESTS/service.yaml"
kubectl apply -f "$MANIFESTS/deployment.yaml"

# ── Wait for readiness ──────────────────────────────────────────────────────
echo "→ waiting for $DEPLOY to become Ready ..."
kubectl rollout status "deploy/$DEPLOY" -n "$NAMESPACE" --timeout=180s

echo "→ verifying /health on hostNetwork port $MCP_PORT ..."
if curl -fsS --max-time 10 "http://127.0.0.1:$MCP_PORT/health"; then
  echo
  echo "✓ sudo-gmail-mcp is Ready and /health answers on :$MCP_PORT"
else
  echo "⚠ /health did not answer on :$MCP_PORT; check: kubectl -n $NAMESPACE logs deploy/$DEPLOY" >&2
fi

echo
echo "sudo-gmail-mcp up."
echo "  MCP:     http://sudo-gmail-mcp:8000/mcp  (ClusterIP, fleet convention)"
echo "  MCP:     http://192.168.5.15:$MCP_PORT/mcp  (host LAN, baked fleet address)"
echo "  Health:  http://192.168.5.15:$MCP_PORT/health"
echo "  Consent: python3 factories/sudo-gmail-mcp/kube-scripts/consent.py --account <email>"
