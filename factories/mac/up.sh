#!/usr/bin/env bash
set -euo pipefail

# factories/mac/up.sh — stand up key-based SSH access from the lima host to the Mac.
#
# Idempotent and re-runnable: a second run changes nothing and still PASSes.
# Zero interactive prompts (BatchMode ssh, empty-passphrase keygen). Runs on the
# lima host as root — it writes /root/.ssh and the Mac's ~/.ssh/authorized_keys
# via the virtiofs mount /mnt/mac. It writes nothing to the Mac outside that one
# file, and never calls limactl restart.
#
# Order of work:
#   [1] ensure an ed25519 key exists on the lima host for Mac access — REUSE
#       /root/.ssh/id_ed25519 (comment lima-vm-kbd-reset) if present, generate a
#       new one only if none exists. An existing key is never regenerated or
#       overwritten.
#   [2] assert the virtiofs mount /mnt/mac exists and is readable.
#   [3] ensure that pubkey is present EXACTLY ONCE in the Mac's
#       /mnt/mac/Users/aidanmcohen/.ssh/authorized_keys (idempotent append),
#       keeping 700 on .ssh and 600 on the file.
#   [4] prove it for real: a BatchMode ssh to the Mac must answer
#       `hostname; sw_vers -productVersion`, else fail loudly with the error.
#   [5] print a PASS/FAIL summary and exit non-zero on FAIL.

# ── Hardcoded Mac facts (verified live 2026-10-02 — do not re-derive) ────────
MAC_USER="aidanmcohen"
MAC_IP="192.168.5.2"
MAC_MOUNT="/mnt/mac"
MAC_SSH_DIR="$MAC_MOUNT/Users/$MAC_USER/.ssh"
MAC_AUTH_KEYS="$MAC_SSH_DIR/authorized_keys"

HOST_SSH_DIR="/root/.ssh"
HOST_KEY="$HOST_SSH_DIR/id_ed25519"
KEY_COMMENT="lima-vm-kbd-reset"

# The Mac's login shell is zsh, so a remote command containing a bare word that
# starts with '=' (e.g. echo ===FOO===) fails with 'zsh:1: ==FOO=== not found'.
# The probe below uses only hostname / sw_vers, which carry no such markers.
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
REMOTE_PROBE='hostname; sw_vers -productVersion'

PASS=0
FAIL=0
note_ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
note_bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "mac-ssh-hookup: key-based SSH from the lima host to the Mac"
echo "  Mac: $MAC_USER@$MAC_IP  (mount $MAC_MOUNT)"

# ── [1/4] ed25519 key on the lima host ────────────────────────────────────────
echo "→ [1/4] ed25519 key on the lima host"
if [[ ! -d "$HOST_SSH_DIR" ]]; then
  mkdir -p "$HOST_SSH_DIR"
  chmod 700 "$HOST_SSH_DIR"
fi
if [[ -f "$HOST_KEY" ]]; then
  note_ok "reusing existing key $HOST_KEY (never regenerated)"
else
  if ssh-keygen -t ed25519 -N "" -C "$KEY_COMMENT" -f "$HOST_KEY" >/dev/null 2>&1; then
    note_ok "generated new ed25519 key $HOST_KEY (comment $KEY_COMMENT)"
  else
    note_bad "failed to generate $HOST_KEY"
  fi
fi

# Authoritative public key, derived from the private key, so an existing
# lima-vm-kbd-reset key keeps its comment verbatim.
if PUBKEY_LINE="$(ssh-keygen -y -f "$HOST_KEY" 2>/dev/null)"; then
  note_ok "public key derived from $HOST_KEY (comment: ${PUBKEY_LINE##* })"
else
  note_bad "cannot read the public half of $HOST_KEY — is it a valid ed25519 private key?"
fi

# ── [2/4] virtiofs mount /mnt/mac exists + readable ───────────────────────────
echo "→ [2/4] virtiofs mount $MAC_MOUNT"
if [[ ! -d "$MAC_MOUNT" ]]; then
  note_bad "$MAC_MOUNT does not exist (Mac is not sharing its root via virtiofs)"
elif ! ls "$MAC_MOUNT" >/dev/null 2>&1; then
  note_bad "$MAC_MOUNT exists but is not readable"
else
  note_ok "$MAC_MOUNT mounted and readable"
fi

# ── [3/4] pubkey present EXACTLY ONCE in the Mac's authorized_keys ────────────
echo "→ [3/4] pubkey in $MAC_AUTH_KEYS (exactly once)"
if [[ -z "${PUBKEY_LINE:-}" ]]; then
  note_bad "no public key available — cannot touch authorized_keys"
elif [[ ! -d "$MAC_MOUNT" ]] || ! ls "$MAC_MOUNT" >/dev/null 2>&1; then
  note_bad "skipping authorized_keys — $MAC_MOUNT not mounted/readable"
else
  mkdir -p "$MAC_SSH_DIR"
  if [[ "$(stat -c '%a' "$MAC_SSH_DIR" 2>/dev/null || echo 0)" != "700" ]]; then
    chmod 700 "$MAC_SSH_DIR"
  fi
  if [[ ! -f "$MAC_AUTH_KEYS" ]]; then
    touch "$MAC_AUTH_KEYS"
    chmod 600 "$MAC_AUTH_KEYS"
  fi

  _count="$(grep -cFx "$PUBKEY_LINE" "$MAC_AUTH_KEYS" 2>/dev/null || true)"
  if [[ "$_count" -eq 0 ]]; then
    printf '%s\n' "$PUBKEY_LINE" >> "$MAC_AUTH_KEYS"
    note_ok "appended pubkey to $MAC_AUTH_KEYS"
  elif [[ "$_count" -gt 1 ]]; then
    grep -vFx "$PUBKEY_LINE" "$MAC_AUTH_KEYS" > "$MAC_AUTH_KEYS.tmp" || true
    printf '%s\n' "$PUBKEY_LINE" >> "$MAC_AUTH_KEYS.tmp"
    mv "$MAC_AUTH_KEYS.tmp" "$MAC_AUTH_KEYS"
    note_ok "deduplicated pubkey to exactly one in $MAC_AUTH_KEYS"
  else
    note_ok "pubkey already present exactly once (no change)"
  fi
  if [[ "$(stat -c '%a' "$MAC_AUTH_KEYS" 2>/dev/null || echo 0)" != "600" ]]; then
    chmod 600 "$MAC_AUTH_KEYS"
  fi
fi

# ── [4/4] end-to-end ssh verify ───────────────────────────────────────────────
echo "→ [4/4] end-to-end ssh verify ($MAC_USER@$MAC_IP)"
if SSH_OUT="$(ssh "${SSH_OPTS[@]}" "$MAC_USER@$MAC_IP" "$REMOTE_PROBE" 2>&1)"; then
  note_ok "ssh answered: $(printf '%s' "$SSH_OUT" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
else
  note_bad "ssh FAILED — exact error: $SSH_OUT"
fi

# ── [5/5] summary ─────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
if [[ "$FAIL" -gt 0 ]]; then
  echo "RESULT: FAIL  ($PASS passed, $FAIL failed)"
  exit 1
fi
echo "RESULT: PASS  ($PASS passed, $FAIL failed)"
