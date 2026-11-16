# computer-bot — a local-LLM artifact node on the gaming laptop

`computer-bot` turns the operator's ROG gaming laptop ("compooper", WSL2 + RTX 4070
8GB) into a sudo-fleet node that runs a **local** model and produces **real,
dated artifact files** on a 15-minute Paperclip heartbeat.

```
k3s (compooper)
├── docker container `sudo-llm`  → llama.cpp server, Qwen3.5-9B Q4_K_M on the GPU
│                                  (host network, http://127.0.0.1:8080/v1)
├── k8s Service `sudo-llm`        → stable in-cluster name for the endpoint
├── deploy `sudo-computer-bot`    → Letta agent, model = local llama (openai-compatible)
│                                  hostPath workspace mount → /opt/computer-bot
├── Paperclip (ns paperclip)      → control plane; wakes computer-bot every 900s
└── /opt/computer-bot/{prompts,artifacts,state}  → prompt bank + dated artifacts on the host
```

## Why the model is served the way it is

- **Model**: Qwen3.5-9B **Q4_K_M** (`bartowski/Qwen_Qwen3.5-9B-GGUF`,
  `Qwen_Qwen3.5-9B-Q4_K_M.gguf`, 6.17 GB). Do NOT substitute a 27B-class model
  (it only fits at 2-bit — a quality cliff).
- **CUDA 12.6, not 12.8**: the laptop's driver is 561.00 (CUDA 12.6). The official
  `ghcr.io/ggml-org/llama.cpp:server-cuda` image is CUDA 12.8 and needs driver
  >= 570.26, so it would not start. `factories/sudo-llm/Dockerfile` builds
  `llama-server` from source against CUDA 12.6, targeting sm_89 (RTX 4070).
- **Docker `--gpus all`, not a k3s pod**: nvidia-container-toolkit is wired into
  docker; the container runs `--network host` on :8080. The agent pod is
  `hostNetwork`, so it reaches the endpoint at `127.0.0.1:8080` with no
  device-plugin plumbing.
- **Quantized KV (q8_0) + FlashAttention + 16k ctx** are enabled in
  `run-llm.sh`; llama.cpp auto-offloads layers that fit in the ~6 GB of VRAM
  left free after the Windows desktop (the card is 8 GB total and WDDM keeps
  ~2 GB).

## Bring-up (on the laptop, as root, docker + k3s already installed)

```bash
# 0. bootstrap k3s (docker is already present)
curl -sfL https://get.k3s.io | sh -

# 1. clone + download the model + install nvidia-container-toolkit
git clone https://github.com/salmonhealer772/sudo-fleet.git /opt/computer-bot/sudo-fleet
mkdir -p /opt/computer-bot/models
curl -fL -C - -o /opt/computer-bot/models/Qwen_Qwen3.5-9B-Q4_K_M.gguf \
  https://huggingface.co/bartowski/Qwen_Qwen3.5-9B-GGUF/resolve/main/Qwen_Qwen3.5-9B-Q4_K_M.gguf
# nvidia-container-toolkit (gives docker the `nvidia` runtime for --gpus all):
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --batch --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update && apt-get install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker && systemctl restart docker

# 2. build the agent image (Letta)
docker build -t sudo-letta:latest -f /opt/computer-bot/sudo-fleet/factories/sudo-letta/Dockerfile /opt/computer-bot/sudo-fleet/factories/sudo-letta

# 3. run deploy.sh (builds sudo-llm, serves the model, deploys the agent, brings up Paperclip)
bash /opt/computer-bot/sudo-fleet/computer-bot/deploy.sh
```

After `deploy.sh`, write the persona into the agent's MemFS and commit it (the
agent record + MemFS are created on the first prompt):

```bash
POD=$(kubectl get pod -l agent=computer-bot -o jsonpath='{.items[0].metadata.name}')
# first prompt creates the agent + MemFS
kubectl exec $POD -- letta -p "hello" >/dev/null 2>&1
MEM=$(kubectl exec $POD -- bash -c 'for d in /home/node/.letta/lc-local-backend/memfs/*/memory; do echo "$d"; break; done')
kubectl cp /opt/computer-bot/sudo-fleet/computer-bot/persona.md $POD:$MEM/system/persona.md
kubectl exec $POD -- bash -c "git -C '$MEM' init -q -b main 2>/dev/null; git -C '$MEM' add -A && git -C '$MEM' -c user.email=factory@localhost -c user.name=factory commit -q -m 'computer-bot persona'"
kubectl rollout restart deploy/sudo-computer-bot
```

## Verification

```bash
# local model really answers
curl -s http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.5-9b","messages":[{"role":"user","content":"Say PONG"}],"max_tokens":16}'

# agent identity + model
kubectl exec $POD -- letta -p "who are you, and what model are you?"

# Paperclip routine (heartbeat 900s)
kubectl -n paperclip exec $(kubectl -n paperclip get pod -l app=paperclip -o jsonpath='{.items[0].metadata.name}') -- \
  sh -c "curl -sS -H 'Authorization: Bearer $PAPERCLIP_BOARD_KEY' http://127.0.0.1:3100/api/agents/\$PAPERCLIP_AGENT_ID" | grep -o 'intervalSec[^,]*'

# artifacts land here on the host
ls -la /opt/computer-bot/artifacts/
```

## Files

| Path | What |
|---|---|
| `factories/sudo-llm/Dockerfile` | llama.cpp CUDA 12.6 server image build |
| `factories/sudo-llm/run-llm.sh` | serve the GGUF on the GPU, host net :8080 |
| `computer-bot/prompts/*.md` | the ~30-prompt artifact bank |
| `computer-bot/persona.md` | agent identity + the heartbeat artifact routine |
| `computer-bot/sudo-llm-service.yaml` | in-cluster `sudo-llm` Service + Endpoints |
| `computer-bot/deploy.sh` | end-to-end node bring-up |
| `factories/sudo-letta/bin/up.sh` | + `--workspace <hostpath>` hostPath mount flag |
