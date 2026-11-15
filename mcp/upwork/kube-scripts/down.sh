#!/usr/bin/env bash
# Tear down sudo-upwork-mcp. Keeps the PVC (the OAuth token) and the image by
# default so a re-deploy does not force a fresh authorization.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="$(dirname "$SCRIPT_DIR")/k8s"

if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"; do
    [[ -f "$cfg" ]] && { export KUBECONFIG="$cfg"; break; }
  done
fi

kubectl delete -f "$MANIFESTS/deployment.yaml" --ignore-not-found
kubectl delete -f "$MANIFESTS/service.yaml" --ignore-not-found

if [[ "${1:-}" == "--purge" ]]; then
  kubectl delete -f "$MANIFESTS/pvc.yaml" --ignore-not-found
  echo "sudo-upwork-mcp removed (PVC purged)."
else
  echo "sudo-upwork-mcp removed (PVC + token kept)."
fi
