---
description: THE glimor format spec — what a glimor directory contains, how identity+state+agent-record travel, and the rename contract. Supersedes the older "yaml + hostPath pvc/ under deployments/" model in one-repo-fleet-spec.md.
---

# GLIMOR-FORMAT — the single source of truth (2026-09-29)

A **glimor** is a portable, forkable snapshot of ONE agent's full state — enough to stand that agent up on any fleet with `up.sh --from-glimor <dir>`, waking as a RENAMED FORK (not the source agent, and NOT a blank default agent).

## The load-bearing truth this spec corrects

An agent is **NOT its persona/SOUL files**. An agent is its **full state volume**:

- **Letta** (planner): the agent RECORD (`agent id`, name, description, compiled system prompt, model, memory-block refs) lives in the Letta local backend at `$LETTA_HOME/lc-local-backend/agents/<base64url(agent-id)>.json`, and the memfs is keyed to that agent id (`$LETTA_HOME/lc-local-backend/memfs/<agent-id>/`). Copying `persona.md` into a fresh PVC does NOTHING — on first `letta` launch, the CLI auto-creates a brand-new **Tutor** agent because there is no record to resume.
- **Hermes** (engineer): identity + config + state live at `$HERMES_HOME` (= `/opt/data`): `SOUL.md`, `config.yaml`, `state.db`, `.hermes_history`, `.local/`.

So a glimor MUST carry the agent record + agent-id-keyed memfs (Letta) / the full HERMES_HOME state (Hermes), NOT hand-picked identity files.

## Dir layout

```
glimors/<name>/                        # one glimor = one directory = one agent
├── kind                     # "letta" | "hermes"
├── name                     # the CURRENT name of this fork (what it wakes as)
├── meta.yaml                # { kind, source_agent_id, name, model, ports }
├── letta/ OR hermes/        # the actual state volume, captured whole
└── allowlist.txt            # exact file/dir list that ships (see below)
```

### Letta glimor — `glimors/<name>/letta/` carries (allowlist):
- `lc-local-backend/agents/<b64url(agent-id)>.json`   — the agent RECORD (full system prompt + name + model)
- `lc-local-backend/memfs/<agent-id>/`                 — the brain (persona + human + reference + skills + all memory)
- `lc-local-backend/conversations/<b64url(conversation-id)>*` — message history (optional but preferred)
- `settings.json` if present (agent settings)

### Hermes glimor — `glimors/<name>/hermes/` carries (allowlist):
- `SOUL.md`, `config.yaml`, `state.db`, `.hermes_history`, `.local/`
- NOT the accumulated /opt/data cruft (other agents' souls, briefs, tokens, .venv, build dirs)

## How to load it (the mechanism, verified from source)

1. **Seed the PVC BEFORE the agent process runs** — populate `/home/node/.letta/` (Letta) or `/opt/data/` (Hermes) from the glimor (init container, or `kubectl cp` immediately after pod is up and Ready but before first `letta` interaction).
2. **Attach to the seeded agent** — do NOT let `letta` auto-create Tutor. For Letta, resume the seeded agent-id (set the active/current agent to the record's id; the exact env/flag is `LETTA_LOCAL_BACKEND_DIR` for the storage location — the agent to *resume* is whichever record is in `lc-local-backend/agents/`; verify the active-agent selector in the CLI before finalizing any `--agent`/env flag — do NOT guess a flag name).

## The rename contract

The fork wakes as a NEW name (`psnvc`→`Marc`, `forge`→`Caesar`). Rewrite ONLY:
- the **identity name** (`name` field in the Letta record / the `persona.md` first line; `SOUL.md` "You are forge" → "You are Caesar")
- the **planner↔engineer pointer**: Marc's persona says his engineer is Caesar; Caesar's SOUL says his planner is Marc.
NO blind find-and-replace. `deploy/sudo-forge`, `deploy/sudo-<name>`, k8s paths, bridge commands, and every other literal MUST survive untouched. The rename is a **one-way copy**: editing the live fork never writes back to the glimor.

## Secrets

The glimor NEVER contains secrets. API keys / tokens / passwords / provider creds come from the `setup.sh` key gate at deploy time. Before shipping a glimor, SCRUB: API keys, tokens, passwords from `state.db`, `.hermes_history`, memory files, and any personal/family contact info (emails, names) if the repo is public. List everything scrubbed.

**The repo IS public (confirmed 2026-09-29):** `salmonhealer772/sudo-fleet` (and the `sudo-agent`/`sudo-letta` factory repos under the same account) return HTTP 200 unauthenticated, so the PII scrub is **mandatory, not conditional**. The specific PII that must NOT ship in a committed glimor (found in psnvc's own `human.md` + reference files): family/employee emails — `[REDACTED]` (mother), `[REDACTED]` (father), `[REDACTED]` (personal), `[REDACTED]` ([REDACTED], boss), `[REDACTED]` ([REDACTED]). The actual API keys (`sk-…` / `tvly-dev-…`) are already redacted in memory as `<sk-…>` placeholders (they live in the secret store, not memory) — but the *bare emails/names* are plaintext and must be scrubbed before any glimor is committed/pushed.

**Beware the `--from-glimor` seed bloat:** a full memfs export is ~11MB (`.git` history + `profile.png` + worktrees), and it drags in every `reference/` file — including the Vast-credentials and family-PII files above. Export with an explicit **allowlist** (the dir layout's `allowlist.txt`), not a whole-tree `cp -r`, so scrubbed/sensitive files never enter the glimor in the first place.

## Conflicts resolved

This REPLACES the older "yaml + hostPath pvc/ under deployments/" model in `reference/one-repo-fleet-spec.md`. Chosen because: the k3s `local-path` PVC is a UUID-mangled dir invisible to copy; a plain `glimors/<name>/` dir the depot owns is human-readable, git-trackable, and directly forkable. The hostPath `pvc/` idea is subsumed: the glimor IS the portable state dir; the runtime PVC is just a working mount at deploy time.
