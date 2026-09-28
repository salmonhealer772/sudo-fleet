# sudo-fleet

A disposable room you stand up anywhere: saved agents are pulled in, talk to each other, and survive the room's destruction. The full spec lives in `SPEC.md`.

Everything lives inside ONE folder — `sudo-fleet/`. The two factory repos (`sudo-agent`, `sudo-letta`), your `.env` secrets, and the saved `glimors/` state are all nested inside it. No siblings, nothing outside it.

## Your fleet is up (two commands)

On a bare Linux box (systemd + curl/wget/git/tailscale — no docker/k3s yet):

**Command 1 — bootstrap** (prompts for keys, installs docker + k3s, clones the
factories INSIDE `sudo-fleet/`, builds images). Run it from ANY directory:

```bash
git clone https://github.com/salmonhealer772/sudo-fleet.git && cd sudo-fleet && bash setup.sh
```

`setup.sh` asks for exactly three things up front — one LLM API key (used by
BOTH agents), the LLM API URL (defaults to `deepseek` if left blank), and an
optional Tavily web-search key — then derives and writes the rest to
`sudo-fleet/.env`:

```
LLM_API_KEY=...                 # ANY LLM API key — one key for BOTH agents (Hermes + Letta)
LLM_BASE_URL=...                # LLM API URL (default https://api.deepseek.com/v1 if blank)
TAVILY_API_KEY=...              # optional — letta search mods
```

It derives (never prompts for) the rest:

```
DEEPSEEK_API_KEY=$LLM_API_KEY        # sudo-agent / Hermes
API_KEY=$LLM_API_KEY                 # sudo-letta / Letta
LLM_PROVIDER=<derived from LLM_BASE_URL>   # deepseek|anthropic|openai|...
LLM_BASE_URL=$LLM_BASE_URL           # defaulted to https://api.deepseek.com/v1 if blank
TAVILY_API_KEY=$TAVILY_API_KEY       # may be empty
```

> `sudo-fleet/.env`, `sudo-fleet/glimors/`, `sudo-fleet/sudo-agent/` and
> `sudo-fleet/sudo-letta/` are all gitignored — secrets, saved agent state, and
> the nested clone trees stay out of the repo.

**Command 2 — bring up the cluster + stand up Marc + Caesar:**

```bash
cd kube-scripts && bash k8s-up.sh
```

This deploys `sudo-marc` (Letta planner) and `sudo-caesar` (Hermes engineer),
then seeds their identity from saved glimors — Marc wakes up AS psnvc, Caesar
wakes up AS forge — and they diverge independently from there.

## One-folder layout

```
sudo-fleet/
├── setup.sh              # Command 1 — prompt keys, docker+k3s, clone factories, build images
├── README.md
├── SPEC.md
├── .gitignore
├── down.sh               # thin pointer -> kube-scripts/k8s-down.sh
├── .env                  # your keys (gitignored, written by setup.sh)
├── sudo-agent/           # Hermes engineer factory (nested clone, gitignored)
├── sudo-letta/           # Letta planner factory (nested clone, gitignored)
├── glimors/              # saved agent identity (gitignored)
│   ├── psnvc/            # Letta brain (persona + memory + skills)
│   └── forge/            # Hermes identity (SOUL.md + state.db + history)
└── kube-scripts/
    ├── k8s-up.sh         # Command 2 — deploy Marc + Caesar, seed glimors
    ├── k8s-down.sh       # stop / purge / teardown
    └── save-glimor.sh    # snapshot the live pair into glimors/
```

## Glimor seed (portable identity)

A **glimor** is a saved snapshot of an agent's identity + live state, stored as
plain files under `sudo-fleet/glimors/`:

- `glimors/psnvc/` — the whole Letta brain (persona + memory blocks + skills), i.e. the `/home/node/.letta` tree.
- `glimors/forge/`  — the Hermes identity: `SOUL.md` + `state.db` + `.hermes_history` + `.local` + `cache`.

**Capture** them on a box that has the live pair running:

```bash
cd kube-scripts && bash save-glimor.sh
```

**Move** them to a fresh box (they are just files — no live pod needed at restore time):

```bash
tar czf glimors.tgz -C sudo-fleet glimors     # then copy + extract on the fresh box
```

`k8s-up.sh` restores from `glimors/` if present; if a glimor dir is missing it
deploys that agent EMPTY (factory defaults) and warns loudly.

## Tear down

```bash
cd kube-scripts && bash k8s-down.sh                 # stop agents, PRESERVE PVCs (state)
cd kube-scripts && bash k8s-down.sh --purge          # also delete PVCs
cd kube-scripts && bash k8s-down.sh --teardown-k3s   # uninstall k3s too
```

(The repo-root `down.sh` is a thin pointer to `kube-scripts/k8s-down.sh`.)

## What setup.sh touches on your box (outside sudo-fleet/)

`setup.sh` (Command 1) is a bootstrap and by design writes system-wide. FLEET_HOME is now the `sudo-fleet/` folder itself, so the repos, `.env`, and `glimors/` all live INSIDE it — nothing fleet-related is written outside `sudo-fleet/`. What it does touch outside `sudo-fleet/` is limited to the system-level tooling:

- **Docker** (get.docker.com): `/usr/bin/` docker binaries, `/etc/systemd/system/docker.service` + `containerd.service`, `/var/lib/docker` (images), `/var/lib/containerd`, adds the invoking user to the `docker` group, `/etc/docker/`.
- **k3s** (get.k3s.io): `/usr/local/bin/k3s` (+ `kubectl`/`crictl`/`ctr` symlinks), `/etc/systemd/system/k3s.service`, `/var/lib/rancher/k3s/` (all cluster data), `/etc/rancher/k3s/k3s.yaml` (kubeconfig), `/var/lib/kubelet`.
- **`/etc/hosts`** may be touched by docker/k3s (rare); docker also installs its own iptables rules.
- **Hidden/other**: `~/.docker` (docker CLI config). `~/.kube` is NOT created by us — the fleet scripts use `/etc/rancher/k3s/k3s.yaml`.
