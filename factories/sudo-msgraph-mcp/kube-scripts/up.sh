#!/usr/bin/env bash
# sudo-msgraph-mcp — fleet-shared Microsoft Graph MCP service (Outlook Mail).
#
# Idempotent deploy: build the image, import it into k3s/containerd, create the
# (placeholder) client-id secret, apply PVC/Service/Deployment, wait for Ready.
#
#   - ClusterIP  sudo-msgraph-mcp:8000  (agents, fleet -mcp convention)
#   - host LAN   http://192.168.5.15:12420/mcp  (baked fleet address)
#
# OAuth: device-code flow. The client id (MICROSOFT_MCP_CLIENT_ID) must be an
# Entra ID app registration with delegated Graph Mail.Read / Mail.Send /
# Mail.ReadWrite permissions + "Allow public client flows". If you set
# MSGRAPH_CLIENT_ID in the env before running, the secret is created with it;
# otherwise a placeholder is written so the pod still runs (tools/list works,
# auth is gated on the real client id).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORY_DIR="$(dirname "$SCRIPT_DIR")"
MANIFESTS="$FACTORY_DIR/manifests"

NAME="msgraph"
DEPLOY="sudo-msgraph-mcp"
NAMESPACE="default"
MCP_PORT=12420                      # 8000 + cksum("msgraph") % 22000 (fleet convention)
IMAGE="sudo-msgraph-mcp:latest"
SECRET="sudo-msgraph-oauth"
TENANT_ID="a8eec281-aaa3-4dae-ac9b-9a398b9215e7"   # Northeastern tenant

if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"; do
    if [[ -f "$cfg" ]]; then export KUBECONFIG="$cfg"; break; fi
  done
fi
if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "✗ No kubeconfig found." >&2; exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "✗ kubectl is required." >&2; exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "✗ docker is required to build the image." >&2; exit 1
fi

echo "→ sudo-msgraph-mcp deploy: image=$IMAGE port=$MCP_PORT namespace=$NAMESPACE"

echo "→ building $IMAGE from $FACTORY_DIR/Dockerfile ..."
docker build -t "$IMAGE" "$FACTORY_DIR"

echo "→ importing $IMAGE into k3s/containerd ..."
docker save "$IMAGE" | k3s ctr images import - >/dev/null 2>&1 || {
  echo "⚠ k3s ctr images import failed; trying sudo fallback" >&2
  docker save "$IMAGE" | sudo k3s ctr images import - >/dev/null
}
echo "→ image imported."

# ── Client-id secret (placeholder until the operator supplies a real app id) ──
if kubectl get secret "$SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "→ secret $SECRET already exists (left untouched)"
else
  CID="${MSGRAPH_CLIENT_ID:-00000000-0000-0000-0000-000000000000}"
  echo "→ creating secret $SECRET (client-id ${CID:0:8}… placeholder if unset)"
  kubectl create secret generic "$SECRET" -n "$NAMESPACE" \
    --from-literal=client-id="$CID"
fi

echo "→ applying PVC / Service / Deployment ..."
kubectl apply -f "$MANIFESTS/pvc.yaml"
kubectl apply -f "$MANIFESTS/service.yaml"
kubectl apply -f "$MANIFESTS/deployment.yaml"

echo "→ waiting for $DEPLOY to become Ready ..."
kubectl rollout status "deploy/$DEPLOY" -n "$NAMESPACE" --timeout=180s

echo "→ probing :$MCP_PORT (tcp) ..."
if kubectl exec "deploy/$DEPLOY" -n "$NAMESPACE" -- \
    python3 -c "import socket; socket.create_connection(('127.0.0.1', $MCP_PORT), 3).close()" 2>/dev/null; then
  echo "✓ sudo-msgraph-mcp is Ready and the MCP port answers."
else
  echo "⚠ MCP port did not answer; check: kubectl -n $NAMESPACE logs deploy/$DEPLOY" >&2
fi

echo
echo "sudo-msgraph-mcp up."
echo "  MCP:     http://sudo-msgraph-mcp:8000/mcp  (ClusterIP, fleet convention)"
echo "  MCP:     http://192.168.5.15:$MCP_PORT/mcp  (host LAN, baked fleet address)"
echo "  Consent: see factories/sudo-msgraph-mcp/README.md (device-code flow)"
