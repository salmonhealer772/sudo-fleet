#!/usr/bin/env bash
set -euo pipefail

# sudo-fleet/kube-scripts/k8s-up.sh — Command 2 of 2.
# Brings up the cluster (k3s must already be installed by setup.sh) and stands
# up the router pair: Marc (Letta planner) + Caesar (Hermes engineer), including
# their PVCs and their identity, seeded as FULL GLIMORS from psnvc (-> Marc) and
# forge (-> Caesar).
#
# Glimor seed: this script restores from a SAVED glimor directory on disk
# ($FLEET_HOME/glimors/{psnvc,forge}/) — it does NOT copy from live pods, so it
# works on a FRESH box (which has no psnvc/forge to copy FROM). If the saved
# glimor dir is absent, Marc/Caesar deploy EMPTY (factory defaults) and we warn
# loudly. Capture the glimors on a box that has the live pair with:
#   bash kube-scripts/save-glimor.sh
#
# Usage: bash k8s-up.sh

FLEET_HOME="${FLEET_HOME:-/opt/0-0}"
FLEET_ENV="$FLEET_HOME/.env"
AGENT_REPO="$FLEET_HOME/sudo-agent"
LETTA_REPO="$FLEET_HOME/sudo-letta"
GLIMOR_DIR="$FLEET_HOME/glimors"

KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

die()  { echo "✗ $*" >&2; exit 1; }
step() { echo ""; echo "── $* ──"; }
ok()   { echo "✓ $*"; }
warn() { echo "⚠ $*" >&2; }

SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

# --- 1. Cluster -----------------------------------------------------------------
step "1/5 Cluster"
[[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig missing at $KUBECONFIG_PATH — run setup.sh first"
export KUBECONFIG="$KUBECONFIG_PATH"
kubectl cluster-info >/dev/null 2>&1 || die "k3s not reachable — run setup.sh first"
kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null 2>&1 \
  || die "node not Ready"
ok "k3s up ($(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}' | paste -sd, -))"

# --- 2. API keys (same non-interactive bridge as setup.sh) ---------------------
step "2/5 API keys from $FLEET_ENV"
[[ -f "$FLEET_ENV" ]] || die "No $FLEET_ENV — drop one with DEEPSEEK_API_KEY, LLM_PROVIDER, API_KEY before running."
set +euo pipefail
# shellcheck disable=SC1090
source "$FLEET_ENV"
set -euo pipefail
[[ -n "${DEEPSEEK_API_KEY:-}" ]] || die "DEEPSEEK_API_KEY missing in $FLEET_ENV"
[[ -n "${LLM_PROVIDER:-}" ]] || die "LLM_PROVIDER missing in $FLEET_ENV"
[[ -n "${API_KEY:-}" ]] || die "API_KEY missing in $FLEET_ENV"
export DEEPSEEK_API_KEY LLM_PROVIDER API_KEY
[[ -n "${LLM_BASE_URL:-}" ]] && export LLM_BASE_URL
for _wk in EXA_API_KEY TAVILY_API_KEY PARALLEL_API_KEY PERPLEXITY_API_KEY; do
  [[ -n "${!_wk:-}" ]] && export "$_wk"
done
unset _wk

# Re-seed the factory .env files so the `sudo bash up.sh` calls (sudo strips the
# wrapper's exported env) still find their credentials. Idempotent.
$SUDO mkdir -p "$LETTA_REPO/.sudo-letta"
{
  printf 'LLM_PROVIDER=%s\n' "$LLM_PROVIDER"
  printf 'API_KEY=%s\n' "$API_KEY"
  [[ -n "${LLM_BASE_URL:-}" ]] && printf 'LLM_BASE_URL=%s\n' "$LLM_BASE_URL"
  for _wk in EXA_API_KEY TAVILY_API_KEY PARALLEL_API_KEY PERPLEXITY_API_KEY; do
    [[ -n "${!_wk:-}" ]] && printf '%s=%s\n' "$_wk" "${!_wk}"
  done
} | $SUDO tee "$LETTA_REPO/.sudo-letta/.env" >/dev/null
unset _wk
# sudo-agent up.sh reads DEEPSEEK_API_KEY from $AGENT_REPO/.env (or env or prompt).
# Upsert the key without clobbering a SUDO_PASSWORD line up.sh may have written.
if $SUDO test -f "$AGENT_REPO/.env" && $SUDO grep -q '^DEEPSEEK_API_KEY=' "$AGENT_REPO/.env" 2>/dev/null; then
  $SUDO sed -i "s|^DEEPSEEK_API_KEY=.*|DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY}|" "$AGENT_REPO/.env"
else
  printf 'DEEPSEEK_API_KEY=%s\n' "$DEEPSEEK_API_KEY" | $SUDO tee -a "$AGENT_REPO/.env" >/dev/null
fi
ok "env sourced + factory .env files re-seeded"

# --- 3. Deploy Marc (Letta planner) --------------------------------------------
step "3/5 Deploy Marc (Letta planner) — factory up.sh"
$SUDO bash "$LETTA_REPO/kube-scripts/up.sh" --marc || die "sudo-letta up.sh --marc failed"

# --- 4. Deploy Caesar (Hermes engineer) ----------------------------------------
step "4/5 Deploy Caesar (Hermes engineer) — factory up.sh"
$SUDO bash "$AGENT_REPO/kube-scripts/up.sh" --caesar || die "sudo-agent up.sh --caesar failed"

# --- 5. Seed glimors (restore from SAVED dir, portable to a fresh box) ---------
step "5/5 Seed glimors (identity + live state)"
kubectl wait --for=condition=Ready pod -l agent=marc  --timeout=180s >/dev/null 2>&1 || die "sudo-marc pod not Ready"
kubectl wait --for=condition=Ready pod -l agent=caesar --timeout=180s >/dev/null 2>&1 || die "sudo-caesar pod not Ready"

# (a) Caesar <- forge (Hermes identity: SOUL.md + state.db + .hermes_history
#     + .local + cache) into the sudo-caesar PVC at /opt/data/.
if [[ -d "$GLIMOR_DIR/forge" ]]; then
  CPOD="$(kubectl get pods -l agent=caesar -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$CPOD" ]] || die "could not resolve sudo-caesar pod for seeding"
  for f in SOUL.md state.db .hermes_history; do
    if [[ -f "$GLIMOR_DIR/forge/$f" ]]; then
      kubectl cp "$GLIMOR_DIR/forge/$f" "$CPOD:/opt/data/$f" || die "seed failed: forge/$f -> $CPOD:/opt/data/$f"
      ok "seeded forge/$f -> sudo-caesar:/opt/data/$f"
    else
      warn "glimor missing $GLIMOR_DIR/forge/$f — skipping (Caesar will lack it)"
    fi
  done
  for d in .local cache; do
    if [[ -d "$GLIMOR_DIR/forge/$d" ]]; then
      kubectl cp "$GLIMOR_DIR/forge/$d/." "$CPOD:/opt/data/$d/" || die "seed failed: forge/$d -> $CPOD:/opt/data/$d/"
      ok "seeded forge/$d/ -> sudo-caesar:/opt/data/$d/"
    else
      warn "glimor missing $GLIMOR_DIR/forge/$d/ — skipping"
    fi
  done
  ok "Caesar seeded from $GLIMOR_DIR/forge"
