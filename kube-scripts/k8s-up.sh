#!/usr/bin/env bash
set -euo pipefail

# sudo-fleet/kube-scripts/k8s-up.sh — Command 2 of 2.
# Brings up the cluster (k3s must already be installed by setup.sh) and stands
# up the router pair: Marc (Letta planner) + Caesar (Hermes engineer), including
# their PVCs and their identity, seeded as FULL GLIMORS from psnvc (-> Marc) and
# forge (-> Caesar).
#
# Glimor seed: Marc and Caesar are seeded from the COMMITTED glimors in
# $FLEET_HOME/deployments/{Marc,Caesar}/ by each factory's up.sh (via an
# initContainer that copies the glimor into the PVC BEFORE the agent process
# starts). There is no live-pod copy and no post-Ready `kubectl cp` — a missing
# or invalid glimor fails the deploy loudly, never a blank Tutor / bare Hermes.
#
# Usage: bash k8s-up.sh

FLEET_HOME="${FLEET_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FLEET_ENV="$FLEET_HOME/.env"
AGENT_REPO="$FLEET_HOME/sudo-agent"
LETTA_REPO="$FLEET_HOME/sudo-letta"
GLIMORS_DIR="$FLEET_HOME/deployments"

KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

die()  { echo "✗ $*" >&2; exit 1; }
step() { echo ""; echo "── $* ──"; }
ok()   { echo "✓ $*"; }
warn() { echo "⚠ $*" >&2; }

# _retry N "description" cmd [args...] — run cmd up to N times with backoff.
# Makes the fragile deploy/readiness steps survive transient failures (pod not
# Ready yet, kubectl still settling, image import racing) instead of dying on
# the first failure — the "try excepts on all the bits that can have it" bar.
_retry() {
  local n="$1" desc="$2"; shift 2
  local i=1
  while (( i <= n )); do
    if "$@"; then
      return 0
    fi
    warn "($desc) attempt $i/$n failed — retrying in ${i}s..."
    sleep "$i"
    (( i++ ))
  done
  return 1
}

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
      sudo -v || die "sudo authentication failed — this script needs sudo to stand up Marc + Caesar"
    else
      # No TTY + no cached credential: consume ONE line of stdin as the sudo
      # password (so a piped / agent / CI run can still authenticate), then feed
      # it to sudo -S. There are no other stdin prompts in this script (the API
      # keys are sourced from $FLEET_ENV, not prompted), so this is safe.
      IFS= read -r _SUDO_PW || true
      if [[ -n "${_SUDO_PW:-}" ]]; then
        printf '%s\n' "$_SUDO_PW" | sudo -S -v 2>/dev/null \
          || die "sudo authentication failed (wrong password) — this script needs sudo to stand up Marc + Caesar"
      else
        die "sudo needs a password but none arrived on stdin (no TTY, no cached credential). Run in a terminal, pre-authenticate with 'sudo -v', or pipe the password as the first line of stdin."
      fi
      unset _SUDO_PW
    fi
  fi
fi

