#!/usr/bin/env bash
set -uo pipefail

# sudo-agent/setup.sh — One-time setup: builds Docker image, prompts for the LLM key.

echo "┌─────────────────────────────────────────────┐"
echo "│  sudo-agent — Hermes Agent with root cage   │"
echo "└─────────────────────────────────────────────┘"
echo ""

# Check the docker socket answers, because every later step (image builds,
# image imports, and the deploy itself) goes through docker; if `docker info`
# fails, abort NOW with the fix hint instead of failing mid-build with an
# unhelpful socket error.
if ! docker info &>/dev/null; then
  echo "Docker is not running or this user isn't in the docker group."
  echo "Fix: sudo usermod -aG docker \$USER && newgrp docker"
  exit 1
fi

# Resolve the factory root once, because the Dockerfile, .env and config.yaml
# are all relative to THIS script's location, not the caller's cwd.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# _retry N "description" cmd [args...] — run cmd up to N times with backoff,
# because network/build steps fail transiently and should not die on the first
# hiccup; if the command still fails after N attempts, _retry returns non-zero
# so the caller can abort loudly instead of half-succeeding.
_retry() {
  local n="$1" desc="$2"; shift 2
  local i=1
  while (( i <= n )); do
    if "$@"; then return 0; fi
    echo "⚠ ($desc) attempt $i/$n failed — retrying in ${i}s..." >&2
    sleep "$i"
    (( i++ ))
  done
  return 1
}

# Build the two images if they are absent. Order matters: sudo-agent is
# `FROM hermes-agent:latest`, so the base is built first. The sudo-agent
# Dockerfile then (a) symlinks the base's off-PATH uv onto /usr/local/bin so
# its `uv pip install` steps resolve, and (b) bakes the comm tools into
# /opt/comm-tools/ at the IMAGE level (never shadowed by the /opt/data PVC —
# that PVC only receives the comm skills + persona on first boot, see
# mcp_entrypoint.sh). Each build retries transient network failures; if one
# still fails after retries, abort — a missing image is fatal downstream.
if ! docker image inspect hermes-agent:latest &>/dev/null; then
  echo "→ Building base Hermes Agent image (3-5 min)..."
  TMP_DIR=$(mktemp -d) || { echo "Failed to create temp dir"; exit 1; }
  _retry 3 "git clone hermes-agent" git clone --depth 1 https://github.com/NousResearch/hermes-agent.git "$TMP_DIR" \
    || { echo "Git clone failed. Check internet."; exit 1; }
  _retry 3 "docker build hermes-agent" docker build -t hermes-agent:latest "$TMP_DIR" \
    || { echo "Docker build failed."; exit 1; }
  rm -rf "$TMP_DIR"
  echo "✓ Base image built"
fi

echo "→ Building sudo-agent image..."
_retry 3 "docker build sudo-agent" docker build -t sudo-agent:latest -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR" \
  || { echo "Sudo-agent build failed."; exit 1; }
echo "✓ sudo-agent image built"

# --- Prompt for DeepSeek API key (env-first: never prompt if a key is available) ---
ENV_FILE="$SCRIPT_DIR/.env"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"

# Resolve the key WITHOUT prompting unless necessary:
#   (1) DEEPSEEK_API_KEY / DEEPSEEK_KEY in the environment -> use it, no prompt
#   (2) a non-empty DEEPSEEK_API_KEY already in $ENV_FILE -> reuse it, no prompt
#   (3) otherwise fall back to an interactive read (the sudo-fleet bridge feeds
#       the key on stdin, which this `read` consumes).
DEEPSEEK_KEY="${DEEPSEEK_API_KEY:-${DEEPSEEK_KEY:-}}"
if [[ -z "$DEEPSEEK_KEY" ]] && [[ -f "$ENV_FILE" ]]; then
  DEEPSEEK_KEY="$(sed -n 's/^DEEPSEEK_API_KEY=//p' "$ENV_FILE" 2>/dev/null | head -n1)"
fi
if [[ -z "$DEEPSEEK_KEY" ]]; then
  echo ""
  echo "┌─────────────────────────────────────────────┐"
  echo "│  DeepSeek API Key Required                   │"
  echo "├─────────────────────────────────────────────┤"
  echo "│  Get one free at:                            │"
  echo "│  https://platform.deepseek.com/api_keys      │"
  echo "└─────────────────────────────────────────────┘"
  echo ""
  read -r -p "Paste your DeepSeek API key: " DEEPSEEK_KEY
fi

if [[ -z "$DEEPSEEK_KEY" ]]; then
  echo "No key entered. Setup incomplete — run setup.sh again."
  exit 1
fi

