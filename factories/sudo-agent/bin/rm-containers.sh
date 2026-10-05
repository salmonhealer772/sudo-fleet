#!/usr/bin/env bash
set -euo pipefail

# bin/rm-containers.sh — Remove sudo-agent deployments + PVCs
# Usage:
#   bash bin/rm-containers.sh --name     Remove one
#   bash bin/rm-containers.sh --ALL       Nuke ALL sudo-*

# Auto-detect kubeconfig, because this script is often run after `sudo`/`su`
# (which changes $HOME and makes kubectl lose its config); try the known k3s/
# operator paths in order so a plain `bash rm-containers.sh --name` just works.
if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in "/etc/rancher/k3s/k3s.yaml" "/home/world15/.kube/config" "$HOME/.kube/config"; do
    if [[ -f "$cfg" ]]; then export KUBECONFIG="$cfg"; break; fi
  done
fi

NAME=""
REMOVE_ALL=false

# Parse --name (with or without `=`) and --ALL. Both spellings of --name are
# accepted because operators habitually type both; anything else aborts with
# usage rather than guessing at a destructive target.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name|--name=*)
      if [[ "$1" == --name=* ]]; then
        NAME="${1#--name=}"
      else
        shift; NAME="${1:-}"
      fi
      ;;
    --ALL|--all)  REMOVE_ALL=true ;;
    *)            echo "Usage: bash bin/rm-containers.sh --name | --ALL" >&2; exit 1 ;;
  esac
  shift
done

# Bulk teardown: delete every sudo-agent Deployment AND PVC by label, then drop
# the generated per-agent manifests so a stale .yaml can't resurrect a dead
# agent. `|| true` on each delete makes an already-absent object a no-op, not
# an abort — a nuke must clear whatever is left, not die on the first miss.
if $REMOVE_ALL; then
  echo "→ Nuking ALL sudo-* from Kubernetes..."
  kubectl delete deploy -l app=sudo-agent 2>/dev/null || true
  kubectl delete pvc -l app=sudo-agent 2>/dev/null || true
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  rm -f "$REPO_DIR/deployments"/*.yaml 2>/dev/null || true
  echo "✓ Gone."
elif [[ -n "$NAME" ]]; then
  DEPLOY="sudo-$NAME"
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  # Single teardown: unlike down.sh, this deletes the PVC TOO, because "remove"
  # means the agent's memory goes with it; the manifest is also dropped so the
  # next `up` starts clean. Absent objects are tolerated, a miss is reported.
  if kubectl get deploy "$DEPLOY" &>/dev/null; then
    kubectl delete deploy "$DEPLOY"
    kubectl delete pvc "$DEPLOY-data" 2>/dev/null || true
    rm -f "$REPO_DIR/deployments/$NAME.yaml" 2>/dev/null || true
    echo "✓ $DEPLOY removed (deployment + volume)."
  else
    echo "→ $DEPLOY not found."
  fi
else
  echo "Usage: bash bin/rm-containers.sh --name | --ALL" >&2
  exit 1
fi
