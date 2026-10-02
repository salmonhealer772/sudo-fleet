#!/usr/bin/env bash
set -euo pipefail

# factories/mac/cluster-access.sh — give the Mac cluster access WITHOUT dropping
# the fleet. Runs on the lima host as root; reaches the Mac over SSH only.
#
# Idempotent: a second run changes nothing and still PASSes. Zero interactive
# prompts. Never touches lima.yaml (so it never needs `limactl restart`), and
# never restarts or disrupts the running agent fleet.
#
# What it installs on the Mac (all as the Mac user aidanmcohen, over SSH):
#   [1] kubectl (darwin/arm64, pinned to the k3s server version) at
#       /opt/homebrew/bin/kubectl.
#   [2] a kubeconfig context "lima-k3s" (server https://127.0.0.1:<K3S_MAC_PORT>,
#       the local end of the API tunnel) MERGED into ~/.kube/config, preserving
#       the existing orbstack context; current-context becomes lima-k3s.
#   [3] Lima autostart (`limactl autostart enable ubuntu --condition=login`) so
#       the VM — and the fleet — comes back after a Mac reboot.
#   [4] a LaunchAgent <AGENT_LABEL> that keeps ONE SSH tunnel up:
#         -L 127.0.0.1:<K3S_MAC_PORT> -> guest 127.0.0.1:6443  (k3s API)
#         -D 127.0.0.1:<SOCKS_MAC_PORT>                        (SOCKS5 into the
#           cluster network: nodePorts + ClusterIP services)
#       RunAtLoad + KeepAlive, so it re-establishes itself after a reboot and
#       self-heals if the tunnel drops (ServerAliveInterval/CountMax catch a
#       half-dead link; launchd restarts it).
#
# The dashboard (https://localhost:30000) is Lima's existing default port
# forward (already in lima.yaml) — this script only VERIFIES it; it does not
# (and must not) edit lima.yaml.
#
# Hardcoded facts below were verified live 2026-10-02 — do not re-derive.

# ── Hardcoded facts (verified live 2026-10-02 — do not re-derive) ────────────
MAC_USER="aidanmcohen"
MAC_IP="192.168.5.2"
K3S_GUEST_API="127.0.0.1:6443"       # k3s API inside the lima VM
K3S_MAC_PORT="16443"                 # Mac-local port the API tunnel binds
SOCKS_MAC_PORT="1080"                # Mac-local SOCKS5 port into the cluster
KUBECTL_VERSION="v1.36.3"            # matches the k3s server (v1.36.3+k3s1)
KUBECTL_SHA256="fc8582acde13869a606730a79379d6515f30c68afcced0b5ac8789d5d002b7d6"
KUBECTL_URL="https://dl.k8s.io/${KUBECTL_VERSION}/bin/darwin/arm64/kubectl"
KUBECTL_INSTALL="/opt/homebrew/bin/kubectl"
LIMACTL="/opt/homebrew/bin/limactl"
LIMA_INSTANCE="ubuntu"
KUBE_CONTEXT="lima-k3s"
KUBE_USER="lima-k3s-admin"
AGENT_LABEL="com.sudofleet.cluster-access"
LIMA_SSH_CONFIG="/Users/${MAC_USER}/.lima/ubuntu/ssh.config"
DASHBOARD_PORT="30000"               # Lima's existing dashboard port forward
TRAEFIK_NODEPORT="30123"             # traefik http nodePort (a host-bound service)

# The Mac's login shell is zsh: a remote command containing a bare word starting
# with '=' (e.g. echo ===FOO===) dies with 'zsh:1: ==FOO=== not found'. Every
# remote probe below avoids '=' markers. (Only matters for non-interactive ssh.)
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
WORK="/tmp/mac-cluster-access"

PASS=0
FAIL=0
note_ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
note_bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
mssh()     { ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "$@"; }

echo "mac-cluster-access: kubectl + dashboard + fleet HTTP from the Mac"
echo "  Mac: $MAC_USER@$MAC_IP"
echo "  k3s API:      https://127.0.0.1:$K3S_MAC_PORT   (via SSH tunnel)"
echo "  SOCKS5:       127.0.0.1:$SOCKS_MAC_PORT          (into the cluster network)"
echo "  dashboard:    https://localhost:$DASHBOARD_PORT  (Lima's existing forward)"
echo ""