else
  warn "no $GLIMOR_DIR/forge — Caesar starts EMPTY (factory default SOUL)."
  warn "  Capture it later on a box with sudo-forge: bash kube-scripts/save-glimor.sh"
fi

# (b) Marc <- psnvc (Letta brain: the whole LETTA_HOME tree) into the sudo-marc
#     PVC at /home/node/.letta/ (the letta PVC mountPath — see factory up.sh).
if [[ -d "$GLIMOR_DIR/psnvc" ]]; then
  MPOD="$(kubectl get pods -l agent=marc -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$MPOD" ]] || die "could not resolve sudo-marc pod for seeding"
  kubectl cp "$GLIMOR_DIR/psnvc/." "$MPOD:/home/node/.letta/" || die "seed failed: psnvc tree -> $MPOD:/home/node/.letta/"
  # The letta container runs as `node`; fix ownership so the brain is readable.
  kubectl exec "$MPOD" -- chown -R node:node /home/node/.letta 2>/dev/null \
    || warn "could not chown /home/node/.letta (may already be node-owned)"
  ok "Marc seeded from $GLIMOR_DIR/psnvc"
else
  warn "no $GLIMOR_DIR/psnvc — Marc starts EMPTY (factory default persona)."
  warn "  Capture it later on a box with sudo-psnvc: bash kube-scripts/save-glimor.sh"
fi

# --- Verify ---------------------------------------------------------------------
echo ""
echo "→ Verifying PVCs + services..."
for pvc in sudo-marc-data sudo-caesar-data; do
  kubectl get pvc "$pvc" >/dev/null 2>&1 || die "PVC $pvc missing"
done
for svc in sudo-marc-mcp sudo-marc-watch sudo-caesar-mcp sudo-caesar-watch; do
  kubectl get svc "$svc" >/dev/null 2>&1 || die "Service $svc missing"
done

ok "router pair running: sudo-marc (planner) + sudo-caesar (engineer)"
kubectl get pods -l 'agent in (marc,caesar)' -o wide
echo ""
echo "✓ Fleet up."
echo "  Talk (Letta planner): kubectl exec -it deploy/sudo-marc -- bash -c 'letta'"
echo "  Talk (Hermes eng):    kubectl exec -it deploy/sudo-caesar -- hermes"
echo "  Stop (preserve state): bash kube-scripts/k8s-down.sh"
