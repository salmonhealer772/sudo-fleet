#!/usr/bin/env bash
# sudo-mail-mcp teardown: scale to zero + delete deployment/service (keep PVC + secret).
set -euo pipefail
if [ -z "${KUBECONFIG:-}" ]; then
  for cfg in /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"; do
    [ -f "$cfg" ] && export KUBECONFIG="$cfg" && break
  done
fi
kubectl scale deploy/sudo-mail-mcp -n default --replicas=0 2>/dev/null || true
kubectl delete deploy/sudo-mail-mcp -n default 2>/dev/null || true
kubectl delete svc/sudo-mail-mcp -n default 2>/dev/null || true
echo "sudo-mail-mcp down (PVC + secret kept)."