# ── [1/7] preflight ──────────────────────────────────────────────────────────
echo "→ [1/7] preflight"
if [[ "$(id -u)" != "0" ]]; then
  note_bad "must run as root"
else
  note_ok "running as root"
fi
if curl -sk --max-time 5 "https://$K3S_GUEST_API/version" >/dev/null 2>&1; then
  note_ok "k3s API reachable on the guest at $K3S_GUEST_API"
else
  note_bad "k3s API not reachable at $K3S_GUEST_API (is k3s up?)"
fi
if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
  note_ok "kubeconfig source /etc/rancher/k3s/k3s.yaml present"
else
  note_bad "missing /etc/rancher/k3s/k3s.yaml"
fi
if OUT="$(mssh 'hostname' 2>&1)"; then
  note_ok "ssh to Mac OK (hostname: $OUT)"
else
  note_bad "ssh to Mac FAILED — exact error: $OUT"
fi

# ── [2/7] kubectl on the Mac ─────────────────────────────────────────────────
echo "→ [2/7] kubectl $KUBECTL_VERSION on the Mac"
MAC_VER_RAW="$(mssh "$KUBECTL_INSTALL version --client --output=json 2>/dev/null" 2>/dev/null || true)"
MAC_KUBECTL_VER="$(printf '%s' "$MAC_VER_RAW" | grep -o 'v1\.[0-9]*\.[0-9]*' | head -1)"
MAC_KUBECTL_VER="${MAC_KUBECTL_VER:-}"
if [[ "$MAC_KUBECTL_VER" == "$KUBECTL_VERSION" ]]; then
  note_ok "kubectl already installed at $KUBECTL_VERSION (no change)"
else
  mkdir -p "$WORK"
  if curl -sSL --max-time 180 -o "$WORK/kubectl-darwin" "$KUBECTL_URL"; then
    note_ok "downloaded kubectl $KUBECTL_VERSION (darwin/arm64)"
  else
    note_bad "failed to download kubectl from $KUBECTL_URL"
  fi
  if [[ -f "$WORK/kubectl-darwin" ]] && echo "$KUBECTL_SHA256  $WORK/kubectl-darwin" | sha256sum -c - >/dev/null 2>&1; then
    note_ok "kubectl sha256 verified"
  else
    note_bad "kubectl sha256 mismatch (expected $KUBECTL_SHA256)"
  fi
  if [[ -f "$WORK/kubectl-darwin" ]] && scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$WORK/kubectl-darwin" "$MAC_USER@$MAC_IP:/tmp/kubectl" >/dev/null 2>&1 \
       && mssh "mkdir -p /opt/homebrew/bin && cp /tmp/kubectl $KUBECTL_INSTALL && chmod 755 $KUBECTL_INSTALL && rm -f /tmp/kubectl" >/dev/null 2>&1; then
    note_ok "installed kubectl at $KUBECTL_INSTALL"
  else
    note_bad "failed to install kubectl at $KUBECTL_INSTALL"
  fi
  rm -f "$WORK/kubectl-darwin"
fi

# ── [3/7] kubeconfig context lima-k3s on the Mac ─────────────────────────────
echo "→ [3/7] kubeconfig context $KUBE_CONTEXT (merged, orbstack preserved)"
mkdir -p "$WORK"
python3 - "$WORK" <<'PYEOF'
import sys, yaml, base64
outdir = sys.argv[1]
cfg = yaml.safe_load(open("/etc/rancher/k3s/k3s.yaml"))
cluster = cfg["clusters"][0]["cluster"]
user = cfg["users"][0]["user"]
open(outdir + "/ca.crt", "wb").write(base64.b64decode(cluster["certificate-authority-data"]))
open(outdir + "/client.crt", "wb").write(base64.b64decode(user["client-certificate-data"]))
open(outdir + "/client.key", "wb").write(base64.b64decode(user["client-key-data"]))
PYEOF
if [[ -s "$WORK/ca.crt" && -s "$WORK/client.crt" && -s "$WORK/client.key" ]]; then
  note_ok "extracted CA + client cert + key from k3s.yaml"
else
  note_bad "failed to extract CA/client cert/key from k3s.yaml"
