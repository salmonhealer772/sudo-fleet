#!/usr/bin/env bash
set -euo pipefail

# sudo-fleet/setup.sh — Command 1 of 2 (bootstrap ONLY; normally run by
# bootstrap.sh after it clones + writes .env).
#
# Bootstraps a bare Linux box: docker + k3s (single node), clones the two
# factory repos NESTED inside this one folder, and builds both factory images
# non-interactively. It does NOT deploy agents — that is Command 2:
#
#   cd sudo-fleet/kube-scripts && bash k8s-up.sh
#
# Everything this script creates lives INSIDE the single `sudo-fleet/` folder
# (the repo root = FLEET_HOME). No /opt/0-0, no siblings, nothing outside it.
#
# API keys are collected by bootstrap.sh (interactive) into FLEET_HOME/.env.
# setup.sh reads them non-interactively from there. Required:
#     DEEPSEEK_API_KEY=...      # sudo-agent / Hermes
#     LLM_PROVIDER=...          # sudo-letta / Letta (openai|anthropic|deepseek|...)
#     API_KEY=...               # sudo-letta / Letta
#   optional:
#     GITHUB_TOKEN=...          # GitHub PAT for authenticated clone/pull (repos are public)
#     LLM_BASE_URL=...          # OpenAI-compatible base URL
#     TAVILY_API_KEY=...        # letta web_search hard-requires one of
#                               #   EXA_API_KEY / TAVILY_API_KEY / PARALLEL_API_KEY / PERPLEXITY_API_KEY

# FLEET_HOME is the repo root — the single sudo-fleet/ folder. Derive it from
# the script's own location (portable to ANY directory), never a hardcoded path.
FLEET_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_ENV="$FLEET_HOME/.env"

AGENT_REPO="$FLEET_HOME/sudo-agent"
LETTA_REPO="$FLEET_HOME/sudo-letta"
GLIMOR_DIR="$FLEET_HOME/glimors"

GH="https://github.com/salmonhealer772"

die()  { echo "✗ $*" >&2; exit 1; }
step() { echo ""; echo "── $* ──"; }
ok()   { echo "✓ $*"; }
warn() { echo "⚠ $*" >&2; }

# --- root/sudo -----------------------------------------------------------------
is_root() { [[ "$(id -u)" -eq 0 ]]; }
SUDO=""
if ! is_root; then
  SUDO="sudo"
  echo "→ Warming up sudo (you may be prompted for your password once)..."
  $SUDO -v || die "sudo failed — this script needs sudo to install docker/k3s"
fi

# --- 1. Docker ------------------------------------------------------------------
step "1/6 Bootstrap: Docker"
if ! command -v docker >/dev/null 2>&1; then
  echo "→ installing Docker..."
  curl -fsSL https://get.docker.com | $SUDO sh || die "Docker install failed"
else
  ok "docker binary present"
fi
# Add the invoking user to the docker group (best-effort; the factory steps are
# run under sudo below, which covers the case where the group isn't active yet).
TARGET_USER="${SUDO_USER:-$USER}"
if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
  $SUDO usermod -aG docker "$TARGET_USER" 2>/dev/null \
    && ok "added $TARGET_USER to docker group" \
    || warn "could not add $TARGET_USER to docker group"
fi
# Ensure the daemon is up (systemd box; WSL2 may need `service`).
if command -v systemctl >/dev/null 2>&1; then
  $SUDO systemctl enable --now docker >/dev/null 2>&1 || warn "could not enable docker.service (may already be running)"
else
  $SUDO service docker start >/dev/null 2>&1 || warn "could not start docker"
fi
# Verify docker actually works for the account the factory steps run as.
$SUDO docker info >/dev/null 2>&1 || die "docker daemon is not usable even with sudo — fix docker before re-running"
ok "Docker ready"

# --- 2. k3s ---------------------------------------------------------------------
step "2/6 Bootstrap: k3s (single node)"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  echo "→ installing k3s..."
  curl -sfL https://get.k3s.io | $SUDO sh - || die "k3s install failed"
fi
[[ -f "$KUBECONFIG_PATH" ]] || die "k3s kubeconfig missing at $KUBECONFIG_PATH"
$SUDO chmod 644 "$KUBECONFIG_PATH" 2>/dev/null || warn "could not chmod $KUBECONFIG_PATH (continuing)"
export KUBECONFIG="$KUBECONFIG_PATH"
kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null 2>&1 \
  || warn "node not Ready within 180s (check: kubectl get nodes)"
ok "k3s up ($(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}' | paste -sd, -))"

