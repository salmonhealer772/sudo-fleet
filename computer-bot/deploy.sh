#!/usr/bin/env bash
set -euo pipefail
# computer-bot — deploy the local-LLM artifact agent node end to end.
# Run ON the laptop (compooper) as root, with k3s + docker already up.
#
#   bash computer-bot/deploy.sh

FLEET_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
WORKSPACE="${WORKSPACE:-/opt/computer-bot}"
MODEL_FILE="Qwen_Qwen3.5-9B-Q4_K_M.gguf"

echo "── 1/6 prompt bank -> host workspace ──"
mkdir -p "$WORKSPACE/prompts" "$WORKSPACE/artifacts" "$WORKSPACE/state"
cp -n "$FLEET_HOME/computer-bot/prompts/"*.md "$WORKSPACE/prompts/" 2>/dev/null || true
echo "  prompts: $(ls "$WORKSPACE/prompts"/*.md | wc -l)"

echo "── 2/6 build llama.cpp CUDA 12.6 server image ──"
docker build -t sudo-llm:latest -f "$FLEET_HOME/factories/sudo-llm/Dockerfile" "$FLEET_HOME/factories/sudo-llm"

echo "── 3/6 serve Qwen3.5-9B on the GPU (host network, :8080) ──"
[[ -f "$WORKSPACE/models/$MODEL_FILE" ]] || { echo "✗ model missing at $WORKSPACE/models/$MODEL_FILE" >&2; exit 1; }
MODEL_DIR="$WORKSPACE/models" bash "$FLEET_HOME/factories/sudo-llm/run-llm.sh"

echo "── 4/6 in-cluster Service sudo-llm ──"
kubectl apply -f "$FLEET_HOME/computer-bot/sudo-llm-service.yaml"

echo "── 5/6 deploy Letta agent sudo-computer-bot (workspace mount) ──"
bash "$FLEET_HOME/factories/sudo-letta/bin/up.sh" --computer-bot --workspace "$WORKSPACE"

echo "── 6/6 Paperclip control plane + hire @900s heartbeat ──"
if [[ ! -f /logs/paperclip/paperclip.env ]]; then
  bash "$FLEET_HOME/bin/paperclip-up.sh"
fi
bash "$FLEET_HOME/bin/paperclip-hire.sh" --name computer-bot --deploy sudo-computer-bot --kind letta --heartbeat 900

echo ""
echo "✓ computer-bot node deployed."
echo "  LLM endpoint : http://sudo-llm:8080/v1  (127.0.0.1:8080/v1)"
echo "  artifacts    : $WORKSPACE/artifacts/"
echo "  Next: write the persona into the agent MemFS (computer-bot/README.md, step 6)."
