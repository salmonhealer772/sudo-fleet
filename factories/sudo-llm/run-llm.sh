#!/usr/bin/env bash
set -euo pipefail

# Serve Qwen3.5-9B Q4_K_M on the RTX 4070 (8GB) via llama.cpp, CUDA 12.6.
# Host network, port 8080 — the sudo-letta agent pod is hostNetwork, so it
# reaches this at http://127.0.0.1:8080/v1. Also exposed as an in-cluster
# Service `sudo-llm` (see computer-bot/sudo-llm-service.yaml).

MODEL_DIR="${MODEL_DIR:-/opt/computer-bot/models}"
MODEL_FILE="Qwen_Qwen3.5-9B-Q4_K_M.gguf"
MODEL_PATH="$MODEL_DIR/$MODEL_FILE"

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "✗ model missing at $MODEL_PATH — download it first (see computer-bot/README.md)" >&2
  exit 1
fi

if ! docker image inspect sudo-llm:latest >/dev/null 2>&1; then
  echo "✗ sudo-llm:latest image missing — build it first: docker build -t sudo-llm:latest factories/sudo-llm" >&2
  exit 1
fi

docker rm -f sudo-llm >/dev/null 2>&1 || true

docker run -d \
  --name sudo-llm \
  --gpus all \
  --network host \
  --restart unless-stopped \
  -v "$MODEL_DIR":/models \
  sudo-llm:latest \
  --model "/models/$MODEL_FILE" \
  --alias qwen3.5-9b \
  --ctx-size 16384 \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --flash-attn on \
  --parallel 1 \
  --port 8080 \
  --host 0.0.0.0

echo "✓ sudo-llm started. OpenAI-compatible endpoint: http://127.0.0.1:8080/v1"
echo "  health:  curl -s http://127.0.0.1:8080/health"
echo "  models:  curl -s http://127.0.0.1:8080/v1/models"
