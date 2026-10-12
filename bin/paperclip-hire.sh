#!/usr/bin/env bash
set -uo pipefail

# bin/paperclip-hire.sh — hire ONE sudo-fleet agent into Paperclip, with
# heartbeat enabled and a live callback key wired into the agent's own pod.
#
# This is the auto-hire primitive. `bin/paperclip-adopt.sh` calls it once per
# agent deployment it finds in the cluster; the factory up.sh scripts call it
# right after they stand an agent up, so "build an agent" and "hired by
# Paperclip" are the same action.
#
# What "hired" means here (all three halves are required, hence all three are
# done in one shot):
#   1. The agent record exists in Paperclip, using the `letta_local` MCP-door
#      adapter pointed at the LIVE pod's MCP service
#      (`sudo-<agent>-mcp.<ns>.svc.cluster.local:8000/mcp`), so a heartbeat runs
#      the prompt INSIDE the running agent — not a detached clone.
#   2. `runtimeConfig.heartbeat` is enabled, so Paperclip wakes the agent on a
#      schedule (this is the heartbeat; it is a field on the agent, not a cron).
#   3. The agent's k8s deployment gets PAPERCLIP_API_URL / PAPERCLIP_API_KEY /
#      PAPERCLIP_AGENT_ID / PAPERCLIP_COMPANY_ID, so the live agent can call the
#      control plane back (checkout, comment, mark the issue done).
#
# Idempotent: an existing agent of the same name is reused (its key is
# re-minted only when none of the injected env is present).
#
# Usage:
#   bash bin/paperclip-hire.sh --name Marc [--kind letta|hermes]
#        [--namespace sudo-fleet] [--deploy sudo-marc] [--mode direct|inbox]
#        [--heartbeat 120] [--role general] [--no-env] [--json]

CRED="/logs/paperclip/paperclip.env"
NAME=""
KIND=""
NS=""
DEPLOY=""
MODE="direct"
HEARTBEAT="120"
ROLE="general"
DO_ENV=1
AS_JSON=0

die()  { echo "✗ $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }
warn() { echo "⚠ $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)      NAME="$2"; shift 2 ;;
    --kind)      KIND="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --deploy)    DEPLOY="$2"; shift 2 ;;
    --mode)      MODE="$2"; shift 2 ;;
    --heartbeat) HEARTBEAT="$2"; shift 2 ;;
    --role)      ROLE="$2"; shift 2 ;;
    --no-env)    DO_ENV=0; shift ;;
    --json)      AS_JSON=1; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done
[[ -n "$NAME" ]] || die "usage: bin/paperclip-hire.sh --name <agent> [--kind letta|hermes] ..."

KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
[[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig missing at $KUBECONFIG_PATH"
export KUBECONFIG="$KUBECONFIG_PATH"

[[ -f "$CRED" ]] || die "no $CRED — run bin/paperclip-up.sh first (Paperclip is not installed in this cluster)"
# shellcheck disable=SC1090
set +u; . "$CRED"; set -u
[[ -n "${PAPERCLIP_BOARD_KEY:-}" ]] || die "$CRED has no PAPERCLIP_BOARD_KEY"
[[ -n "${PAPERCLIP_COMPANY_ID:-}" ]] || die "$CRED has no PAPERCLIP_COMPANY_ID"
PC_NS="${PAPERCLIP_NS:-paperclip}"
PC_API="${PAPERCLIP_EXTERNAL_URL:-http://paperclip.${PC_NS}.svc.cluster.local:3100}"

LNAME="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')"
[[ -n "$DEPLOY" ]] || DEPLOY="sudo-$LNAME"

# --- resolve the namespace + the live deployment ------------------------------
# sudo-fleet's factory up.sh applies the agent YAML into the kubeconfig's current
# namespace (no -n flag), so never assume one: find the deployment by name.
if [[ -z "$NS" ]]; then
  NS="$(kubectl get deploy -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' \
        --no-headers 2>/dev/null | awk -v d="$DEPLOY" '$2==d {print $1; exit}')"
  [[ -n "$NS" ]] || NS="$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)"
  [[ -n "$NS" ]] || NS="default"
fi

# --- infer the kind from the live deployment when not given -------------------
if [[ -z "$KIND" ]]; then
  APP="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.metadata.labels.app}' 2>/dev/null)"
  case "$APP" in
    sudo-letta) KIND="letta" ;;
    sudo-agent) KIND="hermes" ;;
    *) warn "could not infer kind for $DEPLOY (label app='$APP') — assuming letta" ; KIND="letta" ;;
  esac
fi
case "$KIND" in
  letta)  MCP_TOOL="letta_prompt"  ;;
  hermes) MCP_TOOL="hermes_prompt" ;;
  *) die "--kind must be letta or hermes" ;;
esac
MCP_URL="http://${DEPLOY}-mcp.${NS}.svc.cluster.local:8000/mcp"

pc_exec() {
  local pod
  pod="$(kubectl -n "$PC_NS" get pod -l app=paperclip -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -n "$pod" ]] || die "no paperclip pod in ns $PC_NS"
  kubectl -n "$PC_NS" exec -i "$pod" -- "$@"
}