# ── LLM model / provider / base_url — resolve the ONE source of truth ─────────
# Resolved from (1) the environment, (2) this factory's .env, (3) the
# backward-compatible DeepSeek defaults — in that order. The SAME three values
# are consumed by kube-scripts/up.sh, so a Featherless/custom endpoint is
# configured in exactly ONE place (the root .env) and nothing re-pins it here.
_is_custom_endpoint() {
  case "$1" in
    *deepseek*) return 1 ;;
    *featherless*|*openai*|*custom*|*localhost*|*127.0.0.1*) return 0 ;;
    *) return 1 ;;
  esac
}

LLM_MODEL="${LLM_MODEL:-}"
LLM_BASE_URL="${LLM_BASE_URL:-}"
LLM_PROVIDER="${LLM_PROVIDER:-}"
if [[ -f "$ENV_FILE" ]]; then
  [[ -z "$LLM_MODEL" ]]    && LLM_MODEL="$(sed -n 's/^LLM_MODEL=//p' "$ENV_FILE" 2>/dev/null | head -n1)"
  [[ -z "$LLM_BASE_URL" ]] && LLM_BASE_URL="$(sed -n 's/^LLM_BASE_URL=//p' "$ENV_FILE" 2>/dev/null | head -n1)"
  [[ -z "$LLM_PROVIDER" ]] && LLM_PROVIDER="$(sed -n 's/^LLM_PROVIDER=//p' "$ENV_FILE" 2>/dev/null | head -n1)"
fi
# Backward-compatible defaults — used ONLY when the variables are unset.
LLM_BASE_URL="${LLM_BASE_URL:-https://api.deepseek.com/v1}"
LLM_PROVIDER="${LLM_PROVIDER:-deepseek}"
if _is_custom_endpoint "$LLM_BASE_URL"; then
  [[ -z "$LLM_MODEL" ]] && read -r -p "LLM model (required for custom endpoint, e.g. deepseek-ai/DeepSeek-V4-Pro): " LLM_MODEL
else
  LLM_MODEL="${LLM_MODEL:-deepseek-v4-pro}"
fi
if _is_custom_endpoint "$LLM_BASE_URL"; then
  case "$LLM_PROVIDER" in
    deepseek|openai|"") LLM_PROVIDER="custom" ;;
  esac
  echo "→ custom OpenAI-compatible endpoint ($LLM_BASE_URL) — provider '$LLM_PROVIDER'"
fi

# Persist the credentials + LLM contract to .env. The repo dir may be
# root-owned, so a direct append is tried FIRST and only falls back to
# `sudo tee` when that is refused — the sudo/exit-code trap: a root-owned repo
# is a normal state in this factory, not an error. If BOTH paths fail, abort
# with the chown fix instead of continuing with a key that only lives in this
# process's environment and is lost on exit.
# NOTE: the LLM_API_KEY line is the env var a custom_providers entry references
# via `key_env`, so a custom endpoint's key resolves inside the pod.
_ENV_BODY="# sudo-agent config (set by setup.sh)
DEEPSEEK_API_KEY=$DEEPSEEK_KEY
LLM_API_KEY=$DEEPSEEK_KEY
LLM_MODEL=$LLM_MODEL
LLM_PROVIDER=$LLM_PROVIDER
LLM_BASE_URL=$LLM_BASE_URL"
if ! echo "" >> "$ENV_FILE" 2>/dev/null; then
  echo "→ Repo is root-owned. Using sudo to save credentials..."
  printf '%s\n' "$_ENV_BODY" | sudo tee "$ENV_FILE" > /dev/null 2>&1 || {
    echo "✗ Could not write .env. Run: sudo chown -R \$USER:\$USER $SCRIPT_DIR" >&2
    exit 1
  }
else
  printf '%s\n' "$_ENV_BODY" > "$ENV_FILE"
fi
unset _ENV_BODY
echo "✓ API key + LLM contract saved to $ENV_FILE"

# ── config.yaml — converge WITHOUT re-pinning (the drift fix) ────────────────
# OLD BEHAVIOUR (the bug this replaces): on EVERY run this block sed-RE-PINNED
#   model.default -> "deepseek-v4-pro", provider -> "deepseek", and DELETED any
#   `base_url:` line. A working Featherless/custom endpoint was therefore
#   silently clobbered back to DeepSeek every time setup.sh ran.
#
# NEW CONTRACT: provider / base_url / model.default come from LLM_PROVIDER /
# LLM_BASE_URL / LLM_MODEL (resolved above). We only WRITE a value that is not
# already present, we NEVER delete a user's base_url, and the DeepSeek defaults
# are used only when those variables are completely unset (backward compat).
# The LLM keys live at TOP LEVEL (`provider:` / `base_url:`) — not under
# `model:` — because that is the shape Hermes reads, and a custom endpoint needs
# the custom_providers entry emitted below for its Bearer token to be sent.

