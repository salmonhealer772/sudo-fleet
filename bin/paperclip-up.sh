#!/usr/bin/env bash
set -uo pipefail

# bin/paperclip-up.sh — deploy Paperclip (the self-hosted agent control plane)
# into the CURRENT k3s cluster and make it immediately able to AUTO-HIRE
# sudo-fleet agents.
#
# Why this exists: sudo-fleet stands agents up as k8s deployments with an MCP
# door (`sudo-<agent>-mcp.<ns>.svc.cluster.local:8000/mcp`). Paperclip is the
# control plane that assigns issues and fires heartbeats. This script closes the
# gap in one command: cluster -> Paperclip + Postgres -> the `letta_local`
# adapter registered -> an instance admin + a board API key minted and stored ->
# `/logs/paperclip/paperclip.env` written so `bin/paperclip-hire.sh` (and
# `bin/paperclip-adopt.sh`) can hire agents with zero manual wiring.
#
# Idempotent: re-running re-applies the manifests, re-checks the adapter, and
# reuses the stored board key/company id when they still work.
#
# Log convention: ALL logs go under /logs/. Credentials live in
# /logs/paperclip/ (0600) — never in the repo.
#
# Usage: bash bin/paperclip-up.sh [--namespace paperclip]

FLEET_HOME="${FLEET_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
NS="paperclip"
LOG_DIR="/logs/paperclip"
CRED="$LOG_DIR/paperclip.env"
PAPERCLIP_IMAGE="${PAPERCLIP_IMAGE:-ghcr.io/paperclipai/paperclip:latest}"
PG_IMAGE="${PG_IMAGE:-postgres:17-alpine}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    *) echo "Usage: bash bin/paperclip-up.sh [--namespace paperclip]" >&2; exit 1 ;;
  esac
done

die()  { echo "✗ $*" >&2; exit 1; }
step() { echo ""; echo "── $* ──"; }
ok()   { echo "✓ $*"; }
warn() { echo "⚠ $*" >&2; }

is_root() { [[ "$(id -u)" -eq 0 ]]; }
SUDO=""; is_root || SUDO="sudo"

mkdir -p "$LOG_DIR" 2>/dev/null || $SUDO mkdir -p "$LOG_DIR"
$SUDO chmod 700 "$LOG_DIR" 2>/dev/null || true

