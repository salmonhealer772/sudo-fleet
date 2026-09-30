#!/usr/bin/env bash
set -euo pipefail

# kube-scripts/down.sh — Stop a sudo-agent in Kubernetes (PVC = memory persists)
# Usage: bash kube-scripts/down.sh --name

# Parse the --name flag, because the agent's Kubernetes objects are all
# derived from that one token (deploy `sudo-$NAME`, PVC `sudo-$NAME-data`); an
# unrecognised arg aborts with usage instead of guessing.
NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name|--*)  NAME="${1#--}"; shift ;;
    *)           echo "Usage: bash kube-scripts/down.sh --name" >&2; exit 1 ;;
  esac
done
# Reject an empty name, because `sudo-` is not a valid object and would
# otherwise produce a confusing kubectl error far from the real cause.
if [[ -z "$NAME" ]]; then
  echo "Usage: bash kube-scripts/down.sh --name" >&2
  echo "Example: bash kube-scripts/down.sh --alice" >&2
  exit 1
fi
# Refuse `--all`, because a bulk teardown must go through rm-containers.sh
# (which also deletes PVCs) so the two tools never silently overlap.
if [[ "${NAME,,}" == "all" ]]; then
  echo "Use rm-containers.sh --ALL instead." >&2; exit 1
fi

DEPLOY="sudo-$NAME"

# Delete ONLY the Deployment, because the PVC is the agent's memory and must
# survive a stop so the next `up` resumes the same identity; if the deploy is
# already gone, report that instead of failing.
if kubectl get deploy "$DEPLOY" &>/dev/null; then
  kubectl delete deploy "$DEPLOY"
  echo "✓ $DEPLOY stopped. Volume (PVC) preserved — memory persists."
else
  echo "→ Deployment $DEPLOY not found."
fi
