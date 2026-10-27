#!/usr/bin/env bash
set -euo pipefail

# sudo-fleet/bin/k8s-up.sh — Command 2 of 2.
# Brings up the cluster (k3s must already be installed by setup.sh) and stands
# up a working starter pair: PLANNER_NAME (a Letta planner) and ENGINEER_NAME
# (a Hermes engineer), including their PVCs.
#
# OPTIONAL identity seed: if a glimor exists at $GLIMORS_DIR/<cap-name>/ it is
# passed to the factory as --from-glimor, so an install WITH a saved identity
# resumes it and an install WITHOUT one starts a clean agent. This repository
# ships no glimors: a fresh clone deploys two empty-brained agents and you grow
# their identity from there. A glimor you point at that is missing or corrupt
# still fails loudly (the initContainer never yields a blank agent).
#
# Names are configurable so this script is not tied to one fleet's identities:
#   PLANNER_NAME=boss ENGINEER_NAME=worker bash bin/k8s-up.sh
#
# Usage: bash k8s-up.sh

FLEET_HOME="${FLEET_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FLEET_ENV="$FLEET_HOME/.env"
AGENT_REPO="$FLEET_HOME/factories/sudo-agent"
LETTA_REPO="$FLEET_HOME/factories/sudo-letta"
GLIMORS_DIR="${GLIMORS_DIR:-$FLEET_HOME/deployments}"

# The starter pair. Generic by default; override per install. Capitalised forms
# are what the factories take (they prepend "sudo-" themselves), lower-case is
# what kubectl label selectors and PVC names use.
PLANNER_NAME="${PLANNER_NAME:-planner}"
ENGINEER_NAME="${ENGINEER_NAME:-engineer}"
PLANNER_DEPLOY="sudo-${PLANNER_NAME,,}"
ENGINEER_DEPLOY="sudo-${ENGINEER_NAME,,}"

# _seed_for <cap-name> — echo "--from-glimor <dir>" only when that glimor
# actually exists, so the default path needs no committed identity package.
_seed_for() {
  local cap="$1"
  local dir="$GLIMORS_DIR/$cap"
  if [[ -d "$dir" ]]; then printf ' --from-glimor %s' "$dir"; fi
}

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
      sudo -v || die "sudo authentication failed — this script needs sudo to stand up the starter pair"
    else
      # No TTY + no cached credential: consume ONE line of stdin as the sudo
      # password (so a piped / agent / CI run can still authenticate), then feed
      # it to sudo -S. There are no other stdin prompts in this script (the API
      # keys are sourced from $FLEET_ENV, not prompted), so this is safe.
      IFS= read -r _SUDO_PW || true
      if [[ -n "${_SUDO_PW:-}" ]]; then
        printf '%s\n' "$_SUDO_PW" | sudo -S -v 2>/dev/null \
          || die "sudo authentication failed (wrong password) — this script needs sudo to stand up the starter pair"
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
[[ -f "$FLEET_ENV" ]] || die "No $FLEET_ENV — drop one with LLM_API_KEY, LLM_PROVIDER, API_KEY before running."
set +euo pipefail
# shellcheck disable=SC1090
source "$FLEET_ENV"
set -euo pipefail
[[ -n "${DEEPSEEK_API_KEY:-}" ]] || die "DEEPSEEK_API_KEY missing in $FLEET_ENV"
[[ -n "${LLM_PROVIDER:-}" ]] || die "LLM_PROVIDER missing in $FLEET_ENV"
[[ -n "${API_KEY:-}" ]] || die "API_KEY missing in $FLEET_ENV"
export DEEPSEEK_API_KEY LLM_PROVIDER API_KEY
[[ -n "${LLM_BASE_URL:-}" ]] && export LLM_BASE_URL
# LLM_MODEL is the model contract's third leg (default deepseek-v4-pro); it is
# optional in the env (a missing value falls back to the working DeepSeek model
# in the factories), so it is exported only when set. LLM_API_KEY is the env var
# a Hermes custom_providers entry references via `key_env`; fall back to the
# shared LLM key so a custom endpoint's token resolves inside the pod.
LLM_MODEL="${LLM_MODEL:-deepseek-v4-pro}"
LLM_API_KEY="${LLM_API_KEY:-${DEEPSEEK_API_KEY:-}}"
export LLM_MODEL
export LLM_API_KEY
for _wk in EXA_API_KEY TAVILY_API_KEY PARALLEL_API_KEY PERPLEXITY_API_KEY; do
  [[ -n "${!_wk:-}" ]] && export "$_wk=${!_wk}"
