# LAYOUT — the sudo-fleet directory topology

> Canonical directory structure. `sudo-fleet` is the **top-level application directory** for the whole fleet. The two factories and the glimor store all live *inside* it. This is the spine every other doc (GLIMORS, BUILD-STEPS, up.sh paths) hangs off. Branch `glimors`.

## The layout

```
/opt/sudo-fleet/                    ← THE top — the fleet application directory
├── deployments/                    ← the glimor store: one folder per agent
│   ├── fa-glm-l/
│   │   ├── fa-glm-l.yaml           ← wiring (written by the factory, not in the repo)
│   │   └── pvc/                    ← state (hostPath — live agent brain)
│   ├── fa-glm-h/
│   │   ├── fa-glm-h.yaml
│   │   └── pvc/
│   └── ...
├── sudo-letta/                     ← planner factory (repo, folded inside)
├── sudo-agent/                     ← engineer factory (repo, folded inside)
├── spec/                           ← SPEC.md, GLIMORS.md, BUILD-STEPS.md, LAYOUT.md  (or at top level)
├── setup.sh                        ← boots the empty room
└── ... (a few other things: cluster config, other subdirs TBD)
```

## The principles

1. **`sudo-fleet` is the top.** Not `/opt/0-0/sudo-fleet/` — it is `/opt/sudo-fleet/`, the root of everything.
2. **`deployments/` is a top-level sibling of the factories**, *not* nested inside either one. This is the glimor store: every agent lives there as `<name>/yaml + pvc/`.
3. **The two factory repos live inside** — `sudo-letta/` (planners) and `sudo-agent/` (engineers) are subdirectories of `sudo-fleet`, matching the "one repo = one entity" vision (factories folded into the one repo).
4. **Spec docs live alongside** — SPEC.md / GLIMORS.md / BUILD-STEPS.md / LAYOUT.md at the top or under `spec/`. (Not yet pinned which — see open question.)

## What this resolves

- Kills the `/opt/0-0/` vs `sudo-fleet` ambiguity: the canonical path is **`/opt/sudo-fleet/`** as the app root, with `deployments/` + both factories *inside* it.
- The glimor path becomes **`/opt/sudo-fleet/deployments/<name>/pvc`** and the yaml **`/opt/sudo-fleet/deployments/<name>/<name>.yaml`**.
- One repo = one entity, literally: clone `sudo-fleet` and you get the factories + the glimor store + the spec, in one tree.

## Open / to confirm

- **Spec docs at top level vs `spec/`?** This doc lists both; pin one.
- **Git boundary** — `deployments/<name>/pvc/` is live runtime state and must **not** be committed. The `.gitignore` (or a `deployments/` submodule/git-exclusion) must exclude `pvc/` while tracking `*.yaml`. This is the leak guard.
- **Which other subdirs** — "a few other things" (cluster config, the `admin-user.kubeconfig`, etc.) — where they land inside `sudo-fleet` is TBD.
