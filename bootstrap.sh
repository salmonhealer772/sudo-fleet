#!/usr/bin/env bash
set -euo pipefail

# sudo-fleet/bootstrap.sh — Command 1 entry point. Fetched via:
#   curl -fsSL https://raw.githubusercontent.com/salmonhealer772/sudo-fleet/main/bootstrap.sh | bash
# Run from WHATEVER directory you choose. It prompts for the keys FIRST, then
# clones the repo into ./sudo-fleet/, writes the keys to ./sudo-fleet/.env, and
# hands off to setup.sh. Self-contained — depends on nothing but curl/git/bash.

FLEET_REPO_URL="https://github.com/salmonhealer772/sudo-fleet.git"
FLEET_DIR="sudo-fleet"

echo ""
echo "── sudo-fleet bootstrap ──"
echo "Keys are collected FIRST, before anything is cloned or installed."
echo "Leave optional fields empty (just press Enter) to skip."

# --- keys FIRST -----------------------------------------------------------------
read -r -p "GITHUB_TOKEN (optional — repos are public): " GITHUB_TOKEN
read -r -p "DEEPSEEK_API_KEY (required): " DEEPSEEK_API_KEY
read -r -p "LLM_PROVIDER (required, e.g. deepseek): " LLM_PROVIDER
read -r -p "API_KEY (required): " API_KEY
read -r -p "LLM_BASE_URL (optional): " LLM_BASE_URL
read -r -p "TAVILY_API_KEY (optional — web search; EXA_/PARALLEL_/PERPLEXITY_ also work): " TAVILY_API_KEY

# --- validate required ----------------------------------------------------------
[[ -n "${DEEPSEEK_API_KEY:-}" ]] || { echo "✗ DEEPSEEK_API_KEY is required" >&2; exit 1; }
[[ -n "${LLM_PROVIDER:-}" ]]    || { echo "✗ LLM_PROVIDER is required" >&2; exit 1; }
[[ -n "${API_KEY:-}" ]]         || { echo "✗ API_KEY is required" >&2; exit 1; }
[[ -n "${TAVILY_API_KEY:-}" ]]  || echo "⚠ no web-search key — sudo-letta up.sh --marc will need one later" >&2

# --- clone (idempotent) ----------------------------------------------------------
if [[ -d "$FLEET_DIR/.git" ]]; then
  echo "→ $FLEET_DIR/ already exists — reusing it"
else
  echo "→ cloning sudo-fleet into ./$FLEET_DIR/"
  git clone "$FLEET_REPO_URL" "$FLEET_DIR" || { echo "✗ git clone failed" >&2; exit 1; }
fi

# --- write keys into the one folder (never echo them) ----------------------------
echo "→ writing keys to ./$FLEET_DIR/.env"
{
  [[ -n "${GITHUB_TOKEN:-}" ]] && printf 'GITHUB_TOKEN=%s\n' "$GITHUB_TOKEN"
  printf 'DEEPSEEK_API_KEY=%s\n' "$DEEPSEEK_API_KEY"
  printf 'LLM_PROVIDER=%s\n' "$LLM_PROVIDER"
  printf 'API_KEY=%s\n' "$API_KEY"
  [[ -n "${LLM_BASE_URL:-}" ]] && printf 'LLM_BASE_URL=%s\n' "$LLM_BASE_URL"
  [[ -n "${TAVILY_API_KEY:-}" ]] && printf 'TAVILY_API_KEY=%s\n' "$TAVILY_API_KEY"
} > "$FLEET_DIR/.env"

# --- hand off to setup.sh --------------------------------------------------------
cd "$FLEET_DIR"
exec bash setup.sh
