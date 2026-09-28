#!/usr/bin/env bash
set -euo pipefail

# sudo-fleet/kube-scripts/save-glimor.sh — capture the LIVE router pair into
# portable glimor directories on disk. This is what makes the seed portable to
# a FRESH box: run this on a box where sudo-psnvc + sudo-forge are running, and
# it snapshots their identity into $FLEET_HOME/glimors/. Copy that directory to
# the fresh box (git add / tar / scp — it's just files), and k8s-up.sh restores
# Marc <- psnvc and Caesar <- forge from it.
#
#   psnvc (Letta planner)  -> $FLEET_HOME/glimors/psnvc/  (whole LETTA_HOME tree,
#                                                          i.e. /home/node/.letta)
#   forge (Hermes engineer)-> $FLEET_HOME/glimors/forge/  (SOUL.md + state.db +
#                                                          .hermes_history + .local + cache)
#
# Uses kubectl cp from the live pods (labels agent=psnvc / agent=forge). If a
# source pod is not running, that glimor is skipped with a warning.

FLEET_HOME="${FLEET_HOME:-/opt/0-0}"
GLIMOR_DIR="$FLEET_HOME/glimors"

die()  { echo "✗ $*" >&2; exit 1; }
step() { echo ""; echo "── $* ──"; }
ok()   { echo "✓ $*"; }
warn() { echo "⚠ $*" >&2; }

# kubeconfig auto-detect (mirrors the factory scripts)
if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in "/etc/rancher/k3s/k3s.yaml" "$HOME/.kube/config"; do
    if [[ -f "$cfg" ]]; then export KUBECONFIG="$cfg"; break; fi
  done
fi
[[ -n "${KUBECONFIG:-}" ]] || die "no kubeconfig found — is k3s running?"

mkdir -p "$GLIMOR_DIR"

# --- psnvc (Letta) -> glimors/psnvc -------------------------------------------
step "psnvc (Letta planner) -> $GLIMOR_DIR/psnvc"
POD="$(kubectl get pods -l agent=psnvc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [[ -z "$POD" ]]; then
  warn "no sudo-psnvc pod (label agent=psnvc) — skipping psnvc glimor"
else
  mkdir -p "$GLIMOR_DIR/psnvc"
  kubectl cp "$POD:/home/node/.letta/." "$GLIMOR_DIR/psnvc/" \
    || die "kubectl cp failed for $POD:/home/node/.letta"
  ok "psnvc glimor saved ($GLIMOR_DIR/psnvc/)"
fi

# --- forge (Hermes) -> glimors/forge ------------------------------------------
step "forge (Hermes engineer) -> $GLIMOR_DIR/forge"
FPOD="$(kubectl get pods -l agent=forge -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [[ -z "$FPOD" ]]; then
  warn "no sudo-forge pod (label agent=forge) — skipping forge glimor"
else
  mkdir -p "$GLIMOR_DIR/forge"
  for f in SOUL.md state.db .hermes_history; do
    kubectl cp "$FPOD:/opt/data/$f" "$GLIMOR_DIR/forge/$f" \
      || warn "kubectl cp failed for $FPOD:/opt/data/$f (continuing)"
  done
  for d in .local cache; do
    mkdir -p "$GLIMOR_DIR/forge/$d"
    kubectl cp "$FPOD:/opt/data/$d/." "$GLIMOR_DIR/forge/$d/" \
      || warn "kubectl cp failed for $FPOD:/opt/data/$d (continuing)"
  done
  ok "forge glimor saved ($GLIMOR_DIR/forge/)"
fi

echo ""
echo "✓ glimors captured under $GLIMOR_DIR"
echo "  To move to a fresh box, copy that directory (git / tar / scp):"
echo "    tar czf glimors.tgz -C $FLEET_HOME glimors"
echo "  On the fresh box, k8s-up.sh restores Marc <- psnvc and Caesar <- forge from it."
