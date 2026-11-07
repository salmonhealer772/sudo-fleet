#!/usr/bin/env bash
# sudo-msgraph-mcp teardown — keeps the PVC + client-id secret so the device
# token cache survives a redeploy.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORY_DIR="$(dirname "$SCRIPT_DIR")"
MANIFESTS="$FACTORY_DIR/manifests"

if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"; do
    if [[ -f "$cfg" ]]; then export KUBECONFIG="$cfg"; break; fi
  done
fi

kubectl delete -f "$MANIFESTS/deployment.yaml" --ignore-not-found
kubectl delete -f "$MANIFESTS/service.yaml" --ignore-not-found
echo "→ kept PVC sudo-msgraph-mcp-data and secret sudo-msgraph-oauth (token cache intact)."
