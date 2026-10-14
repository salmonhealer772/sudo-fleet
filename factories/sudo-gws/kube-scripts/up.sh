#!/usr/bin/env bash
# sudo-gws — fleet-shared Google Workspace MCP service (Drive + Docs + Sheets).
#
# Idempotent deploy: build the image (or reuse a cached one), import it into
# k3s/containerd, create the OAuth secret, apply the PVC/Service/Deployment,
# and wait for /health. The service is then reachable at:
#   - ClusterIP  sudo-gws-mcp:8000  (agents, via the fleet -mcp convention)
#   - host LAN   http://192.0.2.15:27462/mcp  (baked fleet address)
#
# OAuth client creds come from the ENV (never committed): GWS_CLIENT_ID and
# GWS_CLIENT_SECRET. If unset, the secret is created with empty values so the
# pod still runs (unconfigured) — tools/list works, tools/call returns the
# "ACTION REQUIRED: authorization URL" flow that the operator completes once.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORY_DIR="$(dirname "$SCRIPT_DIR")"
MANIFESTS="$FACTORY_DIR/manifests"

NAME="gws"
DEPLOY="sudo-gws"
NAMESPACE="default"
MCP_PORT=27462                      # 8000 + cksum("gws") % 22000 (fleet convention)
IMAGE="sudo-gws:latest"
SECRET="sudo-gws-oauth"

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

echo "→ sudo-gws deploy: image=$IMAGE port=$MCP_PORT namespace=$NAMESPACE"

# ── Build + import the image ────────────────────────────────────────────────
# Always rebuild: docker layer caching makes this cheap after the first build,
# and it guarantees the image matches the Dockerfile (no stale-image class of
# bug). docker save | k3s ctr images import is best-effort, so we import
# unconditionally after every build.
echo "→ building $IMAGE from $FACTORY_DIR/Dockerfile ..."
docker build -t "$IMAGE" "$FACTORY_DIR"

echo "→ importing $IMAGE into k3s/containerd ..."
docker save "$IMAGE" | k3s ctr images import - >/dev/null 2>&1 || {
  echo "⚠ k3s ctr images import failed; trying sudo fallback" >&2
  docker save "$IMAGE" | sudo k3s ctr images import - >/dev/null
}
echo "→ image imported."

# ── OAuth secret (never committed) ──────────────────────────────────────────
GWS_CLIENT_ID="${GWS_CLIENT_ID:-}"
GWS_CLIENT_SECRET="${GWS_CLIENT_SECRET:-}"
if kubectl get secret "$SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "→ secret $SECRET already exists (left untouched)"
else
  if [[ -n "$GWS_CLIENT_ID" && -n "$GWS_CLIENT_SECRET" ]]; then
    echo "→ creating secret $SECRET from GWS_CLIENT_ID / GWS_CLIENT_SECRET env"
    kubectl create secret generic "$SECRET" -n "$NAMESPACE" \
      --from-literal=client-id="$GWS_CLIENT_ID" \
      --from-literal=client-secret="$GWS_CLIENT_SECRET"
  else
    echo "⚠ GWS_CLIENT_ID / GWS_CLIENT_SECRET unset — creating EMPTY secret $SECRET"
    echo "  (the pod runs unconfigured; OAuth consent is gated on the operator's client)."
    kubectl create secret generic "$SECRET" -n "$NAMESPACE" \
      --from-literal=client-id="" \
      --from-literal=client-secret=""
  fi
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
  echo "✓ sudo-gws is Ready and /health answers on :$MCP_PORT"
else
  echo "⚠ /health did not answer on :$MCP_PORT; check: kubectl -n $NAMESPACE logs deploy/$DEPLOY" >&2
fi

echo
echo "sudo-gws up."
echo "  MCP:     http://sudo-gws-mcp:8000/mcp  (ClusterIP, fleet convention)"
echo "  MCP:     http://192.0.2.15:$MCP_PORT/mcp  (host LAN, baked fleet address)"
echo "  Health:  http://192.0.2.15:$MCP_PORT/health"
echo "  OAuth:   see factories/sudo-gws/oauth-clickpath.md (redirect URI + scopes)"