KUBECTL="kubectl"
[[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig missing at $KUBECONFIG_PATH — run setup.sh first"
export KUBECONFIG="$KUBECONFIG_PATH"

_rand_hex() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# `pc_exec` runs a command inside the running Paperclip pod. All control-plane
# HTTP calls go through here because the deployment guards the Host header
# (private-hostname-guard) and only 127.0.0.1/localhost is guaranteed allowed —
# calling the ClusterIP/NodePort from outside would 403.
_pc_pod() {
  $KUBECTL -n "$NS" get pod -l app=paperclip \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}
pc_exec() {
  local pod; pod="$(_pc_pod)"
  [[ -n "$pod" ]] || die "no paperclip pod in ns $NS"
  $KUBECTL -n "$NS" exec -i "$pod" -- "$@"
}
pc_curl() { pc_exec curl -sS "$@"; }

step "1/6 Namespace + secrets"
$KUBECTL get ns "$NS" >/dev/null 2>&1 || $KUBECTL create ns "$NS" >/dev/null
ok "namespace $NS"

if $KUBECTL -n "$NS" get secret paperclip-db >/dev/null 2>&1; then
  PG_PW="$($KUBECTL -n "$NS" get secret paperclip-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
  ok "reusing existing DB secret"
else
  PG_PW="$(_rand_hex)"
  ok "generated DB password"
fi
AUTH_SECRET="$($KUBECTL -n "$NS" get secret paperclip-app -o jsonpath='{.data.BETTER_AUTH_SECRET}' 2>/dev/null | base64 -d)"
[[ -n "$AUTH_SECRET" ]] || AUTH_SECRET="$(_rand_hex)"
AGENT_JWT_SECRET="$($KUBECTL -n "$NS" get secret paperclip-app -o jsonpath='{.data.PAPERCLIP_AGENT_JWT_SECRET}' 2>/dev/null | base64 -d)"
[[ -n "$AGENT_JWT_SECRET" ]] || AGENT_JWT_SECRET="$(_rand_hex)"

NODE_NAME="$(hostname)"
NODE_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
ALLOWED_HOSTS="${NODE_NAME},${NODE_IP},${NODE_NAME}:31310,${NODE_IP}:31310,paperclip,paperclip:3100,paperclip.${NS}.svc.cluster.local,paperclip.${NS}.svc.cluster.local:3100,localhost,localhost:3100,127.0.0.1,127.0.0.1:3100"

$KUBECTL -n "$NS" create secret generic paperclip-db \
  --from-literal=POSTGRES_USER=paperclip \
  --from-literal=POSTGRES_PASSWORD="$PG_PW" \
  --from-literal=POSTGRES_DB=paperclip \
  --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null

$KUBECTL -n "$NS" create secret generic paperclip-app \
  --from-literal=BETTER_AUTH_SECRET="$AUTH_SECRET" \
  --from-literal=PAPERCLIP_AGENT_JWT_SECRET="$AGENT_JWT_SECRET" \
  --from-literal=DATABASE_URL="postgres://paperclip:${PG_PW}@paperclip-pg:5432/paperclip" \
  --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
ok "secrets applied"

step "2/6 Postgres + Paperclip manifests"
$KUBECTL apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: paperclip-pgdata, namespace: ${NS} }
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources: { requests: { storage: 8Gi } }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: paperclip-pg
  namespace: ${NS}
  labels: { app: paperclip-pg }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector: { matchLabels: { app: paperclip-pg } }
  template:
    metadata: { labels: { app: paperclip-pg } }
    spec:
      containers:
        - name: postgres
          image: ${PG_IMAGE}
          imagePullPolicy: IfNotPresent
          ports: [{ name: pg, containerPort: 5432 }]
          env:
            - { name: POSTGRES_USER,     valueFrom: { secretKeyRef: { name: paperclip-db, key: POSTGRES_USER } } }
            - { name: POSTGRES_PASSWORD, valueFrom: { secretKeyRef: { name: paperclip-db, key: POSTGRES_PASSWORD } } }
            - { name: POSTGRES_DB,       valueFrom: { secretKeyRef: { name: paperclip-db, key: POSTGRES_DB } } }
            - { name: PGDATA, value: /var/lib/postgresql/data/pgdata }
          volumeMounts: [{ name: pgdata, mountPath: /var/lib/postgresql/data }]
          readinessProbe:
            exec: { command: ["sh","-c","pg_isready -U paperclip -d paperclip"] }
            initialDelaySeconds: 5
            periodSeconds: 3
            failureThreshold: 30
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits:   { memory: 1Gi }
      volumes:
        - name: pgdata
          persistentVolumeClaim: { claimName: paperclip-pgdata }
---
apiVersion: v1
kind: Service
metadata: { name: paperclip-pg, namespace: ${NS} }
spec:
  selector: { app: paperclip-pg }
  ports: [{ name: pg, port: 5432, targetPort: 5432 }]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: paperclip-data, namespace: ${NS} }
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources: { requests: { storage: 10Gi } }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: paperclip
  namespace: ${NS}
  labels: { app: paperclip }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector: { matchLabels: { app: paperclip } }
  template:
    metadata: { labels: { app: paperclip } }
    spec:
      containers:
        - name: paperclip
          image: ${PAPERCLIP_IMAGE}
          imagePullPolicy: IfNotPresent
          ports: [{ name: http, containerPort: 3100 }]
          env:
            - { name: HOST, value: "0.0.0.0" }
            - { name: PAPERCLIP_BIND, value: "lan" }
            - { name: PORT, value: "3100" }
            - { name: SERVE_UI, value: "true" }
            - { name: PAPERCLIP_HOME, value: "/paperclip" }
            - { name: PAPERCLIP_DEPLOYMENT_MODE, value: "authenticated" }
            - { name: PAPERCLIP_DEPLOYMENT_EXPOSURE, value: "private" }
            - { name: PAPERCLIP_PUBLIC_URL, value: "http://${NODE_IP}:31310" }
            - { name: PAPERCLIP_ALLOWED_HOSTNAMES, value: "${ALLOWED_HOSTS}" }
            - { name: BETTER_AUTH_SECRET, valueFrom: { secretKeyRef: { name: paperclip-app, key: BETTER_AUTH_SECRET } } }
            - { name: DATABASE_URL,       valueFrom: { secretKeyRef: { name: paperclip-app, key: DATABASE_URL } } }
            - { name: PAPERCLIP_AGENT_JWT_SECRET, valueFrom: { secretKeyRef: { name: paperclip-app, key: PAPERCLIP_AGENT_JWT_SECRET } } }
          volumeMounts: [{ name: data, mountPath: /paperclip }]
          startupProbe:
            exec: { command: ["sh","-c","curl -fsS -o /dev/null http://127.0.0.1:3100/api/health"] }
            periodSeconds: 5
            failureThreshold: 90
          readinessProbe:
            exec: { command: ["sh","-c","curl -fsS -o /dev/null http://127.0.0.1:3100/api/health"] }
            periodSeconds: 5
            failureThreshold: 12
          livenessProbe:
            exec: { command: ["sh","-c","curl -fsS -o /dev/null http://127.0.0.1:3100/api/health"] }
            periodSeconds: 20
            failureThreshold: 6
          resources:
            requests: { cpu: 200m, memory: 512Mi }
            limits:   { memory: 2Gi }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: paperclip-data }
