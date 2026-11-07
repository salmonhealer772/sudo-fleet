#!/usr/bin/env bash
# sudo-gmail-mcp teardown — keeps the PVC + the shared OAuth secret so refresh
# tokens survive a redeploy (the old path stays intact as fallback).
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
echo "→ kept PVC sudo-gmail-mcp-data and secret sudo-gws-oauth (refresh tokens intact)."
