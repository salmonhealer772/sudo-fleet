#!/usr/bin/env bash
set -uo pipefail

# sudo-agent/setup.sh — One-time setup: builds Docker image, prompts for DeepSeek API key.

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

# Persist the key to .env. The repo dir may be root-owned, so a direct append
# is tried FIRST and only falls back to `sudo tee` when that is refused — the
# sudo/exit-code trap: a root-owned repo is a normal state in this factory, not
# an error. If BOTH paths fail, abort with the chown fix instead of continuing
# with a key that only lives in this process's environment and is lost on exit.
if ! echo "" >> "$ENV_FILE" 2>/dev/null; then
  echo "→ Repo is root-owned. Using sudo to save credentials..."
  { echo "# sudo-agent config (set by setup.sh)"; echo "DEEPSEEK_API_KEY=$DEEPSEEK_KEY"; } | sudo tee "$ENV_FILE" > /dev/null 2>&1 || {
    echo "✗ Could not write .env. Run: sudo chown -R \$USER:\$USER $SCRIPT_DIR" >&2
    exit 1
  }
else
  echo "# sudo-agent config (set by setup.sh)" > "$ENV_FILE"
  echo "DEEPSEEK_API_KEY=$DEEPSEEK_KEY" >> "$ENV_FILE"
fi
echo "✓ API key saved to $ENV_FILE"

# Seed config.yaml from the inline template on first run, then pin the model /
# provider / terminal backend on EVERY run (idempotent). A re-run must converge
# to the same config, and a missing config.yaml must never block first boot; if
# the heredoc write fails the later sed pins still apply (they are independent).
if [[ ! -f "$CONFIG_FILE" ]]; then
  cat > "$CONFIG_FILE" << 'CONFIGEOF'
model:
  default: "deepseek-v4-pro"
  provider: "deepseek"
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
else
  sed -i 's|^  default:.*|  default: "deepseek-v4-pro"|' "$CONFIG_FILE"
  sed -i 's|^  provider:.*|  provider: "deepseek"|' "$CONFIG_FILE"
  sed -i 's|^  backend:.*|  backend: "local"|' "$CONFIG_FILE"
  # Remove any stale base_url line
  sed -i '/^  base_url:/d' "$CONFIG_FILE"
fi

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