---
apiVersion: v1
kind: Service
metadata: { name: paperclip, namespace: ${NS} }
spec:
  selector: { app: paperclip }
  ports: [{ name: http, port: 3100, targetPort: 3100 }]
---
apiVersion: v1
kind: Service
metadata: { name: paperclip-node, namespace: ${NS} }
spec:
  type: NodePort
  selector: { app: paperclip }
  ports: [{ name: http, port: 3100, targetPort: 3100, nodePort: 31310 }]
YAML
ok "manifests applied"

# Pull the Paperclip image into the k3s containerd store (it is not on a
# registry the node's containerd is configured to trust implicitly, and a
# PullIfNotPresent pod would otherwise sit in ImagePullBackOff on a fresh box).
if ! $KUBECTL -n "$NS" get pods -l app=paperclip -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running; then
  if command -v k3s >/dev/null 2>&1; then
    ok "pre-pulling $PAPERCLIP_IMAGE into k3s containerd"
    k3s ctr images pull "$PAPERCLIP_IMAGE" >/dev/null 2>&1 || warn "ctr pull failed — containerd may still pull it itself"
  fi
fi

step "3/6 Wait for Postgres + Paperclip to be Ready"
$KUBECTL -n "$NS" rollout status deploy/paperclip-pg --timeout=300s >/dev/null 2>&1 || warn "postgres rollout not confirmed in 300s"
_ready=0
for _i in $(seq 1 90); do
  if pc_curl http://127.0.0.1:3100/api/health 2>/dev/null | grep -q '"status":"ok"'; then _ready=1; break; fi
  sleep 5
done
[[ "$_ready" -eq 1 ]] || die "Paperclip /api/health never reported ok (check: kubectl -n $NS logs deploy/paperclip)"
ok "Paperclip healthy"

