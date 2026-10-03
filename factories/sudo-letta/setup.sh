#!/usr/bin/env bash
set -uo pipefail

# sudo-letta/setup.sh — One-time setup: builds Docker image, prompts for API key.

echo "┌─────────────────────────────────────────────┐"
echo "│  sudo-letta — Letta Code with root cage      │"
echo "└─────────────────────────────────────────────┘"
echo ""

# --- Check Docker ---
if ! docker info &>/dev/null; then
  echo "Docker is not running or this user isn't in the docker group."
  echo "Fix: sudo usermod -aG docker \$USER && newgrp docker"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# _retry N "description" cmd [args...] — run cmd up to N times with backoff.
# Makes network/build steps survive transient failures instead of dying once.
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

# --- Build image ---
# Rebuild whenever the build INPUTS changed, not just when the image is absent.
# The inputs are this Dockerfile + every file it COPYs into the image. Their
# combined sha256 is stamped into the image at build time (SOURCE_HASH build
# arg -> sudo-fleet.source-hash label); if the current sources hash to
# something different (or the label is missing — e.g. an image built before
# this mechanism existed, or a stale image from a pre-change-detection setup),
# rebuild. A re-run with unchanged sources skips the build, so idempotent
# re-runs stay fast. This closes the stale-image hole: previously a re-run
# skipped the build whenever the image existed, so a Dockerfile/kube-scripts
# change survived in the old image until the image was manually removed.
_source_hash() {
  ( cd "$SCRIPT_DIR" && \
      cat Dockerfile \
          kube-scripts/letta_prompt.py \
          kube-scripts/mcp_server.py \
          kube-scripts/mcp_entrypoint.sh \
          kube-scripts/watch_sidecar.py \
          kube-scripts/rich_tap.py ) | sha256sum | cut -d' ' -f1
}

CUR_HASH="$(_source_hash)"
IMG_HASH="$(docker image inspect --format '{{index .Config.Labels "sudo-fleet.source-hash"}}' sudo-letta:latest 2>/dev/null || true)"

if [[ -z "$IMG_HASH" || "$IMG_HASH" != "$CUR_HASH" ]]; then
  if [[ -z "$IMG_HASH" ]]; then
    echo "→ Building sudo-letta image (no source-hash label — image predates change detection)..."
  else
    echo "→ Building sudo-letta image (source changed)..."
  fi
  _retry 3 "docker build sudo-letta" docker build --build-arg SOURCE_HASH="$CUR_HASH" -t sudo-letta:latest -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR" || {
    echo "Docker build failed." >&2
    exit 1
  }
  echo "✓ sudo-letta image built"
else
  echo "→ sudo-letta:latest up to date (source unchanged), skipping build"
fi

# --- Create config directory inside the repo ---
# Detect if dir is root-owned and use sudo if needed
_writable() { echo "" >> "$1" 2>/dev/null; }

if ! _writable "$SCRIPT_DIR/.sudo-letta/.env"; then
  USE_SUDO=true
  echo "→ Repo is root-owned. Using sudo to save credentials..."
  sudo mkdir -p "$SCRIPT_DIR/.sudo-letta"
else
  USE_SUDO=false
  mkdir -p "$SCRIPT_DIR/.sudo-letta"
fi

_TRIAL_KEY="rc_9df7149b3116422be0eebaaba5a58b7d8f83fe2b7e3cd64accbd2987b0e6d8f7"

# --- Prompt for API key --
ENV_FILE="$SCRIPT_DIR/.sudo-letta/.env"

