#!/usr/bin/env bash
set -euo pipefail

# sudo-fleet/kube-scripts/k8s-down.sh — Stop the router pair.
# Stops Marc (Letta planner) + Caesar (Hermes engineer) by calling the factory
# down.sh. PVCs are PRESERVED by default (persistent state); pass --purge to
# delete them. --teardown-k3s uninstalls k3s.
#
# (This folds in the logic that used to live in the repo root down.sh; the root
#  down.sh is now a thin pointer that execs this script.)

FLEET_HOME="${FLEET_HOME:-/opt/0-0}"
AGENT_REPO="$FLEET_HOME/sudo-agent"
LETTA_REPO="$FLEET_HOME/sudo-letta"

die()  { echo "✗ $*" >&2; exit 1; }
step() { echo ""; echo "── $* ──"; }
ok()   { echo "✓ $*"; }
warn() { echo "⚠ $*" >&2; }

PURGE=0
TEARDOWN_K3S=0

usage() {
  cat <<'USAGE'
Usage: bash k8s-down.sh [--purge] [--teardown-k3s]
  (no flags)        stop sudo-marc + sudo-caesar, PRESERVE PVCs (persistent state)
  --purge           also delete the PVCs (sudo-marc-data, sudo-caesar-data)
  --teardown-k3s    uninstall k3s (and its data) after stopping agents
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge)        PURGE=1; shift ;;
    --teardown-k3s) TEARDOWN_K3S=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage; die "unknown flag: $1" ;;
  esac
done

SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

# kubeconfig auto-detect (mirrors the factory down.sh)
if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in "/etc/rancher/k3s/k3s.yaml" "$HOME/.kube/config"; do
    if [[ -f "$cfg" ]]; then export KUBECONFIG="$cfg"; break; fi
  done
fi
[[ -n "${KUBECONFIG:-}" ]] || warn "no kubeconfig found — k3s may already be gone"

step "Stop router pair"
$SUDO bash "$LETTA_REPO/kube-scripts/down.sh" --marc  || warn "sudo-letta down.sh --marc failed"
$SUDO bash "$AGENT_REPO/kube-scripts/down.sh" --caesar || warn "sudo-agent down.sh --caesar failed"
ok "deployments stopped"

if [[ "$PURGE" -eq 1 ]]; then
  step "Purge PVCs (persistent state)"
  for pvc in sudo-marc-data sudo-caesar-data; do
    kubectl delete pvc "$pvc" --ignore-not-found=true || warn "could not delete $pvc"
  done
  ok "PVCs deleted"
else
  ok "PVCs preserved (persistent state kept — re-run k8s-up.sh to come back)"
fi

if [[ "$TEARDOWN_K3S" -eq 1 ]]; then
  step "Tear down k3s"
  if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
    $SUDO /usr/local/bin/k3s-uninstall.sh || warn "k3s-uninstall.sh failed"
  else
    warn "/usr/local/bin/k3s-uninstall.sh not found — k3s left in place"
  fi
fi

echo ""
echo "✓ teardown complete"