step "4/6 Register the letta_local adapter"
# The adapter is a Paperclip *external adapter plugin*: a package directory under
# $PAPERCLIP_HOME/adapter-plugins plus a record in adapter-plugins.json (the
# file-based registry the server reads at startup). It ships PREBUILT (dist/) so
# a fresh box needs no npm/tsc.
ADAPTER_SRC="$FLEET_HOME/factories/paperclip-letta-adapter"
ADAPTER_DIR="/paperclip/adapter-plugins/letta-local-adapter"
[[ -f "$ADAPTER_SRC/dist/index.js" ]] || die "adapter dist missing at $ADAPTER_SRC/dist/index.js (commit the built dist/)"
pc_exec mkdir -p "$ADAPTER_DIR/dist"
pc_exec sh -c "cat > $ADAPTER_DIR/package.json" < "$ADAPTER_SRC/package.json"
pc_exec sh -c "cat > $ADAPTER_DIR/dist/index.js" < "$ADAPTER_SRC/dist/index.js"
pc_exec sh -c "cat > $ADAPTER_DIR/dist/index.d.ts" < "$ADAPTER_SRC/dist/index.d.ts" 2>/dev/null || true
pc_exec sh -c "cat > /paperclip/adapter-plugins.json" <<JSON
[
  {
    "packageName": "@letta-ai/letta-local-adapter",
    "localPath": "$ADAPTER_DIR",
    "version": "0.2.1",
    "type": "letta_local",
    "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  }
]
JSON
ok "adapter files placed"

if ! pc_exec sh -c 'cat /paperclip/instances/default/.env 2>/dev/null | grep -q PAPERCLIP_TOOL_ACTION_SIGNING_SECRET'; then
  pc_exec sh -c 'mkdir -p /paperclip/instances/default; S=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n"); printf "PAPERCLIP_TOOL_ACTION_SIGNING_SECRET=%s\n" "$S" >> /paperclip/instances/default/.env'
  ok "tool-action signing secret seeded"
fi

$KUBECTL -n "$NS" rollout restart deploy/paperclip >/dev/null
$KUBECTL -n "$NS" rollout status deploy/paperclip --timeout=300s >/dev/null 2>&1 || warn "rollout restart not confirmed in 300s"
_ready=0
for _i in $(seq 1 60); do
  if pc_curl http://127.0.0.1:3100/api/health 2>/dev/null | grep -q '"status":"ok"'; then _ready=1; break; fi
  sleep 5
done
[[ "$_ready" -eq 1 ]] || die "Paperclip did not come back after the adapter restart"
if pc_exec sh -c 'grep -rq "Failed to load external" /tmp 2>/dev/null; exit 0' ; then :; fi
ok "adapter registered (letta_local)"

step "5/6 Bootstrap: instance admin + board API key"
# Reuse a stored key when it still authenticates.
if [[ -f "$CRED" ]]; then
  # shellcheck disable=SC1090
  set +u; . "$CRED"; set -u
  if [[ -n "${PAPERCLIP_BOARD_KEY:-}" ]] && \
     pc_curl -H "Authorization: Bearer $PAPERCLIP_BOARD_KEY" \
       "http://127.0.0.1:3100/api/companies" 2>/dev/null | grep -q '"id"'; then
    ok "existing board key still valid (company ${PAPERCLIP_COMPANY_ID:-?})"
    echo "PAPERCLIP_URL=http://127.0.0.1:3100 (in-pod); http://${NODE_IP}:31310 (external)"
    exit 0
  fi
fi

ADMIN_EMAIL="${ADMIN_EMAIL:-admin@paperclip.local}"
# The password MUST survive a re-run: the first run creates the user, so a
# second run has to sign IN with the same secret to mint a key. Persist it.
PW_FILE="$LOG_DIR/admin.pw"
if [[ -s "$PW_FILE" ]]; then
  ADMIN_PW="$(cat "$PW_FILE")"
  ok "reusing stored admin password"
else
  ADMIN_PW="$(_rand_hex | cut -c1-24)"
  ( umask 077; printf '%s\n' "$ADMIN_PW" > "$PW_FILE" )
  chmod 600 "$PW_FILE" 2>/dev/null || $SUDO chmod 600 "$PW_FILE" 2>/dev/null || true
fi

if pc_curl http://127.0.0.1:3100/api/health 2>/dev/null | grep -q '"bootstrapStatus":"ready"'; then
  ok "instance already bootstrapped — signing in"
  SIGNIN=1
else
  SIGNIN=0
fi

pc_exec sh -s "$ADMIN_EMAIL" "$ADMIN_PW" "$SIGNIN" <<'BOOT' > /tmp/pc-boot.out 2>&1
EMAIL="$1"; PW="$2"; SIGNIN="$3"
API="http://127.0.0.1:3100"
ORIGIN="$API"
JAR=/tmp/pc-session.jar
rm -f "$JAR"
if [ "$SIGNIN" = "0" ]; then
  curl -sS -c "$JAR" -o /tmp/pc-signup.json -w 'signup_http=%{http_code}\n' \
    -X POST "$API/api/auth/sign-up/email" \
    -H 'Content-Type: application/json' -H "Origin: $ORIGIN" -H "Referer: $ORIGIN/" \
    -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\",\"name\":\"sudo-fleet admin\"}"
  curl -sS -b "$JAR" -c "$JAR" -o /tmp/pc-claim.json -w 'claim_http=%{http_code}\n' \
    -X POST "$API/api/bootstrap/claim" \
    -H 'Content-Type: application/json' -H "Origin: $ORIGIN"           -H "Referer: $ORIGIN/"
  cat /tmp/pc-claim.json; echo
else
  curl -sS -c "$JAR" -o /tmp/pc-signin.json -w 'signin_http=%{http_code}\n' \
    -X POST "$API/api/auth/sign-in/email" \
    -H 'Content-Type: application/json' -H "Origin: $ORIGIN" -H "Referer: $ORIGIN/" \
    -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}"