if ! grep -q '^API_KEY=' "$ENV_FILE" 2>/dev/null || \
     grep -q '^API_KEY=\s*$' "$ENV_FILE" 2>/dev/null; then
  echo ""
  echo "┌─────────────────────────────────────────────┐"
  echo "│  LLM API Key Required                        │"
  echo "├─────────────────────────────────────────────┤"
  echo "│  Supported providers:                       │"
  echo "│  - OpenAI:       platform.openai.com/api-keys│"
  echo "│  - Anthropic:    console.anthropic.com       │"
  echo "│  - DeepSeek:     platform.deepseek.com/api_keys│"
  echo "│  - OpenRouter:   openrouter.ai/keys          │"
  echo "│  - Or any OpenAI-compatible API              │"
  echo "└─────────────────────────────────────────────┘"
  echo ""
  read -r -p "Provider (e.g. openai, anthropic, deepseek): " PROVIDER
  read -r -p "Paste your API key: " API_KEY

  # --- Trial key detection — refuse to proceed with a known trial key ------
  if [[ -n "${API_KEY}" && "${API_KEY}" == "${_TRIAL_KEY}" ]]; then
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
    unset API_KEY
    read -r -p "Paste your REAL API key (NOT the trial key): " API_KEY
    if [[ -z "${API_KEY}" ]]; then
      echo "No key entered. Setup incomplete — run setup.sh again." >&2
      exit 1
    fi
  fi

  if [[ -z "$PROVIDER" || -z "$API_KEY" ]]; then
    echo "No provider or key entered. Setup incomplete — run setup.sh again."
    exit 1
  fi

  if $USE_SUDO; then
    {
      echo "# sudo-letta config (set by setup.sh)"
      echo "LLM_PROVIDER=$PROVIDER"
      echo "API_KEY=$API_KEY"
    } | sudo tee "$ENV_FILE" > /dev/null
  else
    {
      echo ""
      echo "# sudo-letta config (set by setup.sh)"
      echo "LLM_PROVIDER=$PROVIDER"
      echo "API_KEY=$API_KEY"
    } >> "$ENV_FILE"
  fi

  # If it's an OpenAI-compatible provider, ask for base URL
  if [[ "$PROVIDER" != "anthropic" && "$PROVIDER" != "chatgpt" ]]; then
    read -r -p "Base URL (e.g. https://api.deepseek.com/v1) [leave blank for default]: " BASE_URL
    if [[ -n "$BASE_URL" ]]; then
      if $USE_SUDO; then
        echo "LLM_BASE_URL=$BASE_URL" | sudo tee -a "$ENV_FILE" > /dev/null
      else
        echo "LLM_BASE_URL=$BASE_URL" >> "$ENV_FILE"
      fi
    fi
  fi

  echo "✓ Saved $ENV_FILE"
fi

# --- Create default settings.json template ---
SETTINGS_FILE="$SCRIPT_DIR/.sudo-letta/settings.json"
if [[ ! -f "$SETTINGS_FILE" ]]; then
  if $USE_SUDO; then
    sudo tee "$SETTINGS_FILE" > /dev/null << 'EOF'
{
  "tokenStreaming": true,
  "preferredBackendMode": "local",
  "globalSharedBlockIds": {},
  "permissions": {
    "bash": "allow",
    "read": "allow",
    "write": "allow"
  }
}
EOF
  else
    cat > "$SETTINGS_FILE" << 'EOF'
{
  "tokenStreaming": true,
  "preferredBackendMode": "local",
  "globalSharedBlockIds": {},
  "permissions": {
    "bash": "allow",
    "read": "allow",
    "write": "allow"
  }
}
EOF
  fi
  echo "✓ Created $SETTINGS_FILE"
fi

# --- Shared Redis for the prompt distributor queue ---
# Applied now if kubectl + a cluster are available; otherwise applied on first up.sh deploy.
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
  echo "→ Applying shared Redis (kube-scripts/redis.yaml)..."
  if ! kubectl apply -f "$SCRIPT_DIR/kube-scripts/redis.yaml" --validate=false; then
    echo "✗ FAILED to apply kube-scripts/redis.yaml (shared Redis for the prompt distributor queue). Setup aborted — fix Redis provisioning and re-run setup.sh." >&2
    exit 1
  fi
  echo "✓ Shared Redis applied"
else
  echo "⚠ kubectl/cluster not available yet — shared Redis (kube-scripts/redis.yaml) will be applied on the first up.sh agent deploy."
fi

echo ""
echo "✓ Setup complete"
echo ""
echo "  bash kube-scripts/up.sh --fish      # start agent (generates sudo password)"
echo "  bash kube-scripts/talk.sh --fish    # talk to agent"
echo "  bash kube-scripts/down.sh --fish    # stop agent (memory persists)"
echo ""
