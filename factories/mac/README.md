# mac factory — key-based SSH from the lima host to the Mac

`up.sh` stands up passwordless, key-based SSH access from the lima host to the
Mac, idempotently and end-to-end.

**The Mac** (verified live 2026-10-02, hardcoded in `up.sh` — do not re-derive):
MacBook Pro M4 Pro (`Mac16,7`), macOS 26.6.2, hostname
`Aidans-MacBook-Pro.local`, LAN IP `192.168.5.2`, Mac-side user `aidanmcohen`.
`/mnt/mac` is the Mac's whole root mounted read/write over virtiofs, so
`/mnt/mac/Users/aidanmcohen/.ssh/authorized_keys` IS the Mac's real
`~/.ssh/authorized_keys`.

## Run it

```bash
sudo bash factories/mac/up.sh
```

Runs on the lima host as root (it writes `/root/.ssh` and the Mac's
`~/.ssh/authorized_keys` via `/mnt/mac`). Zero interactive prompts — the ssh
probe uses `BatchMode`, and a new key is generated with an empty passphrase.

## What it guarantees

1. **An ed25519 key exists on the lima host for Mac access.** It REUSES
   `/root/.ssh/id_ed25519` (comment `lima-vm-kbd-reset`) when present, and
   generates a new key only if none exists. An existing key is never regenerated
   or overwritten; its comment stays `lima-vm-kbd-reset`.
2. **That pubkey is present EXACTLY ONCE** in
   `/mnt/mac/Users/aidanmcohen/.ssh/authorized_keys` (idempotent append), with
   `700` on `.ssh` and `600` on the file.
3. **The virtiofs mount `/mnt/mac` exists and is readable** (asserted before any
   write into it).
4. **REAL end-to-end proof.** The script runs
   `ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new aidanmcohen@192.168.5.2 'hostname; sw_vers -productVersion'`
   and requires an answer, else it fails loudly with the exact ssh error.
5. **A PASS/FAIL summary** is printed; a non-zero exit means FAIL.

It writes nothing to the Mac outside `~/.ssh/authorized_keys`, and never calls
`limactl restart`.

## Verified failure modes

- `/mnt/mac` missing → FAIL: "virtiofs mount missing" (the Mac is not sharing its
  root to the lima VM).
- `/mnt/mac` present but unreadable → FAIL.
- `~/.ssh/authorized_keys` missing → created (700/600) and the pubkey appended.
- pubkey duplicated in `authorized_keys` (defensive) → deduplicated to exactly one.
- Mac unreachable / key not yet authorized → the ssh probe fails loudly with the
  raw ssh error (never papered over).

## Run it again on a fresh Mac

On a Mac that has never authorized the key:

1. Ensure the Mac shares its whole root to the lima VM over virtiofs at
   `/mnt/mac` (read/write), and that the lima host can reach it at `192.168.5.2`.
2. Run `sudo bash factories/mac/up.sh`. It will:
   - reuse the existing lima-host key (no new key), or generate one if absent;
   - write the pubkey into `/mnt/mac/Users/aidanmcohen/.ssh/authorized_keys`
     (700/600) — the Mac's real `~/.ssh/authorized_keys` via virtiofs;
   - prove it by ssh-ing to the Mac and printing `hostname` + the macOS version.
3. If the ssh probe still fails on a fresh Mac, check that the mount really maps
   to the Mac's root and that the target user's `.ssh` ownership/modes are
   correct on the Mac side (sshd rejects `authorized_keys` with bad ownership or
   modes).

## Gotcha (hardcoded, do not re-derive)

The Mac's login shell is **zsh**: any remote command containing a bare word that
starts with `=` (e.g. `echo ===FOO===`) fails with `zsh:1: ==FOO=== not found`.
`up.sh`'s probe (`hostname; sw_vers -productVersion`) avoids `=` markers entirely.
