#!/usr/bin/env bash
set -euo pipefail

# sudo-fleet/kube-scripts/k8s-down.sh — Stop the router pair.
# Stops Marc (Letta planner) + Caesar (Hermes engineer) by calling the factory
# down.sh. PVCs are PRESERVED by default (persistent state); pass --purge to
# delete them. --teardown-k3s uninstalls k3s.
#
# (This folds in the logic that used to live in the repo root down.sh; the root
#  down.sh is now a thin pointer that execs this script.)

FLEET_HOME="${FLEET_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AGENT_REPO="$FLEET_HOME/factories/sudo-agent"
LETTA_REPO="$FLEET_HOME/factories/sudo-letta"

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

is_root() { [[ "$(id -u)" -eq 0 ]]; }
SUDO=""
if ! is_root; then
  SUDO="sudo"
  echo "→ Warming up sudo (you may be prompted once for your password)..."
  # Prime sudo non-interactively FIRST: succeeds when credentials are already
  # cached (passwordless sudo, or a recent sudo) without hanging on a hidden
  # prompt. Only fall back to an interactive prompt (real TTY) or a password
  # read from stdin (-S) when there is no cached credential; never hang.
  if ! sudo -n -v 2>/dev/null; then
    if [[ -t 0 ]]; then
      sudo -v || die "sudo authentication failed — this script needs sudo to stop Marc + Caesar"
    else
      # No TTY + no cached credential: consume ONE line of stdin as the sudo
      # password (so a piped / agent / CI run can still authenticate), then feed
      # it to sudo -S. There are no other stdin prompts in this script, so this
      # is safe.
      IFS= read -r _SUDO_PW || true
      if [[ -n "${_SUDO_PW:-}" ]]; then
        printf '%s\n' "$_SUDO_PW" | sudo -S -v 2>/dev/null \
          || die "sudo authentication failed (wrong password) — this script needs sudo to stop Marc + Caesar"
      else
        die "sudo needs a password but none arrived on stdin (no TTY, no cached credential). Run in a terminal, pre-authenticate with 'sudo -v', or pipe the password as the first line of stdin."
      fi
      unset _SUDO_PW
    fi
  fi
fi

# kubeconfig auto-detect (mirrors the factory down.sh)
if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in "/etc/rancher/k3s/k3s.yaml" "$HOME/.kube/config"; do
    if [[ -f "$cfg" ]]; then export KUBECONFIG="$cfg"; break; fi
  done
fi
[[ -n "${KUBECONFIG:-}" ]] || warn "no kubeconfig found — k3s may already be gone"

step "Stop router pair"
marc_fail=0
caesar_fail=0
# sudo resets the environment (Defaults env_reset), so an exported KUBECONFIG
# does NOT survive the `$SUDO bash ...` hop. The factory letta down.sh re-detects
# its own kubeconfig, but the factory agent down.sh does NOT — so pass KUBECONFIG
# explicitly to make BOTH stop reliably when run as non-root.
if [[ -n "${KUBECONFIG:-}" ]]; then
  $SUDO env "KUBECONFIG=$KUBECONFIG" bash "$LETTA_REPO/kube-scripts/down.sh" --marc   || marc_fail=$?
  $SUDO env "KUBECONFIG=$KUBECONFIG" bash "$AGENT_REPO/kube-scripts/down.sh" --caesar || caesar_fail=$?
else
  $SUDO bash "$LETTA_REPO/kube-scripts/down.sh" --marc   || marc_fail=$?
  $SUDO bash "$AGENT_REPO/kube-scripts/down.sh" --caesar || caesar_fail=$?
fi

# A failed factory down.sh must NOT be swallowed: fail loud, do not claim
# "stopped" while either Marc or Caesar is still up.
if (( marc_fail != 0 || caesar_fail != 0 )); then
  die "stop FAILED: sudo-letta down.sh --marc exit=$marc_fail, sudo-agent down.sh --caesar exit=$caesar_fail — pods NOT stopped"
fi

# Verify the pods are actually GONE (not merely "delete requested"): wait out
# the termination grace period, then require zero marc/caesar pods before we
# claim success. Never print "deployments stopped" while a pod is still up.
for ((_i = 0; _i < 30; _i++)); do
  _remaining="$(kubectl get pods -A --no-headers 2>/dev/null | grep -cE 'sudo-(marc|caesar)-' || true)"
  (( _remaining == 0 )) && break
  sleep 2
done
_remaining="$(kubectl get pods -A --no-headers 2>/dev/null | grep -cE 'sudo-(marc|caesar)-' || true)"
if (( _remaining > 0 )); then
  die "stop FAILED: $_remaining marc/caesar pod(s) still present after down.sh — NOT stopped, refusing to claim teardown complete"
fi
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
