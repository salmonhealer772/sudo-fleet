#!/usr/bin/env bash
set -euo pipefail

# sudo-fleet/setup.sh — Command 1 of 2 (bootstrap ONLY).
# Bootstraps a bare Linux box: docker + k3s (single node), prompts for the API
# keys FIRST (writes them to sudo-fleet/.env), clones the two factory repos
# NESTED inside this one folder, and builds both factory images non-interactively.
# It does NOT deploy agents — that is Command 2.
#
#   Command 1 (run from ANY directory — clone + cd + this script):
#     git clone https://github.com/salmonhealer772/sudo-fleet.git && cd sudo-fleet && bash setup.sh
#
#   Command 2:
#     cd kube-scripts && bash k8s-up.sh
#
# Everything this script creates lives INSIDE the single `sudo-fleet/` folder
# (the repo root = FLEET_HOME). No siblings, nothing outside it.
# Prompted here (EXACTLY three fields, written to FLEET_HOME/.env, never echoed):
#     LLM_API_KEY=...          # ONE LLM API key used by BOTH agents (secret)
#     LLM_BASE_URL=...         # LLM API URL (defaults to https://api.deepseek.com/v1 if blank)
#     TAVILY_API_KEY=...       # letta search mods (secret, optional)
#   derived in .env (never prompted):
#     DEEPSEEK_API_KEY=$LLM_API_KEY   # sudo-agent / Hermes
#     API_KEY=$LLM_API_KEY            # sudo-letta / Letta
#     LLM_PROVIDER=<derived from LLM_BASE_URL>   # deepseek|anthropic|openai|...

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

# --- 1. API keys — prompt at the gate (BEFORE any build work) ------------------
step "1/6 API keys (prompt)"
_source_env() {
  set +euo pipefail
  # shellcheck disable=SC1090
  source "$FLEET_ENV"
  set -euo pipefail
}
# The invoking user (for chown, so the .env stays usable by whoever runs this).
TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
# Idempotent: on re-run, keys already in $FLEET_ENV are reused (not re-prompted).
# The tree may be root-owned (sudo git clone), so EVERY .env write goes through
# $SUDO and the file is chowned back to the invoking user so it never fails.
if [[ -f "$FLEET_ENV" ]]; then
  _source_env
  ok "reusing existing keys from $FLEET_ENV"
else
  $SUDO touch "$FLEET_ENV"
fi
$SUDO chown "$TARGET_USER" "$FLEET_ENV" 2>/dev/null || warn "could not chown $FLEET_ENV to $TARGET_USER"
$SUDO chmod 600 "$FLEET_ENV" 2>/dev/null || warn "could not chmod 600 $FLEET_ENV"

# Write one key=value line to $FLEET_ENV only if that key isn't already present,
# so re-runs are idempotent (no re-prompt, no duplicate lines). Secrets never echo.
_write_env() {
  local line="$1" key="${1%%=*}"
  [[ -n "${!key:-}" ]] && return
  printf '%s\n' "$line" | $SUDO tee -a "$FLEET_ENV" >/dev/null
}

# --- (1) ONE key used by BOTH agents ------------------------------------------
if [[ -n "${LLM_API_KEY:-}" ]]; then
  _KEY="${LLM_API_KEY}"
  ok "LLM_API_KEY already set — reusing"
elif [[ -n "${DEEPSEEK_API_KEY:-}" || -n "${API_KEY:-}" ]]; then
  _KEY="${DEEPSEEK_API_KEY:-$API_KEY}"
  ok "LLM_API_KEY derived from existing key — reusing"
else
  read -rs -p "LLM API key: " _KEY || die "read failed for LLM_API_KEY"
  echo ""
  [[ -n "$_KEY" ]] || warn "LLM_API_KEY not provided — you can add it to $FLEET_ENV later."
fi

# --- (2) LLM API URL — defaults to deepseek if left blank (plain) -------------
if [[ -n "${LLM_BASE_URL:-}" ]]; then
  _BASE_URL="${LLM_BASE_URL}"
  ok "LLM API URL already set ($_BASE_URL) — reusing"
else
  read -r -p "LLM API URL [default: https://api.deepseek.com/v1]: " _BASE_URL || die "read failed for LLM API URL"
  _BASE_URL="${_BASE_URL:-https://api.deepseek.com/v1}"
fi

# --- Provider is DERIVED from the URL, never prompted --------------------------
# deepseek -> deepseek; anthropic -> anthropic; openai -> openai; else openai.
case "$_BASE_URL" in
  *deepseek*)  _PROVIDER="deepseek"  ;;
  *anthropic*) _PROVIDER="anthropic" ;;
  *openai*)    _PROVIDER="openai"    ;;
  *)           _PROVIDER="openai"    ;;
esac

# --- (3) Tavily API key — letta search mods (secret, optional) ---------------
if [[ -n "${TAVILY_API_KEY:-}" ]]; then
  _WS_KEY="$TAVILY_API_KEY"
  ok "TAVILY_API_KEY already set — reusing"
else
  read -rs -p "Tavily API key (optional): " _WS_KEY || die "read failed for TAVILY_API_KEY"
  echo ""
  [[ -n "$_WS_KEY" ]] || warn "TAVILY_API_KEY not provided — you can add it to $FLEET_ENV later."