done
unset _wk

# ── Web-search key gate (WARN ONCE, clearly — never break the install) ──────
# A missing web-search key is NOT fatal: the starter pair still deploy and run,
# only `web_search` is unavailable (the agents run blind). The factory up.sh
# has the same warn-not-die gate, so `_retry 3` never churns on it. We warn
# ONCE, here, with the exact one-line fix to add the key later.
_have_ws=0
for _wk in EXA_API_KEY TAVILY_API_KEY PARALLEL_API_KEY PERPLEXITY_API_KEY; do
  [[ -n "${!_wk:-}" ]] && _have_ws=1
done
unset _wk
if [[ "$_have_ws" -ne 1 ]]; then
  echo "" >&2
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
  echo "!!  SHIT, YOU NEED A TAVILY KEY — WEB SEARCH IS OFF              !!" >&2
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
  echo "" >&2
  echo "  No web-search key in $FLEET_ENV. This is NOT fatal: the install" >&2
  echo "  CONTINUES and the starter pair deploy + run normally. But web_search" >&2
  echo "  is DISABLED — the agents have NO internet access (they run BLIND)." >&2
  echo "" >&2
  echo "  FIX IT LATER — NO REINSTALL, ONE LINE:" >&2
  echo "    echo 'TAVILY_API_KEY=tvly-YOUR_KEY_HERE' >> $FLEET_ENV && (cd $FLEET_HOME/bin && bash k8s-up.sh)" >&2
  echo "" >&2
  echo "  Get a key (free tier): https://tavily.com" >&2
  echo "  Any ONE provider key works: EXA_API_KEY, TAVILY_API_KEY, PARALLEL_API_KEY, PERPLEXITY_API_KEY" >&2
  echo "  Or per-agent, from inside the pod:  /secret set TAVILY_API_KEY <key>" >&2
  echo "" >&2
fi

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
  printf 'LLM_MODEL=%s\n' "$LLM_MODEL"
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
# Also carry the LLM contract (LLM_MODEL / LLM_PROVIDER / LLM_BASE_URL / LLM_API_KEY)
# into the factory .env, so a re-run of the factory setup.sh and the pod env both
# read the SAME source. LLM_API_KEY is what a custom_providers `key_env` names.
_upsert_agent_env() {
  local key="$1" val="$2"
  [[ -z "$val" ]] && return 0
  if $SUDO test -f "$AGENT_REPO/.env" && $SUDO grep -q "^${key}=" "$AGENT_REPO/.env" 2>/dev/null; then
    $SUDO sed -i "s|^${key}=.*|${key}=${val}|" "$AGENT_REPO/.env"
  else
    printf '%s=%s\n' "$key" "$val" | $SUDO tee -a "$AGENT_REPO/.env" >/dev/null
  fi
}
_upsert_agent_env LLM_API_KEY  "$LLM_API_KEY"
_upsert_agent_env LLM_MODEL    "$LLM_MODEL"
_upsert_agent_env LLM_PROVIDER "$LLM_PROVIDER"
_upsert_agent_env LLM_BASE_URL "${LLM_BASE_URL:-}"
ok "env sourced + factory .env files re-seeded"

# --- 3. Deploy the planner (Letta) -------------------------------------------
# --from-glimor is appended only if a saved identity exists for this name.
PLANNER_SEED="$(_seed_for "${PLANNER_NAME^}")"
step "3/4 Deploy $PLANNER_DEPLOY (Letta planner)${PLANNER_SEED:+ — seeded from a glimor}"
# shellcheck disable=SC2086  # PLANNER_SEED is a deliberate flag pair, empty-safe
_retry 3 "deploy $PLANNER_NAME" $SUDO bash "$LETTA_REPO/bin/up.sh" "--${PLANNER_NAME}" $PLANNER_SEED \
  || die "sudo-letta up.sh --${PLANNER_NAME} failed"

