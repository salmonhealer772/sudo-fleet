#!/usr/bin/env bash
# sudo-upwork-mcp — fleet-shared Upwork MCP gateway.
#
# Idempotent deploy: build the image, import it into k3s/containerd, apply the
# PVC/Service/Deployment, and wait for /health. The one-time OAuth authorize
# step is separate (see README + kube-scripts/consent.py).
#
# Reachable at:
#   - ClusterIP  http://sudo-upwork-mcp:8000/mcp   (agents, fleet convention)
#   - host LAN   http://192.168.5.15:9232/mcp      (baked fleet address)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_DIR="$(dirname "$SCRIPT_DIR")"                # mcp/upwork/
MANIFESTS="$GATEWAY_DIR/k8s"

NAME="upwork"
DEPLOY="sudo-upwork-mcp"
NAMESPACE="default"
MCP_PORT=9232                      # 8000 + cksum("upwork") % 22000 (fleet convention)
IMAGE="sudo-upwork-mcp:latest"

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
for bin in kubectl docker; do
  command -v "$bin" >/dev/null 2>&1 || { echo "✗ $bin is required." >&2; exit 1; }
done

echo "→ sudo-upwork-mcp deploy: image=$IMAGE port=$MCP_PORT namespace=$NAMESPACE"

# ── Build + import the image ────────────────────────────────────────────────
echo "→ building $IMAGE from $GATEWAY_DIR/gateway/Dockerfile ..."
docker build -t "$IMAGE" "$GATEWAY_DIR/gateway"

echo "→ importing $IMAGE into k3s/containerd ..."
docker save "$IMAGE" | k3s ctr images import - >/dev/null 2>&1 || {
  echo "⚠ k3s ctr images import failed; trying sudo fallback" >&2
  docker save "$IMAGE" | sudo k3s ctr images import - >/dev/null
}
echo "→ image imported."

# ── Apply manifests (idempotent) ────────────────────────────────────────────
echo "→ applying PVC / Service / Deployment ..."
kubectl apply -f "$MANIFESTS/pvc.yaml"
kubectl apply -f "$MANIFESTS/service.yaml"
kubectl apply -f "$MANIFESTS/deployment.yaml"

echo "→ waiting for $DEPLOY to become Ready ..."
kubectl rollout status "deploy/$DEPLOY" -n "$NAMESPACE" --timeout=180s

echo "→ verifying /health on hostNetwork port $MCP_PORT ..."
if curl -fsS --max-time 10 "http://127.0.0.1:$MCP_PORT/health"; then
  echo
  echo "✓ sudo-upwork-mcp is Ready and /health answers on :$MCP_PORT"
else
  echo "⚠ /health did not answer on :$MCP_PORT; check: kubectl -n $NAMESPACE logs deploy/$DEPLOY" >&2
fi

echo
echo "sudo-upwork-mcp up."
echo "  MCP:       http://sudo-upwork-mcp:8000/mcp   (ClusterIP, fleet convention)"
echo "  MCP:       http://192.168.5.15:$MCP_PORT/mcp  (host LAN, baked fleet address)"
echo "  Health:    http://192.168.5.15:$MCP_PORT/health"
echo "  Authorize: python3 kube-scripts/consent.py   (operator's Mac, one-time)"