# --- 1. Cluster -----------------------------------------------------------------
step "1/4 Cluster"
[[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig missing at $KUBECONFIG_PATH — run setup.sh first"
export KUBECONFIG="$KUBECONFIG_PATH"
_retry 5 "kubectl cluster-info" kubectl cluster-info >/dev/null 2>&1 \
  || die "k3s not reachable — run setup.sh first"
_retry 3 "wait node Ready" kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null 2>&1 \
  || die "node not Ready"
ok "k3s up ($(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}' | paste -sd, -))"

# --- 2. API keys (same non-interactive bridge as setup.sh) ---------------------
step "2/4 API keys from $FLEET_ENV"
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
  [[ -n "${!_wk:-}" ]] && export "$_wk=${!_wk}"
done
unset _wk

# Re-seed the factory .env files so the `sudo bash up.sh` calls (sudo strips the
# wrapper's exported env) still find their credentials. Idempotent.
$SUDO mkdir -p "$LETTA_REPO/.sudo-letta"
# Build the pre-seed .env in a user-owned temp file (never pipe into sudo, so
# no hidden sudo prompt), then install it into place under sudo. An `if` guard
# skips unset optional keys (e.g. PERPLEXITY_API_KEY) so `set -euo pipefail`
# cannot kill this script on a missing key.
_env_tmp="$(mktemp)"
{
  printf 'LLM_PROVIDER=%s\n' "$LLM_PROVIDER"
  printf 'API_KEY=%s\n' "$API_KEY"
  [[ -n "${LLM_BASE_URL:-}" ]] && printf 'LLM_BASE_URL=%s\n' "$LLM_BASE_URL"
  for _wk in EXA_API_KEY TAVILY_API_KEY PARALLEL_API_KEY PERPLEXITY_API_KEY; do
    if [[ -n "${!_wk:-}" ]]; then
      printf '%s=%s\n' "$_wk" "${!_wk}"
    fi
  done
} > "$_env_tmp"
unset _wk
$SUDO install -m 600 "$_env_tmp" "$LETTA_REPO/.sudo-letta/.env" \
  || { rm -f "$_env_tmp"; die "could not write $LETTA_REPO/.sudo-letta/.env"; }
rm -f "$_env_tmp"
# sudo-agent up.sh reads DEEPSEEK_API_KEY from $AGENT_REPO/.env (or env or prompt).
# Upsert the key without clobbering a SUDO_PASSWORD line up.sh may have written.
if $SUDO test -f "$AGENT_REPO/.env" && $SUDO grep -q '^DEEPSEEK_API_KEY=' "$AGENT_REPO/.env" 2>/dev/null; then
  $SUDO sed -i "s|^DEEPSEEK_API_KEY=.*|DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY}|" "$AGENT_REPO/.env"
else
  printf 'DEEPSEEK_API_KEY=%s\n' "$DEEPSEEK_API_KEY" | $SUDO tee -a "$AGENT_REPO/.env" >/dev/null
fi
ok "env sourced + factory .env files re-seeded"

# --- 3. Deploy Marc (Letta planner) — seeded from the committed glimor --------
step "3/4 Deploy Marc (Letta planner) — factory up.sh (seeded from $GLIMORS_DIR/Marc)"
_retry 3 "deploy Marc" $SUDO bash "$LETTA_REPO/kube-scripts/up.sh" --marc \
  --from-glimor "$GLIMORS_DIR/Marc" \
  || die "sudo-letta up.sh --marc --from-glimor failed"

# --- 4. Deploy Caesar (Hermes engineer) — seeded from the committed glimor ----
step "4/4 Deploy Caesar (Hermes engineer) — factory up.sh (seeded from $GLIMORS_DIR/Caesar)"
_retry 3 "deploy Caesar" $SUDO bash "$AGENT_REPO/kube-scripts/up.sh" --caesar \
  --from-glimor "$GLIMORS_DIR/Caesar" \
  || die "sudo-agent up.sh --caesar --from-glimor failed"

# Seeding happens INSIDE each factory's up.sh via an initContainer that copies
# the committed glimor into the PVC BEFORE the agent process starts. Wait for
# the pods to become Ready — a missing/corrupt glimor keeps the pod in
# Init:Error forever (the required fail-loudly, never a blank agent).
_retry 5 "wait sudo-marc Ready" kubectl wait --for=condition=Ready pod -l agent=marc  --timeout=180s >/dev/null 2>&1 \
  || die "sudo-marc pod not Ready (initContainer may have failed to seed)"
_retry 5 "wait sudo-caesar Ready" kubectl wait --for=condition=Ready pod -l agent=caesar --timeout=180s >/dev/null 2>&1 \
  || die "sudo-caesar pod not Ready (initContainer may have failed to seed)"

# --- Verify ---------------------------------------------------------------------
echo ""
echo "→ Verifying PVCs + services..."
for pvc in sudo-marc-data sudo-caesar-data; do
  _retry 5 "verify PVC $pvc" kubectl get pvc "$pvc" >/dev/null 2>&1 \
    || die "PVC $pvc missing"
done
for svc in sudo-marc-mcp sudo-marc-watch sudo-caesar-mcp sudo-caesar-watch; do
  _retry 5 "verify Service $svc" kubectl get svc "$svc" >/dev/null 2>&1 \
    || die "Service $svc missing"
done

ok "router pair running: sudo-marc (planner) + sudo-caesar (engineer)"
kubectl get pods -l 'agent in (marc,caesar)' -o wide
echo ""
echo "✓ Fleet up."
echo "  Talk (Letta planner): kubectl exec -it deploy/sudo-marc -- bash -c 'letta'"
echo "  Talk (Hermes eng):    kubectl exec -it deploy/sudo-caesar -- hermes"
echo "  Stop (preserve state): bash kube-scripts/k8s-down.sh"