# --- 4. Deploy the engineer (Hermes) -----------------------------------------
ENGINEER_SEED="$(_seed_for "${ENGINEER_NAME^}")"
step "4/4 Deploy $ENGINEER_DEPLOY (Hermes engineer)${ENGINEER_SEED:+ — seeded from a glimor}"
# shellcheck disable=SC2086
_retry 3 "deploy $ENGINEER_NAME" $SUDO bash "$AGENT_REPO/bin/up.sh" "--${ENGINEER_NAME}" $ENGINEER_SEED \
  || die "sudo-agent up.sh --${ENGINEER_NAME} failed"

# Wait for the pods to become Ready. With no seed these come up on their own;
# with a seed, a corrupt glimor keeps the pod in Init:Error and this catches it.
_retry 5 "wait $PLANNER_DEPLOY Ready" kubectl wait --for=condition=Ready pod -l "agent=${PLANNER_NAME,,}" --timeout=180s >/dev/null 2>&1 \
  || die "$PLANNER_DEPLOY pod not Ready (check: kubectl describe pod -l agent=${PLANNER_NAME,,})"
_retry 5 "wait $ENGINEER_DEPLOY Ready" kubectl wait --for=condition=Ready pod -l "agent=${ENGINEER_NAME,,}" --timeout=180s >/dev/null 2>&1 \
  || die "$ENGINEER_DEPLOY pod not Ready (check: kubectl describe pod -l agent=${ENGINEER_NAME,,})"

# --- Verify ---------------------------------------------------------------------
echo ""
echo "→ Verifying PVCs + services..."
for pvc in "${PLANNER_DEPLOY}-data" "${ENGINEER_DEPLOY}-data"; do
  _retry 5 "verify PVC $pvc" kubectl get pvc "$pvc" >/dev/null 2>&1 \
    || die "PVC $pvc missing"
done
for svc in "${PLANNER_DEPLOY}-mcp" "${PLANNER_DEPLOY}-watch" "${ENGINEER_DEPLOY}-mcp" "${ENGINEER_DEPLOY}-watch"; do
  _retry 5 "verify Service $svc" kubectl get svc "$svc" >/dev/null 2>&1 \
    || die "Service $svc missing"
done

# --- 5. Paperclip control plane + AUTO-HIRE ---------------------------------
# sudo-fleet ships with Paperclip (docs/PAPERCLIP.md). Standing the fleet up
# brings the control plane up too, then hires every agent that now exists — so
# "the fleet is up" and "every agent is hired with a heartbeat" are the same
# event, with no manual step.
# Deliberately NON-FATAL: the router pair is the fleet, and it must come up even
# on a box too small for the control plane. Re-run bin/paperclip-up.sh later.
step "5/5 Paperclip control plane + auto-hire"
if [[ -x "$FLEET_HOME/bin/paperclip-up.sh" ]]; then
  if bash "$FLEET_HOME/bin/paperclip-up.sh"; then
    bash "$FLEET_HOME/bin/paperclip-adopt.sh" || warn "auto-hire reported failures — see above"
  else
    warn "bin/paperclip-up.sh failed — fleet is up, but Paperclip/auto-hire did not complete"
  fi
else
  warn "bin/paperclip-up.sh missing — Paperclip control plane NOT installed"
fi

ok "pair running: $PLANNER_DEPLOY (planner) + $ENGINEER_DEPLOY (engineer)"
kubectl get pods -l "agent in (${PLANNER_NAME,,},${ENGINEER_NAME,,})" -o wide
echo ""
echo "✓ Fleet up."
echo "  Talk (Letta planner): kubectl exec -it deploy/$PLANNER_DEPLOY -- bash -c 'letta'"
echo "  Talk (Hermes eng):    kubectl exec -it deploy/$ENGINEER_DEPLOY -- hermes"
echo "  Stop (preserve state): bash bin/k8s-down.sh"
