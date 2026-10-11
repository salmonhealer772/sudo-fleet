# bin/hooks — change-protocol enforcement

These hooks turn the change protocol from advisory into **enforced**: a complex
change (one touching deployment/runtime surface) cannot be committed without a
verification record under `docs/verifications/`.

## Install

    bin/hooks/install.sh

Installs `pre-commit` into this repo's `.git/hooks/`. Idempotent — safe to
re-run. A pre-existing foreign hook is backed up (`.orig`) and chained to, never
silently replaced.

## Bypass (genuine emergency only)

    git commit --no-verify

This skips the hook entirely. Use it only for a real emergency.

## Why a bypass is a failure to be recorded

`--no-verify` means the change lands with no verification record, so the exact
gap the protocol exists to close is silently reopened. A bypass is therefore
itself a protocol failure: record it — a note in the commit/PR, and a
verification record added as soon as possible afterward — so the unverified
change stays visible rather than quietly shipping.