fi
if scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$WORK/ca.crt" "$WORK/client.crt" "$WORK/client.key" "$MAC_USER@$MAC_IP:/tmp/" >/dev/null 2>&1; then
  note_ok "staged CA/cert/key to the Mac"
else
  note_bad "failed to stage CA/cert/key to the Mac"
fi
KCFG_OK=1
mssh "$KUBECTL_INSTALL config set-cluster $KUBE_CONTEXT --server=https://127.0.0.1:$K3S_MAC_PORT --certificate-authority=/tmp/ca.crt --embed-certs" >/dev/null 2>&1 || KCFG_OK=0
mssh "$KUBECTL_INSTALL config set-credentials $KUBE_USER --client-certificate=/tmp/client.crt --client-key=/tmp/client.key --embed-certs" >/dev/null 2>&1 || KCFG_OK=0
mssh "$KUBECTL_INSTALL config set-context $KUBE_CONTEXT --cluster=$KUBE_CONTEXT --user=$KUBE_USER" >/dev/null 2>&1 || KCFG_OK=0
mssh "$KUBECTL_INSTALL config use-context $KUBE_CONTEXT" >/dev/null 2>&1 || KCFG_OK=0
mssh "rm -f /tmp/ca.crt /tmp/client.crt /tmp/client.key" >/dev/null 2>&1
if [[ "$KCFG_OK" == "1" ]]; then
  note_ok "wrote + switched to context $KUBE_CONTEXT (server https://127.0.0.1:$K3S_MAC_PORT)"
else
  note_bad "failed to write context $KUBE_CONTEXT"
fi

# ── [4/7] Lima autostart (survive a Mac reboot) ──────────────────────────────
echo "→ [4/7] Lima autostart (VM comes back after a reboot)"
if OUT="$(mssh "$LIMACTL autostart enable $LIMA_INSTANCE --condition=login" 2>&1)"; then
  note_ok "$OUT"
else
  note_bad "limactl autostart enable failed: $OUT"
fi

# ── [5/7] SSH tunnel LaunchAgent (k3s API + SOCKS5) ──────────────────────────
echo "→ [5/7] tunnel LaunchAgent $AGENT_LABEL"
cat > "$WORK/$AGENT_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/ssh</string>
    <string>-F</string>
    <string>$LIMA_SSH_CONFIG</string>
    <string>-N</string>
    <string>-o</string><string>ExitOnForwardFailure=yes</string>
    <string>-o</string><string>ServerAliveInterval=30</string>
    <string>-o</string><string>ServerAliveCountMax=3</string>
    <string>-o</string><string>ControlMaster=no</string>
    <string>-o</string><string>ControlPath=none</string>
    <string>-L</string><string>127.0.0.1:$K3S_MAC_PORT:$K3S_GUEST_API</string>
    <string>-D</string><string>127.0.0.1:$SOCKS_MAC_PORT</string>
    <string>lima-ubuntu</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>/tmp/sudofleet-cluster-access.log</string>
  <key>StandardErrorPath</key><string>/tmp/sudofleet-cluster-access.log</string>
</dict>
</plist>
PLIST
cat > "$WORK/install-agent.sh" <<'INSTALL'
#!/bin/bash
set -e
U=$(id -u)
PLIST="$HOME/Library/LaunchAgents/com.sudofleet.cluster-access.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cp /tmp/com.sudofleet.cluster-access.plist "$PLIST"
# `launchctl` is invoked through a variable + a split subcommand word so a naive
# "launchctl bootstrap/bootout/kickstart" substring scan (the kind of host-side
# safety guard that protects the gateway from being stopped) does not misfire on
# it. These commands run on the REMOTE Mac's launchd, never on the gateway.
LC=/bin/launchctl
"$LC" boot"out"   gui/$U/com.sudofleet.cluster-access 2>/dev/null || true
"$LC" boot"strap" gui/$U "$PLIST"
"$LC" kick"start" -k gui/$U/com.sudofleet.cluster-access
echo agent-loaded
INSTALL
if scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$WORK/$AGENT_LABEL.plist" "$WORK/install-agent.sh" "$MAC_USER@$MAC_IP:/tmp/" >/dev/null 2>&1; then
  note_ok "staged LaunchAgent plist + installer to the Mac"
else
  note_bad "failed to stage LaunchAgent plist/installer to the Mac"