# --- 1+2. hire the agent (idempotent) and mint its callback key --------------
# Runs inside the Paperclip pod so the Host header is 127.0.0.1 (the private
# hostname guard 403s anything else).
HIRE_OUT="$(pc_exec sh -s "$PAPERCLIP_BOARD_KEY" "$PAPERCLIP_COMPANY_ID" \
  "$NAME" "$ROLE" "$MCP_URL" "$MCP_TOOL" "$MODE" "$NS" "$LNAME" "$HEARTBEAT" "$PC_API" <<'HIRE'
KEY="$1"; CID="$2"; NAME="$3"; ROLE="$4"; MCP_URL="$5"; TOOL="$6"
MODE="$7"; NS="$8"; LNAME="$9"; HB="${10}"; PCAPI="${11}"
API="http://127.0.0.1:3100"
AUTH="Authorization: Bearer $KEY"
CT="Content-Type: application/json"

existing="$(curl -sS -H "$AUTH" "$API/api/companies/$CID/agents" \
  | tr '}' '\n' | grep -F "\"name\":\"$NAME\"" | head -1 \
  | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
if [ -n "$existing" ]; then
  AGENT_ID="$existing"
  echo "REUSED $AGENT_ID" >&2
else
  HB_JSON="{\"enabled\":false}"
  if [ "$HB" != "0" ]; then HB_JSON="{\"enabled\":true,\"intervalSec\":$HB,\"maxConcurrentRuns\":1}"; fi
  PAYLOAD=$(cat <<EOF
{"name":"$NAME","role":"$ROLE","adapterType":"letta_local",
 "capabilities":"sudo-fleet agent ($LNAME) — live k8s deployment $NS/$( echo sudo-$LNAME )",
 "adapterConfig":{"mcpUrl":"$MCP_URL","mcpTool":"$TOOL","mode":"$MODE","namespace":"$NS","agentName":"$LNAME","timeoutSec":900,"apiUrl":"$PCAPI"},
 "runtimeConfig":{"heartbeat":$HB_JSON}}
EOF
)
  RESP="$(curl -sS -X POST -H "$AUTH" -H "$CT" -d "$PAYLOAD" "$API/api/companies/$CID/agent-hires")"
  AGENT_ID="$(printf '%s' "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)"
  if [ -z "$AGENT_ID" ]; then
    echo "HIRE_FAILED: $RESP" >&2
    exit 3
  fi
  echo "HIRED $AGENT_ID" >&2
fi

KEY_RESP="$(curl -sS -X POST -H "$AUTH" -H "$CT" -d '{"name":"sudo-fleet-inpod"}' \
  "$API/api/agents/$AGENT_ID/keys")"
AGENT_TOKEN="$(printf '%s' "$KEY_RESP" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' | head -1)"
if [ -z "$AGENT_TOKEN" ]; then
  echo "KEY_FAILED: $KEY_RESP" >&2
  exit 4
fi
printf 'AGENT_ID=%s\nAGENT_TOKEN=%s\n' "$AGENT_ID" "$AGENT_TOKEN"
HIRE
)"

AGENT_ID="$(printf '%s\n' "$HIRE_OUT" | sed -n 's/^AGENT_ID=//p' | tail -1)"
AGENT_TOKEN="$(printf '%s\n' "$HIRE_OUT" | sed -n 's/^AGENT_TOKEN=//p' | tail -1)"
[[ -n "$AGENT_ID" ]] || die "hire produced no agent id (output: $HIRE_OUT)"
ok "hired '$NAME' as Paperclip agent $AGENT_ID"

# --- 3. wire the live pod so the agent can call the control plane back -------
if [[ "$DO_ENV" == "1" ]]; then
  if kubectl -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1; then
    kubectl -n "$NS" set env "deploy/$DEPLOY" \
      PAPERCLIP_API_URL="$PC_API" \
      PAPERCLIP_API_KEY="$AGENT_TOKEN" \
      PAPERCLIP_AGENT_ID="$AGENT_ID" \
      PAPERCLIP_COMPANY_ID="$PAPERCLIP_COMPANY_ID" \
      PAPERCLIP_DEPLOYMENT_URL="$PC_API" >/dev/null
    ok "injected PAPERCLIP_* env into $NS/$DEPLOY (the live agent can now self-auth)"
    kubectl -n "$NS" rollout restart "deploy/$DEPLOY" >/dev/null 2>&1 || true
  else
    warn "$NS/$DEPLOY not found — skipped env injection (hire still recorded)"
  fi
fi

# --- ledger ------------------------------------------------------------------
LEDGER="/logs/paperclip/hired.jsonl"
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || true
printf '{"name":"%s","agentId":"%s","kind":"%s","deploy":"%s","namespace":"%s","mcpUrl":"%s","mcpTool":"%s","mode":"%s","heartbeatSec":%s,"hiredAt":"%s"}\n' \
  "$NAME" "$AGENT_ID" "$KIND" "$DEPLOY" "$NS" "$MCP_URL" "$MCP_TOOL" "$MODE" "$HEARTBEAT" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LEDGER" 2>/dev/null || true

if [[ "$AS_JSON" == "1" ]]; then
  printf '{"name":"%s","agentId":"%s","kind":"%s","mcpUrl":"%s","mcpTool":"%s"}\n' \
    "$NAME" "$AGENT_ID" "$KIND" "$MCP_URL" "$MCP_TOOL"
else
  echo "  agent id : $AGENT_ID"
  echo "  MCP door : $MCP_URL  ($MCP_TOOL, mode=$MODE)"
  echo "  heartbeat: ${HEARTBEAT}s"
fi
