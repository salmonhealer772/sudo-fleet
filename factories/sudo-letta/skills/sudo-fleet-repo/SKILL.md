---
name: sudo-fleet-repo
description: The sudo-fleet repo map, deploy commands, and identity locations. Load before planning any sudo-fleet work.
version: 0.1.0
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [sudo-fleet, repo, deploy, identity]
---

# sudo-fleet repo facts

The one repo this team develops. Load this before planning any change.

## The repo

- Path on lima: **`/opt/0-0/sudo-fleet`** (this is the live checkout, not a mirror).
- Remote: `https://github.com/salmonhealer772/sudo-fleet.git`, branch **`main`**. **Public repo.**
- Auth: `GITHUB_TOKEN` / `GH_TOKEN` in `/opt/0-0/sudo-fleet/.env` and `/root/.git-credentials`. Use them; never print, echo, or commit them.
- Public repo ⇒ never commit a secret, a real email, a persona containing somebody's private data, or a glimor of a living person's agent. If a change would put one in, stop and report.

## Layout that matters

```
/opt/0-0/sudo-fleet
├── setup.sh                     # bootstrap: keys → docker+k3s → build images → stand up room
├── down.sh
├── README.md                    # the operator treats this as the contract
├── .env                         # gitignored secrets
├── bin/                         # k8s-up.sh, k8s-down.sh, talk-ALL*.sh, verify-change.sh, hooks/pre-commit
├── docs/                        # SPEC.md, NEXT.md, comm-mods-PACKAGING.md, ...
├── deployments/                 # COMMITTED glimors (Marc, Caesar, ...) — public!
├── factories/
│   ├── sudo-letta/              # Letta planner factory
│   │   ├── bin/up.sh            # deploy a planner; --name, --from-glimor
│   │   ├── mods/                # local mod packages (list-siblings, message-agent, check-agent, ...)
│   │   ├── skills/              # seeded into every planner's MemFS on deploy
│   │   └── deployments/         # per-agent yamls written by up.sh (gitignored)
│   └── sudo-agent/              # Hermes engineer factory
│       ├── bin/up.sh
│       ├── config/<name>.yaml   # per-agent Hermes config (model, display.skin, plugins)
│       ├── comm/                # tools + skills + persona snippet shared by both halves
│       └── deployments/         # per-agent yamls
└── glimors/                     # local glimor scratch (gitignored)
```

## The two deploy commands (the whole deployment surface)

```bash
# Letta planner
bash /opt/0-0/sudo-fleet/factories/sudo-letta/bin/up.sh --<name>
# Hermes engineer
bash /opt/0-0/sudo-fleet/factories/sudo-agent/bin/up.sh --<name>
```

Both prepend `sudo-` themselves. Passing `sudo-fleet-glm-l` gives deployment `sudo-sudo-fleet-glm-l`. Both are idempotent; both write `factories/<f>/deployments/<name>.yaml`; both seed skills and install the mod set from `up.sh`'s own arrays.

Tear down one: `bash /opt/0-0/sudo-fleet/bin/k8s-down.sh --<name>` (check its flags first).

## Identity: where it actually lives

- **Letta planner:** `system/persona.md` inside its live MemFS dir (`/home/node/.letta/lc-local-backend/memfs/agent-local-<id>/memory/`). Only the ACTIVE `agent-local-*` dir counts. A persona committed from outside does not inject — the agent must self-write it.
- **Hermes engineer:** `/opt/data/SOUL.md` (hostPath-bind-mounted; edit the host-side file).
- Both file kinds end with the factory-managed block bounded by `<!-- FLEET-COMM-AWARENESS-BEGIN -->` / `<!-- FLEET-COMM-AWARENESS-END -->`. Anything hand-added goes after END; inside it gets rewritten on the next deploy.

## Model

`.env` carries `LLM_PROVIDER=deepseek` and the API keys. Hermes reads `model.default` + `model.provider` from `config/<name>.yaml`; Letta's handle is `deepseek/deepseek-flash` (`letta model set deepseek-flash` bare — it qualifies). Verify against `letta model list` inside a pod before writing a handle down.
