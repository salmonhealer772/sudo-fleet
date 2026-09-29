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
# Prompted here (EXACTLY three fields, written to FLEET_HOME/.env, chmod 600):
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

GH="https://github.com/salmonhealer772"

die()  { echo "✗ $*" >&2; exit 1; }
step() { echo ""; echo "── $* ──"; }
ok()   { echo "✓ $*"; }
warn() { echo "⚠ $*" >&2; }

# _retry N "description" cmd [args...] — run cmd up to N times with backoff.
# Returns 0 on the first success, 1 after N failures (caller decides to die).
# Makes network/build steps survive transient failures instead of dying once.
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

# Read one full line from stdin and echo it back. tty-agnostic: no -s, no
# /dev/tty, no echo suppression — so typed input is ALWAYS accepted. The keys
# land in a chmod-600 file, so plain echo is safe and reliable.
_ask() {
  # $1 = prompt label; reads one full line from stdin, echoes exactly what is typed.
  printf '%s' "$1 " >&2
  IFS= read -r REPLY
  printf '%s' "$REPLY"
}

# --- root/sudo -----------------------------------------------------------------
is_root() { [[ "$(id -u)" -eq 0 ]]; }
SUDO=""
if ! is_root; then
  SUDO="sudo"
  echo "→ Warming up sudo (you may be prompted once for your password)..."
  # Prime sudo non-interactively FIRST: succeeds when credentials are already
  # cached (passwordless sudo, or a recent sudo) without hanging on a hidden
  # prompt. Only fall back to an interactive prompt when stdin is a real TTY;
  # otherwise fail LOUD with the right command instead of dying cryptically.
  if ! sudo -n -v 2>/dev/null; then
    if [[ -t 0 ]]; then
      sudo -v || die "sudo authentication failed — this script needs sudo to install docker/k3s"
    else
      die "sudo needs a password but there is no TTY and no cached credential. Run this script in a terminal (so sudo can prompt you), pre-authenticate with 'sudo -v', or run as root."
    fi
  fi
  # Keep the sudo timestamp alive for the whole run: long docker/k3s installs +
  # image builds can outlive sudo's default 15-minute timeout, after which a
  # later $SUDO call would re-prompt (and fail/hang when stdin is a pipe). Renew
  # every 60s so the cache never expires mid-run.
  ( while true; do sudo -n -v 2>/dev/null || break; sleep 60; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap '[[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT
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
  _KEY="$(_ask "LLM API key:")"
  [[ -n "$_KEY" ]] || warn "LLM_API_KEY not provided — you can add it to $FLEET_ENV later."
fi

# --- (2) LLM API URL — defaults to deepseek if left blank (plain) -------------
if [[ -n "${LLM_BASE_URL:-}" ]]; then
  _BASE_URL="${LLM_BASE_URL}"
  ok "LLM API URL already set ($_BASE_URL) — reusing"
else
  _BASE_URL="$(_ask "LLM API URL [default https://api.deepseek.com/v1]:")"
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
  _WS_KEY="$(_ask "Tavily API key (optional):")"
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
    export "$_wk=${!_wk}"
    _have_ws=1
  fi
done
unset _wk
[[ "$_have_ws" -eq 1 ]] || warn "no web-search key (EXA_/TAVILY_/PARALLEL_/PERPLEXITY_) in $FLEET_ENV — sudo-letta up.sh --marc will fail without one"
ok "API keys validated + exported"

# --- 2. Docker ------------------------------------------------------------------
step "2/6 Bootstrap: Docker"
_bootstrap_docker() {
  curl -fsSL https://get.docker.com | $SUDO sh
}
if ! command -v docker >/dev/null 2>&1; then
  echo "→ installing Docker..."
  if ! _retry 3 "docker install (get.docker.com)" _bootstrap_docker; then
    warn "get.docker.com failed 3x — falling back to apt install docker.io..."
    _retry 3 "docker install (apt)" $SUDO apt-get install -y -qq docker.io \
      || die "Docker install failed (both get.docker.com and apt)"
  fi
else
  ok "docker binary present"
fi
# Add the invoking user to the docker group (best-effort; the factory steps are
# run under sudo below, which covers the case where the group isn't active yet).
if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
  if $SUDO usermod -aG docker "$TARGET_USER" 2>/dev/null; then
    ok "added $TARGET_USER to docker group"
  else
    warn "could not add $TARGET_USER to docker group"
  fi
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
_bootstrap_k3s() {
  curl -sfL https://get.k3s.io | $SUDO sh -
}
# Direct-binary fallback: download the release binary and run `k3s server` from
# it, mirroring get.k3s.io closely enough to recover from a blocked installer.
_install_k3s_binary() {
  local arch; arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
  esac
  curl -sfL "https://github.com/k3s-io/k3s/releases/latest/download/k3s" -o /tmp/k3s \
    && $SUDO install -m 755 /tmp/k3s /usr/local/bin/k3s
}
if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  echo "→ installing k3s..."
  if ! _retry 3 "k3s install (get.k3s.io)" _bootstrap_k3s; then
    warn "get.k3s.io failed 3x — falling back to direct binary download..."
    _retry 3 "k3s install (direct binary)" _install_k3s_binary \
      || die "k3s install failed (both get.k3s.io and direct binary)"
    $SUDO /usr/local/bin/k3s server --write-kubeconfig-mode 644 >/tmp/k3s-server.log 2>&1 &
    # Wait for the direct-binary server to write its kubeconfig.
    for _i in $(seq 1 30); do
      [[ -f "$KUBECONFIG_PATH" ]] && break
      sleep 2
    done
  fi
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
_git_pull() {
  local dir="$1" url="$2"
  (cd "$dir" && $SUDO git remote set-url origin "$url" && $SUDO git pull --ff-only)
}
_clone_or_pull() {
  local url="$1" dir="$2"
  export GIT_TERMINAL_PROMPT=0
  if [[ -d "$dir/.git" ]]; then
    echo "→ $dir exists — git pull"
    _retry 3 "git pull $dir" _git_pull "$dir" "$url" || die "git pull failed in $dir"
  else
    echo "→ cloning $url"
    _retry 3 "git clone $dir" $SUDO git clone "$url" "$dir" || die "git clone failed: $url"
  fi
}
_clone_or_pull "$GH/sudo-agent.git" "$AGENT_REPO"
_clone_or_pull "$GH/sudo-letta.git" "$LETTA_REPO"
# The nested clones ran under sudo -> they are root-owned. Chown them back to the
# invoking user so later non-root steps (Command 2, git pulls, edits) don't hit
# "Permission denied" or git "dubious ownership".
if [[ -n "${TARGET_USER:-}" && "$TARGET_USER" != "root" ]]; then
  $SUDO chown -R "$TARGET_USER" "$AGENT_REPO" "$LETTA_REPO" 2>/dev/null \
    || warn "could not chown nested repos to $TARGET_USER"
fi
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