# _set_root_if_absent KEY VALUE — prepend a top-level `KEY: "VALUE"` line only
# when that top-level key does not already exist. Never rewrites a user value.
_set_root_if_absent() {
  local key="$1" val="$2"
  grep -qE "^${key}:" "$CONFIG_FILE" 2>/dev/null && return 0
  local tmp; tmp="$(mktemp)"
  { printf '%s: "%s"\n' "$key" "$val"; cat "$CONFIG_FILE"; } > "$tmp" \
    && mv "$tmp" "$CONFIG_FILE"
}

# _set_nested_if_absent SECTION KEY VALUE — add `SECTION.KEY: "VALUE"` only when
# no sibling `KEY:` already exists, creating the SECTION if needed. Never
# rewrites a user's value.
_set_nested_if_absent() {
  local section="$1" key="$2" val="$3"
  grep -qE "^[[:space:]]+${key}:" "$CONFIG_FILE" 2>/dev/null && return 0
  local tmp; tmp="$(mktemp)"
  if grep -qE "^${section}:" "$CONFIG_FILE" 2>/dev/null; then
    awk -v s="$section" -v k="$key" -v v="$val" '
      { print }
      $0 == (s ":") && !ins { printf "  %s: \"%s\"\n", k, v; ins=1 }
    ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  else
    { printf '%s:\n  %s: "%s"\n' "$section" "$key" "$val"; cat "$CONFIG_FILE"; } > "$tmp" \
      && mv "$tmp" "$CONFIG_FILE"
  fi
}

if [[ ! -f "$CONFIG_FILE" ]]; then
  # First run: seed ONLY the non-LLM defaults. The LLM keys are written by the
  # convergence below so they always reflect LLM_MODEL/PROVIDER/BASE_URL.
  cat > "$CONFIG_FILE" << 'CONFIGEOF'
terminal:
  backend: "local"
  sudo_password_env: "SUDO_PASSWORD"
memory:
  memory_char_limit: 100000
  user_char_limit: 50000
  memory_enabled: true
  user_profile_enabled: true
  write_approval: false
  nudge_interval: 1
CONFIGEOF
fi

_set_root_if_absent    provider "$LLM_PROVIDER"
_set_root_if_absent    base_url "$LLM_BASE_URL"
_set_nested_if_absent  model    default  "$LLM_MODEL"
_set_nested_if_absent  terminal backend  "local"

# A custom (non-DeepSeek) OpenAI-compatible endpoint must also appear in
# custom_providers, or the Bearer token is never sent. The key is referenced by
# ENV VAR NAME (key_env) — no secret is ever written into config.yaml.
if _is_custom_endpoint "$LLM_BASE_URL" && ! grep -qE '^custom_providers:' "$CONFIG_FILE" 2>/dev/null; then
  cat >> "$CONFIG_FILE" <<CUSTOMEOF
custom_providers:
  - name: "$LLM_PROVIDER"
    base_url: "$LLM_BASE_URL"
    key_env: LLM_API_KEY
    api_mode: openai
    models: ["$LLM_MODEL"]
CUSTOMEOF
fi
echo "✓ config.yaml converged (provider='$LLM_PROVIDER' model='$LLM_MODEL' base_url='$LLM_BASE_URL')"

# --- Shared Redis for the prompt-distributor queue ---
# The queue that serializes concurrent prompts into the agent lives in a SHARED
# Redis (one per fleet, hostNetwork on the node loopback, PVC-backed). It must
# exist BEFORE agents do, so provision it at setup time too — up.sh does the
# same on every deploy, which is what keeps it propagated. Loud on failure: a
# fleet without its queue backing has a dead prompt path.
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
  echo ""
  echo "→ Provisioning the shared queue Redis (kube-scripts/redis-up.sh)..."
  if ! bash "$SCRIPT_DIR/kube-scripts/redis-up.sh"; then
    echo "✗ FAILED to provision the shared Redis (kube-scripts/redis-up.sh)." >&2
    echo "  Setup aborted: agents deployed without it would have a dead prompt queue." >&2
    exit 1
  fi
  echo "✓ Shared queue Redis ready (sudo-agent-redis)"
else
  echo ""
  echo "⚠ No reachable Kubernetes cluster (kubectl missing, or 'kubectl cluster-info' failed)."
  echo "  The shared queue Redis is provisioned automatically by the first deploy:"
  echo "    bash kube-scripts/up.sh --<name>"
fi

echo ""
echo "✓ Setup complete"
echo ""
echo "  bash kube-scripts/up.sh --fish    # start agent (k3s; provisions the queue Redis)"
echo "  bash kube-scripts/talk.sh --fish  # talk to agent"
echo "  bash kube-scripts/down.sh --fish  # stop agent"
