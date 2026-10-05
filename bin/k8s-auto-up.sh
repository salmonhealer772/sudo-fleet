#!/usr/bin/env bash
set -euo pipefail

# sudo-fleet/bin/k8s-auto-up.sh — boot-time bring-up (idempotent).
#
# Installed by setup.sh as a oneshot systemd unit (sudo-fleet-boot.service) and
# run automatically on every boot. It is what makes a cluster stood up by
# sudo-fleet COME BACK ON ITS OWN after a VM/WSL2 restart with zero manual
# commands, and self-repair after that.
#
# It is NOT a third operator command: it never needs to be run by hand, and the
# README contract stays "two commands" (setup.sh + k8s-up.sh).
#
# What it does (all idempotent, all safe to run repeatedly):
#   1. Wait for k3s to be Ready (kubectl wait --for=condition=Ready node --all,
#      polling up to ~10 min; never hard-fails — degrades to warn).
#   2. Re-import the locally-built images into containerd if they are MISSING.
#      These tags exist only in the containerd store (NOT on any registry) and
#      every pod pins them with imagePullPolicy: IfNotPresent, so if the store
#      is ever lost the pods would otherwise ImagePullBackOff forever. This is
#      the re-import safety net.
#   3. Re-run the idempotent bring-up (k8s-up.sh) to recreate anything that
#      exists only because up.sh ran (PVC/Deployment/ConfigMaps/Services are
#      already recreated by k3s from its persistent etcd datastore; this is the
#      belt-and-suspenders re-apply of the workload itself).
#   4. Record a boot-proof file so the operator can confirm the fleet came back.
#
# All output is logged under /logs/ (the repo's log convention). Runs as root
# (systemd), so no sudo handling is needed. It never fails the boot: every step
# degrades to a loud warn instead of exiting non-zero.

FLEET_HOME="${FLEET_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
PROOF_DIR="$FLEET_HOME/durable-boot-proof"
LOG_DIR="/logs"
LOG_FILE="$LOG_DIR/k8s-auto-up-$(date -u +%Y%m%dT%H%M%SZ).log"

die()  { echo "✗ $*" >&2; echo "✗ $*" >> "$LOG_FILE" 2>/dev/null || true; exit 1; }
ok()   { echo "✓ $*"; echo "✓ $*" >> "$LOG_FILE" 2>/dev/null || true; }
warn() { echo "⚠ $*" >&2; echo "⚠ $*" >> "$LOG_FILE" 2>/dev/null || true; }

# Ensure the log directory exists (best-effort — /logs may not exist yet on a
# fresh install before setup.sh has fully run).
mkdir -p "$LOG_DIR" 2>/dev/null || true

{
  echo "=== k8s-auto-up.sh started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "FLEET_HOME=$FLEET_HOME"
  echo "KUBECONFIG_PATH=$KUBECONFIG_PATH"

  if [[ ! -f "$KUBECONFIG_PATH" ]]; then
    warn "kubeconfig missing at $KUBECONFIG_PATH — k3s may not be installed yet; aborting (k8s-up.sh will handle it once setup.sh has run)"
    echo "=== k8s-auto-up.sh finished (kubeconfig missing) ==="
    exit 0
  fi
  export KUBECONFIG="$KUBECONFIG_PATH"

  # --- 1. Wait for k3s Ready (bounded: ~10 min, polling every 5s) ----------
  ok "waiting for k3s to become Ready (polling up to ~10 min)..."
  _ready=0
  # Use kubectl wait with a 5s timeout in a retry loop — it returns 0 when
  # Ready, non-zero on timeout. We wrap it so a transient timeout is not fatal.
  for _i in $(seq 1 120); do
    if kubectl wait --for=condition=Ready node --all --timeout=5s >/dev/null 2>&1; then
      _ready=1
      ok "k3s Ready (kubectl wait succeeded on attempt $_i)"
      break
    fi
    # kubectl wait timed out — node not Ready yet; keep polling.
    sleep 5
  done
  if [[ "$_ready" -ne 1 ]]; then
    warn "k3s not Ready within ~10 min — fleet may need manual attention"
  fi
  kubectl get nodes 2>/dev/null || warn "no nodes visible"

  # --- 2. Re-import missing images (idempotent) ----------------------------------
  _ctr_images() {
    k3s ctr images ls -q 2>/dev/null || ctr -n k8s.io images ls -q 2>/dev/null || true
  }
  _image_present() {
    local img="$1" refs
    refs="$(_ctr_images)"
    grep -Fxq "$img" <<<"$refs" && return 0
    grep -Fxq "docker.io/library/$img" <<<"$refs" && return 0
    return 1
  }
  _import_once() {
    local img="$1"
    docker save "$img" | k3s ctr image import - \
      || docker save "$img" | ctr -n k8s.io image import -
  }
  for _img in hermes-agent:latest sudo-agent:latest sudo-letta:latest; do
    if _image_present "$_img"; then
      ok "$_img already in containerd"
      continue
    fi
    if docker image inspect "$_img" >/dev/null 2>&1; then
      warn "$_img missing from containerd — re-importing from docker..."
      if _import_once "$_img" && _image_present "$_img"; then
        ok "$_img re-imported"
      else
        warn "$_img re-import FAILED — pods using it will ImagePullBackOff"
      fi
    else
      warn "$_img missing from both containerd AND docker — rebuild with setup.sh"
    fi
  done

  # --- 3. Re-run the idempotent bring-up -----------------------------------------
  if [[ -x "$FLEET_HOME/bin/k8s-up.sh" ]]; then
    ok "re-running idempotent bring-up (k8s-up.sh)..."
    if bash "$FLEET_HOME/bin/k8s-up.sh"; then
      ok "bring-up complete"
    else
      warn "k8s-up.sh failed — see log above; pods already in etcd may still be Running"
    fi
  else
    warn "$FLEET_HOME/bin/k8s-up.sh missing — cannot re-apply workload"
  fi

  # --- 4. Record boot proof ------------------------------------------------------
  mkdir -p "$PROOF_DIR"
  _boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || date +%s)"
  {
    echo "boot_id=$_boot_id"
    echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "node=$(hostname)"
    echo "k3s_ready=$_ready"
    echo "images_present=$(_image_present sudo-agent:latest && _image_present sudo-letta:latest && echo true || echo false)"
    echo "--- nodes ---"
    kubectl get nodes 2>/dev/null || echo "(no nodes)"
    echo "--- marc/caesar pods ---"
    kubectl get pods -l 'agent in (marc,caesar)' -o wide 2>/dev/null || echo "(none)"
    echo "--- all pods by phase ---"
    kubectl get pods -A --no-headers 2>/dev/null | awk '{print $4}' | sort | uniq -c || echo "(none)"
  } > "$PROOF_DIR/latest.txt"
  cp "$PROOF_DIR/latest.txt" "$PROOF_DIR/boot-$_boot_id.txt" 2>/dev/null || true
  ok "boot proof recorded at $PROOF_DIR/latest.txt"

  echo ""
  echo "✓ sudo-fleet auto bring-up complete."
  echo "=== k8s-auto-up.sh finished at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
} >> "$LOG_FILE" 2>&1
