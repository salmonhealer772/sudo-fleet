#!/usr/bin/env bash
set -euo pipefail

# sudo-fleet/down.sh — thin pointer. The real teardown now lives in
# kube-scripts/k8s-down.sh (stop Marc + Caesar, preserve PVCs by default;
# --purge deletes PVCs, --teardown-k3s uninstalls k3s). Kept so the old
# `bash down.sh` muscle memory still works.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/kube-scripts/k8s-down.sh" "$@"
