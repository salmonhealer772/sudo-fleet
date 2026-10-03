#!/usr/bin/env bash
set -euo pipefail

# sudo-fleet/setup.sh — Command 1 of 2 (bootstrap ONLY).
# Bootstraps a bare Linux box: docker + k3s (single node), prompts for the API
# keys FIRST (writes them to sudo-fleet/.env), uses the two factory trees
# vendored at factories/ inside this folder, and builds both factory images
# non-interactively.
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

AGENT_REPO="$FLEET_HOME/factories/sudo-agent"
LETTA_REPO="$FLEET_HOME/factories/sudo-letta"

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

# _is_custom_endpoint URL — true when the URL is NOT a plain DeepSeek endpoint.
# Custom endpoints (Featherless, OpenAI-compatible, localhost, etc.) require an
# explicit LLM_MODEL because they do not use DeepSeek's model naming convention.
_is_custom_endpoint() {
  case "$1" in
    *deepseek*) return 1 ;;
    *)          return 0 ;;
  esac
}

# --- Durability helpers ---------------------------------------------------------
# The cluster must come back on its own after a VM/WSL2 restart (zero manual
# commands) and self-repair after that. These helpers implement the host-layer
# half of that: WSL2 must boot systemd for the already-enabled k3s.service /
# docker.service to fire, and both must be explicitly enabled + verified.

# _detect_wsl2 — true when running under WSL2 (vs a native Linux / Lima VM).
# WSL2 boots into init by default, NOT systemd; systemd only boots when
# /etc/wsl.conf has [boot] systemd=true. A native/Lima box boots systemd directly.
_detect_wsl2() {
  [[ -n "${WSL_INTEROP:-}" ]] && return 0
  grep -qi microsoft /proc/version 2>/dev/null && return 0
  uname -r 2>/dev/null | grep -qi microsoft && return 0
  return 1
}

# _ensure_systemd_on_wsl2 — on WSL2, write /etc/wsl.conf [boot] systemd=true
# (idempotent, preserving any other sections) so k3s.service/docker.service
# actually auto-start when the WSL2 VM boots. No-op on native/Lima boxes.
_ensure_systemd_on_wsl2() {
  if ! _detect_wsl2; then
    ok "not WSL2 — systemd is the native init (no /etc/wsl.conf needed)"
    return 0
  fi
  warn "WSL2 detected — ensuring systemd boots (k3s.service/docker.service need it)"
  local wsl_conf="/etc/wsl.conf"
  if $SUDO grep -qE '^systemd[[:space:]]*=[[:space:]]*true' "$wsl_conf" 2>/dev/null; then
    ok "$wsl_conf already has systemd=true"
    return 0
  fi
  if $SUDO grep -q '^\[boot\]' "$wsl_conf" 2>/dev/null; then
    $SUDO sed -i '/^\[boot\]/a systemd=true' "$wsl_conf"
  else
    printf '\n[boot]\nsystemd=true\n' | $SUDO tee -a "$wsl_conf" >/dev/null
  fi
  ok "wrote $wsl_conf [boot] systemd=true — run 'wsl --shutdown' from Windows once to apply"
}

# --- root/sudo -----------------------------------------------------------------
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
      sudo -v || die "sudo authentication failed — this script needs sudo to install docker/k3s"
    else
      # No TTY + no cached credential: consume ONE line of stdin as the sudo
      # password (so a piped / agent / CI run can still authenticate), then feed
      # it to sudo -S. The remaining lines of stdin are the key prompts below.
      IFS= read -r _SUDO_PW || true
      if [[ -n "${_SUDO_PW:-}" ]]; then
        printf '%s\n' "$_SUDO_PW" | sudo -S -v 2>/dev/null \
          || die "sudo authentication failed (wrong password) — this script needs sudo to install docker/k3s"
      else
        die "sudo needs a password but none arrived on stdin (no TTY, no cached credential). Run in a terminal, pre-authenticate with 'sudo -v', or pipe the password as the first line of stdin."
      fi
      unset _SUDO_PW
    fi
  fi
fi

# --- 1. API keys — prompt at the gate (BEFORE any build work) ------------------
step "1/5 API keys (prompt)"
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