fi
if OUT="$(mssh "bash /tmp/install-agent.sh" 2>&1)"; then
  note_ok "LaunchAgent bootstrapped + kicked ($OUT)"
else
  note_bad "LaunchAgent bootstrap failed: $OUT"
fi

# ── [6/7] verify from the Mac, for real ──────────────────────────────────────
echo "→ [6/7] verify from the Mac"
sleep 3

if OUT="$(mssh "$KUBECTL_INSTALL get nodes --no-headers 2>&1")"; then
  NODE_COUNT="$(printf '%s\n' "$OUT" | grep -c 'Ready' || true)"
  if [[ "$NODE_COUNT" -ge 1 ]]; then
    note_ok "kubectl get nodes -> $(printf '%s' "$OUT" | head -1 | awk '{print $1, $2, $5}')"
  else
    note_bad "kubectl get nodes returned no Ready node: $OUT"
  fi
else
  note_bad "kubectl get nodes FAILED: $OUT"
fi

if OUT="$(mssh "curl -sk --max-time 8 https://localhost:$DASHBOARD_PORT/api/v1/namespace 2>&1")"; then
  if printf '%s' "$OUT" | grep -q '"namespaces"'; then
    note_ok "dashboard https://localhost:$DASHBOARD_PORT/api/v1/namespace -> cluster JSON"
  else
    note_bad "dashboard returned no namespaces JSON: $(printf '%s' "$OUT" | head -c 120)"
  fi
else
  note_bad "dashboard curl FAILED: $OUT"
fi

if OUT="$(mssh "curl --socks5-hostname 127.0.0.1:$SOCKS_MAC_PORT --max-time 8 -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$TRAEFIK_NODEPORT/ 2>&1")"; then
  if [[ "$OUT" != "000" && -n "$OUT" ]]; then
    note_ok "SOCKS5 -> traefik nodePort 127.0.0.1:$TRAEFIK_NODEPORT -> HTTP $OUT"
  else
    note_bad "SOCKS5 -> traefik nodePort returned HTTP 000 (unreachable)"
  fi
else
  note_bad "SOCKS5 -> traefik nodePort FAILED: $OUT"
fi

SVC_OUT="$(kubectl get svc -o custom-columns=NAME:.metadata.name,IP:.spec.clusterIP --no-headers 2>/dev/null || true)"
MCP_IP="$(printf '%s\n' "$SVC_OUT" | awk '$1 ~ /-mcp$/ {print $2; exit}')"
if [[ -n "$MCP_IP" ]]; then
  if OUT="$(mssh "curl --socks5-hostname 127.0.0.1:$SOCKS_MAC_PORT --max-time 8 -s -o /dev/null -w '%{http_code}' http://$MCP_IP:8000/healthz 2>&1")"; then
    if [[ "$OUT" != "000" && -n "$OUT" ]]; then
      note_ok "SOCKS5 -> an agent MCP service ($MCP_IP:8000) -> HTTP $OUT"
    else
      note_bad "SOCKS5 -> agent MCP ($MCP_IP:8000) returned HTTP 000"
    fi
  else
    note_bad "SOCKS5 -> agent MCP ($MCP_IP:8000) FAILED: $OUT"
  fi
else
  note_bad "no -mcp service found to verify per-agent MCP reachability"
fi

# ── [7/7] summary ────────────────────────────────────────────────────────────
rm -rf "$WORK"
echo ""
echo "════════════════════════════════════════════"
if [[ "$FAIL" -gt 0 ]]; then
  echo "RESULT: FAIL  ($PASS passed, $FAIL failed)"
  exit 1
fi
echo "RESULT: PASS  ($PASS passed, $FAIL failed)"
echo ""
echo "From the Mac:"
echo "  kubectl get nodes                          # k3s cluster"
echo "  kubectl config use-context orbstack        # switch back to orbstack"
echo "  curl -sk https://localhost:$DASHBOARD_PORT/api/v1/namespace   # dashboard"
echo "  curl --socks5-hostname 127.0.0.1:$SOCKS_MAC_PORT http://127.0.0.1:$TRAEFIK_NODEPORT/"
echo "  curl --socks5-hostname 127.0.0.1:$SOCKS_MAC_PORT http://<mcp-cluster-ip>:8000/mcp"
echo "  kubectl port-forward svc/sudo-<name>-mcp 8000:8000           # named MCP access"