fi
curl -sS -b "$JAR" -c "$JAR" -X POST "$API/api/board-api-keys" \
  -H 'Content-Type: application/json' -H "Origin: $ORIGIN" -H "Referer: $ORIGIN/" \
  -d '{"name":"sudo-fleet-autohire"}' -o /tmp/pc-key.json
echo "KEY:"; cat /tmp/pc-key.json; echo
BOOT
cat /tmp/pc-boot.out

BOARD_KEY="$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' /tmp/pc-boot.out | tail -1)"
[[ -n "$BOARD_KEY" ]] || die "could not mint a board API key — see output above"
ok "board API key minted"

COMPANY_ID="$(pc_curl -H "Authorization: Bearer $BOARD_KEY" \
  "http://127.0.0.1:3100/api/companies" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)"
[[ -n "$COMPANY_ID" ]] || die "no company returned for the board key"

step "6/6 Store credentials + company"
umask 077
{
  echo "# Paperclip control-plane credentials for sudo-fleet auto-hire."
  echo "# Written by bin/paperclip-up.sh. Do NOT commit. 0600."
  echo "PAPERCLIP_BOARD_KEY=$BOARD_KEY"
  echo "PAPERCLIP_COMPANY_ID=$COMPANY_ID"
  echo "PAPERCLIP_ADMIN_EMAIL=$ADMIN_EMAIL"
  echo "PAPERCLIP_ADMIN_PASSWORD=$ADMIN_PW"
  echo "PAPERCLIP_NS=$NS"
  echo "PAPERCLIP_INTERNAL_URL=http://paperclip.${NS}.svc.cluster.local:3100"
  echo "PAPERCLIP_EXTERNAL_URL=http://${NODE_IP}:31310"
} > "$CRED"
chmod 600 "$CRED"
$KUBECTL -n "$NS" create secret generic paperclip-board \
  --from-literal=BOARD_API_KEY="$BOARD_KEY" \
  --from-literal=COMPANY_ID="$COMPANY_ID" \
  --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
ok "wrote $CRED (0600) + secret paperclip-board"

echo ""
echo "✓ Paperclip up. UI: http://${NODE_IP}:31310  (admin ${ADMIN_EMAIL}, password in $CRED)"
echo "  Now hire agents:  bash bin/paperclip-adopt.sh"