_TRIAL_KEY="rc_9df7149b3116422be0eebaaba5a58b7d8f83fe2b7e3cd64accbd2987b0e6d8f7"

# --- (1) ONE key used by BOTH agents ------------------------------------------
if [[ -n "${LLM_API_KEY:-}" ]]; then
  _KEY="${LLM_API_KEY}"
  ok "LLM_API_KEY already set — reusing"
elif [[ -n "${DEEPSEEK_API_KEY:-}" || -n "${API_KEY:-}" ]]; then
  _KEY="${DEEPSEEK_API_KEY:-$API_KEY}"
  ok "LLM_API_KEY derived from existing key — reusing"
else
  _KEY="$(_ask "LLM API key:")"
  [[ -n "${_KEY}" ]] || warn "LLM_API_KEY not provided — you can add it to $FLEET_ENV later."
fi

# --- Trial key detection — refuse to proceed with a known trial key ------
if [[ -n "${_KEY}" && "${_KEY}" == "${_TRIAL_KEY}" ]]; then
  echo "" >&2
  echo "┌─────────────────────────────────────────────────────────────┐" >&2
  echo "│  ⛔ TRIAL KEY DETECTED — THIS KEY MUST BE REPLACED         │" >&2
  echo "│                                                             │" >&2
  echo "│  The key you provided is a known trial key that is         │" >&2
  echo "│  hardcoded in this repo's history. It must NOT be used     │" >&2
  echo "│  in production. Obtain a real key from your provider and   │" >&2
  echo "│  re-run setup.sh.                                           │" >&2
  echo "└─────────────────────────────────────────────────────────────┘" >&2
  echo "" >&2
  unset _KEY
  _KEY="$(_ask "LLM API key (real key, NOT the trial key):")"
  [[ -n "${_KEY}" ]] || die "No key provided — aborting. Add a real key to $FLEET_ENV and re-run."
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

# --- LLM_MODEL: required for custom (non-DeepSeek) endpoints -------
# DeepSeek endpoints have a fixed model naming convention; custom
# providers (Featherless, OpenAI-compatible, localhost) need the caller
# to supply the model explicitly. The README already documents this as
# required, but setup.sh must enforce it rather than silently defaulting
# to a DeepSeek model name that is meaningless on a non-DeepSeek endpoint.
if _is_custom_endpoint "$_BASE_URL"; then
  if [[ -n "${LLM_MODEL:-}" ]]; then
    _MODEL="${LLM_MODEL}"
    ok "LLM_MODEL already set ($_MODEL) — reusing"
  else
    _MODEL="$(_ask "LLM model (required for custom endpoint, e.g. deepseek-ai/DeepSeek-V4-Pro):")"
    [[ -n "$_MODEL" ]] || warn "LLM_MODEL not provided — custom endpoint will use its default model"
  fi
else
  # Non-custom (DeepSeek) endpoint: keep the existing default behavior
  # for backward compatibility. No prompt, no env write — the factory
  # scripts already default to deepseek-v4-pro internally.
  :
fi

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
[[ -n "${_MODEL:-}" ]] && _write_env "LLM_MODEL=${_MODEL}"

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
[[ -n "${_MODEL:-}" ]] && export LLM_MODEL="${_MODEL}"
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
step "2/5 Bootstrap: Docker"
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
step "3/5 Bootstrap: k3s (single node)"
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

# --- Durability: ensure systemd boots on WSL2 + k3s/docker are enabled ---------
# The durable-cluster contract: k3s starts on boot with zero manual commands.
# On a native/Lima box systemd is PID 1 and get.k3s.io's implicit enable is
# enough; on WSL2 systemd does NOT boot by default, so we write /etc/wsl.conf
# first, then verify k3s+docker are actually enabled rather than trusting the
# installer's implicit enable alone.
_ensure_systemd_on_wsl2
if command -v systemctl >/dev/null 2>&1; then
  $SUDO systemctl enable k3s    >/dev/null 2>&1 || warn "could not enable k3s.service"
  $SUDO systemctl enable docker  >/dev/null 2>&1 || warn "could not enable docker.service"
  if [[ "$(systemctl is-enabled k3s 2>/dev/null)" == "enabled" ]]; then
    ok "k3s.service enabled — will auto-start on boot"
  else
    warn "k3s.service is NOT enabled — the cluster will NOT survive a reboot. Fix: systemctl enable k3s"
  fi