# --- 3. repos (nested, inside sudo-fleet/; GITHUB_TOKEN optional) ---------------
step "3/6 Repos (nested inside $FLEET_HOME)"
# Source the fleet env FIRST so GITHUB_TOKEN is available for authenticated clone.
[[ -f "$FLEET_ENV" ]] || die "No $FLEET_ENV — run bootstrap.sh first (or drop one with DEEPSEEK_API_KEY, LLM_PROVIDER, API_KEY)."
set +euo pipefail
# shellcheck disable=SC1090
source "$FLEET_ENV"
set -euo pipefail
export GITHUB_TOKEN
_clone_or_pull() {
  local url="$1" dir="$2"
  # Build the clone URL in a var — NEVER echo it if it carries a token.
  # Repos are public, so when GITHUB_TOKEN is unset we clone anonymously.
  local clone_url="$url"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    clone_url="https://x-access-token:${GITHUB_TOKEN}@github.com/${url#https://github.com/}"
  fi
  export GIT_TERMINAL_PROMPT=0
  if [[ -d "$dir/.git" ]]; then
    echo "→ $dir exists — git pull"
    (cd "$dir" && $SUDO git remote set-url origin "$clone_url" && $SUDO git pull --ff-only) || die "git pull failed in $dir"
  else
    echo "→ cloning $url"
    $SUDO git clone "$clone_url" "$dir" || die "git clone failed: $url"
  fi
}
_clone_or_pull "$GH/sudo-agent.git" "$AGENT_REPO"
_clone_or_pull "$GH/sudo-letta.git" "$LETTA_REPO"

# --- 4. API keys (non-interactive) ---------------------------------------------
step "4/6 API keys from $FLEET_ENV"
# (.env was already sourced in step 3; validate + export the API keys here.)
[[ -n "${DEEPSEEK_API_KEY:-}" ]] || die "DEEPSEEK_API_KEY missing in $FLEET_ENV"
[[ -n "${LLM_PROVIDER:-}" ]] || die "LLM_PROVIDER missing in $FLEET_ENV"
[[ -n "${API_KEY:-}" ]] || die "API_KEY missing in $FLEET_ENV"
export DEEPSEEK_API_KEY LLM_PROVIDER API_KEY
[[ -n "${LLM_BASE_URL:-}" ]] && export LLM_BASE_URL
for _wk in EXA_API_KEY TAVILY_API_KEY PARALLEL_API_KEY PERPLEXITY_API_KEY; do
  [[ -n "${!_wk:-}" ]] && export "$_wk"
done
unset _wk
ok "API keys validated + exported"

# --- 5. Non-interactive env-var bridge (the exact mechanism) -------------------
# sudo-agent/setup.sh has an UNCONDITIONAL `read -r -p "Paste your DeepSeek API
# key: "`. Neither an env var nor a pre-seeded .env can skip it — the ONLY way
# to make it non-interactive is to feed the key on STDIN, which `read` consumes.
#
# sudo-letta/setup.sh gates its `read` prompts on `.sudo-letta/.env` NOT already
# holding a non-empty `API_KEY=`. Pre-seeding that file skips the prompts.
step "5/6 Non-interactive env-var bridge"
# (a) sudo-letta: pre-seed .sudo-letta/.env so its prompts are skipped
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
ok "pre-seeded $LETTA_REPO/.sudo-letta/.env (skips letta prompts)"
# (b) sudo-agent: pipe DEEPSEEK_API_KEY on stdin — done inline in step 6.

# Web-search key gate: letta up.sh hard-requires one of these. Warn early rather
# than fail the whole build here — up.sh --marc itself fails loudly if absent.
_have_ws=0
for _wk in EXA_API_KEY TAVILY_API_KEY PARALLEL_API_KEY PERPLEXITY_API_KEY; do
  [[ -n "${!_wk:-}" ]] && _have_ws=1
done
unset _wk
[[ "$_have_ws" -eq 1 ]] || warn "no web-search key (EXA_/TAVILY_/PARALLEL_/PERPLEXITY_) in $FLEET_ENV — sudo-letta up.sh --marc will fail without one"

# --- 6. Build images (factory setup.sh, non-interactive) -----------------------
step "6/6 Build images"
echo "→ sudo-agent (Hermes) image — DEEPSEEK_API_KEY piped on stdin"
printf '%s\n' "$DEEPSEEK_API_KEY" | $SUDO bash "$AGENT_REPO/setup.sh" \
  || die "sudo-agent setup.sh failed"
echo "→ sudo-letta (Letta) image — .env pre-seeded, prompts skipped"
# Belt-and-suspenders: also pipe provider/key/base-url in case the pre-seed did
# not stick; they are simply ignored when no prompt fires.
printf '%s\n%s\n%s\n' "$LLM_PROVIDER" "$API_KEY" "${LLM_BASE_URL:-}" \
  | $SUDO bash "$LETTA_REPO/setup.sh" || die "sudo-letta setup.sh failed"

echo ""
ok "Bootstrap complete (docker + k3s + repos + images)."
echo ""
echo "Next — bring up the cluster and stand up Marc + Caesar:"
echo "    cd $FLEET_HOME/kube-scripts && bash k8s-up.sh"