fi

# Backend derivation: map the ONE key + derived provider into the factory vars.
_write_env "DEEPSEEK_API_KEY=${_KEY}"
_write_env "LLM_PROVIDER=${_PROVIDER}"
_write_env "API_KEY=${_KEY}"
_write_env "LLM_BASE_URL=${_BASE_URL}"
_write_env "TAVILY_API_KEY=${_WS_KEY}"

# Re-source so every key (prompted or pre-existing) is exported fresh below.
_source_env

# Validate required + export for the factory build steps. Missing "required"
# keys are DOWNGRADED to warn (never die): export whatever IS present, skip
# empty, and let the factory build steps (step 6) fail loudly on their own
# if a key is truly needed. Do NOT block the whole script at step 1.
[[ -n "${DEEPSEEK_API_KEY:-}" ]] || warn "DEEPSEEK_API_KEY missing — you can add it to $FLEET_ENV later"
[[ -n "${LLM_PROVIDER:-}" ]]      || warn "LLM_PROVIDER missing — you can add it to $FLEET_ENV later"
[[ -n "${API_KEY:-}" ]]           || warn "API_KEY missing — you can add it to $FLEET_ENV later"
[[ -n "${DEEPSEEK_API_KEY:-}" ]] && export DEEPSEEK_API_KEY
[[ -n "${LLM_PROVIDER:-}" ]]      && export LLM_PROVIDER
[[ -n "${API_KEY:-}" ]]           && export API_KEY
[[ -n "${LLM_BASE_URL:-}" ]] && export LLM_BASE_URL
_have_ws=0
for _wk in EXA_API_KEY TAVILY_API_KEY PARALLEL_API_KEY PERPLEXITY_API_KEY; do
  if [[ -n "${!_wk:-}" ]]; then
    export "$_wk"
    _have_ws=1
  fi
done
unset _wk
[[ "$_have_ws" -eq 1 ]] || warn "no web-search key (EXA_/TAVILY_/PARALLEL_/PERPLEXITY_) in $FLEET_ENV — sudo-letta up.sh --marc will fail without one"
ok "API keys validated + exported"

# --- 2. Docker ------------------------------------------------------------------
step "2/6 Bootstrap: Docker"
if ! command -v docker >/dev/null 2>&1; then
  echo "→ installing Docker..."
  curl -fsSL https://get.docker.com | $SUDO sh || die "Docker install failed"
else
  ok "docker binary present"
fi
# Add the invoking user to the docker group (best-effort; the factory steps are
# run under sudo below, which covers the case where the group isn't active yet).
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

# --- 3. k3s ---------------------------------------------------------------------
step "3/6 Bootstrap: k3s (single node)"
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

# --- 4. Repos (nested clones inside $FLEET_HOME) -------------------------------
step "4/6 Repos (nested inside $FLEET_HOME)"
$SUDO mkdir -p "$FLEET_HOME"
_clone_or_pull() {
  local url="$1" dir="$2"
  export GIT_TERMINAL_PROMPT=0
  if [[ -d "$dir/.git" ]]; then
    echo "→ $dir exists — git pull"
    (cd "$dir" && $SUDO git remote set-url origin "$url" && $SUDO git pull --ff-only) || die "git pull failed in $dir"
  else
    echo "→ cloning $url"
    $SUDO git clone "$url" "$dir" || die "git clone failed: $url"
  fi
}
_clone_or_pull "$GH/sudo-agent.git" "$AGENT_REPO"
_clone_or_pull "$GH/sudo-letta.git" "$LETTA_REPO"
ok "factory repos nested under $FLEET_HOME"

# --- 5. Non-interactive env-var bridge (the exact mechanism) -------------------
# sudo-agent/setup.sh has an UNCONDITIONAL `read -r -p "Paste your DeepSeek API
# key: "`. Neither an env var nor a pre-seeded .env can skip it — the ONLY way
# to make it non-interactive is to feed the key on STDIN, which `read` consumes.
#
# sudo-letta/setup.sh gates its `read` prompts on `.sudo-letta/.env` NOT already
# holding a non-empty `API_KEY=`. Pre-seeding that file skips the prompts.
step "5/6 Non-interactive env-var bridge"
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

# --- 6. Build images (factory setup.sh, non-interactive) -----------------------
step "6/6 Build images"
echo "→ sudo-agent (Hermes) image — DEEPSEEK_API_KEY piped on stdin"
printf '%s\n' "$DEEPSEEK_API_KEY" | $SUDO bash "$AGENT_REPO/setup.sh" \
  || die "sudo-agent setup.sh failed"
echo "→ sudo-letta (Letta) image — .env pre-seeded, prompts skipped"
printf '%s\n%s\n%s\n' "$LLM_PROVIDER" "$API_KEY" "${LLM_BASE_URL:-}" \
  | $SUDO bash "$LETTA_REPO/setup.sh" || die "sudo-letta setup.sh failed"

echo ""
ok "Bootstrap complete (docker + k3s + repos + images)."
echo ""
echo "Next — bring up the cluster and stand up Marc + Caesar:"
echo "    cd $FLEET_HOME/kube-scripts && bash k8s-up.sh"