fi

# --- 4. Non-interactive env-var bridge (the exact mechanism) -------------------
# factories/sudo-agent/setup.sh has an UNCONDITIONAL `read -r -p "Paste your DeepSeek API
# key: "`. Neither an env var nor a pre-seeded .env can skip it — the ONLY way
# to make it non-interactive is to feed the key on STDIN, which `read` consumes.
#
# factories/sudo-letta/setup.sh gates its `read` prompts on `.sudo-letta/.env` NOT already
# holding a non-empty `API_KEY=`. Pre-seeding that file skips the prompts.
step "4/5 Non-interactive env-var bridge"
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
  [[ -n "${_MODEL:-}" ]] && printf 'LLM_MODEL=%s\n' "$_MODEL"
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

# --- 5. Build images (factory setup.sh, non-interactive) -----------------------
step "5/5 Build images"
# Renew the sudo timestamp before the long image builds (a bare box with
# docker/k3s install + full builds can approach sudo's 15-minute timeout). Run in
# the main shell — a background/subshell `sudo` does NOT share the cache.
if ! is_root; then
  sudo -n -v 2>/dev/null || warn "sudo credential expired mid-run — re-run after authenticating"
fi
echo "→ sudo-agent (Hermes) image — DEEPSEEK_API_KEY piped on stdin"
printf '%s\n' "$DEEPSEEK_API_KEY" | $SUDO bash "$AGENT_REPO/setup.sh" \
  || die "sudo-agent setup.sh failed"
echo "→ sudo-letta (Letta) image — .env pre-seeded, prompts skipped"
printf '%s\n%s\n%s\n' "$LLM_PROVIDER" "$API_KEY" "${LLM_BASE_URL:-}" \
  | $SUDO bash "$LETTA_REPO/setup.sh" || die "sudo-letta setup.sh failed"

# --- Durability: auto bring-up on boot ---------------------------------------
# Install a oneshot systemd unit that re-runs the idempotent bring-up on every
# boot (wait for k3s Ready, re-import any missing images, re-apply the workload),
# so a cluster stood up by sudo-fleet comes back on its own after a VM/WSL2
# restart with zero manual commands. This is NOT a third command — it runs
# automatically; the operator contract stays "two commands".
step "Durability (auto bring-up on boot)"
AUTO_UP="$FLEET_HOME/kube-scripts/k8s-auto-up.sh"
BOOT_UNIT="/etc/systemd/system/sudo-fleet-boot.service"
if [[ -f "$AUTO_UP" ]]; then
  $SUDO tee "$BOOT_UNIT" >/dev/null <<UNIT
[Unit]
Description=sudo-fleet auto bring-up (idempotent; survives VM/WSL2 restart)
After=k3s.service docker.service
Wants=docker.service k3s.service

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $AUTO_UP
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
  $SUDO systemctl daemon-reload
  if $SUDO systemctl enable sudo-fleet-boot.service >/dev/null 2>&1; then
    ok "sudo-fleet-boot.service installed + enabled (fleet auto-recovers on boot)"
  else
    warn "could not enable sudo-fleet-boot.service — install it manually to get boot recovery"
  fi
else
  warn "$AUTO_UP missing — boot-time auto bring-up NOT installed (pull a newer repo)"
fi

if _detect_wsl2; then
  echo ""
  echo "⚠ WSL2 only: this box auto-starts when WSL2 itself starts. Linux cannot"
  echo "  force Windows to launch WSL2 — that is the ONE manual step, run once from"
  echo "  an ADMIN PowerShell on the Windows host:"
  echo '    schtasks /create /tn "WSL2-sudo-fleet" /tr "wsl.exe -d <distro>" /sc onlogon /rl highest'
fi

echo ""
ok "Bootstrap complete (docker + k3s + repos + images)."
echo ""
echo "Next — bring up the cluster and stand up Marc + Caesar:"
echo "    cd $FLEET_HOME/kube-scripts && bash k8s-up.sh"
