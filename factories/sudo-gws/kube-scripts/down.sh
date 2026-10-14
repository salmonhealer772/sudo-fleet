#!/usr/bin/env bash
# sudo-gws teardown. Scales the deployment to zero and deletes the Deployment
# and Service, but KEEPS the PVC (sudo-gws-data) so the operator's refresh
# token survives a redeploy — same reason the fleet scales instead of deleting.
set -euo pipefail

NAMESPACE="default"
DEPLOY="sudo-gws"

if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"; do
    if [[ -f "$cfg" ]]; then export KUBECONFIG="$cfg"; break; fi
  done
fi

kubectl -n "$NAMESPACE" scale deploy/"$DEPLOY" --replicas=0 2>/dev/null || true
kubectl -n "$NAMESPACE" delete deploy/"$DEPLOY" --ignore-not-found=true
kubectl -n "$NAMESPACE" delete svc sudo-gws-mcp --ignore-not-found=true
# secret + PVC are intentionally left behind (refresh token + config).
echo "sudo-gws down. PVC sudo-gws-data + secret sudo-gws-oauth kept."
