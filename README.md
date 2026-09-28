# sudo-fleet

A disposable room you stand up anywhere: saved agents are pulled in, talk to each other, and survive the room's destruction. The full spec lives in `SPEC.md`.

## Your fleet is up (two commands)

On a bare Linux box (systemd + curl/wget/git/tailscale — no docker/k3s yet):

**Command 1 — bootstrap** (docker + k3s + clone repos + build images, non-interactive):

```bash
cd /opt/0-0/sudo-fleet && bash setup.sh
```

First, drop your keys into `/opt/0-0/.env`:

```
DEEPSEEK_API_KEY=...            # sudo-agent / Hermes
GITHUB_TOKEN=...                # GitHub PAT for authenticated clone/pull of the repos
LLM_PROVIDER=deepseek           # sudo-letta / Letta (openai|anthropic|deepseek|...)
API_KEY=...                     # sudo-letta / Letta
LLM_BASE_URL=https://api.deepseek.com/v1   # optional, OpenAI-compatible
TAVILY_API_KEY=...              # letta web_search needs one (or EXA_/PARALLEL_/PERPLEXITY_)
```

> `/.env` and `/glimors/` are gitignored — secrets and saved agent state stay out of the repo.

**Command 2 — bring up the cluster + stand up Marc + Caesar:**

```bash
cd /opt/0-0/sudo-fleet/kube-scripts && bash k8s-up.sh
```

This deploys `sudo-marc` (Letta planner) and `sudo-caesar` (Hermes engineer),
then seeds their identity from saved glimors — Marc wakes up AS psnvc, Caesar
wakes up AS forge — and they diverge independently from there.

## Glimor seed (portable identity)

A **glimor** is a saved snapshot of an agent's identity + live state, stored as
plain files under `/opt/0-0/glimors/`:

- `glimors/psnvc/` — the whole Letta brain (persona + memory blocks + skills), i.e. the `/home/node/.letta` tree.
- `glimors/forge/`  — the Hermes identity: `SOUL.md` + `state.db` + `.hermes_history` + `.local` + `cache`.

**Capture** them on a box that has the live pair running:

```bash
cd /opt/0-0/sudo-fleet/kube-scripts && bash save-glimor.sh
```

**Move** them to a fresh box (they are just files — no live pod needed at restore time):

```bash
tar czf glimors.tgz -C /opt/0-0 glimors     # then copy + extract on the fresh box
```

`k8s-up.sh` restores from `glimors/` if present; if a glimor dir is missing it
deploys that agent EMPTY (factory defaults) and warns loudly.

## Tear down

```bash
cd /opt/0-0/sudo-fleet/kube-scripts && bash k8s-down.sh                 # stop agents, PRESERVE PVCs (state)
cd /opt/0-0/sudo-fleet/kube-scripts && bash k8s-down.sh --purge          # also delete PVCs
cd /opt/0-0/sudo-fleet/kube-scripts && bash k8s-down.sh --teardown-k3s   # uninstall k3s too
```

(The repo-root `down.sh` is a thin pointer to `kube-scripts/k8s-down.sh`.)

## What setup.sh touches on your box (outside sudo-fleet/)

`setup.sh` (Command 1) is a bootstrap and by design writes system-wide. Everything it touches outside `/opt/0-0/sudo-fleet/`:

- **Docker** (get.docker.com): `/usr/bin/` docker binaries, `/etc/systemd/system/docker.service` + `containerd.service`, `/var/lib/docker` (images), `/var/lib/containerd`, adds the invoking user to the `docker` group, `/etc/docker/`.
- **k3s** (get.k3s.io): `/usr/local/bin/k3s` (+ `kubectl`/`crictl`/`ctr` symlinks), `/etc/systemd/system/k3s.service`, `/var/lib/rancher/k3s/` (all cluster data), `/etc/rancher/k3s/k3s.yaml` (kubeconfig), `/var/lib/kubelet`.
- **`/etc/hosts`** may be touched by docker/k3s (rare); docker also installs its own iptables rules.
- **Hidden/other**: `~/.docker` (docker CLI config). `~/.kube` is NOT created by us — the fleet scripts use `/etc/rancher/k3s/k3s.yaml`.
- **Sibling repos + state under the fleet home** `/opt/0-0/` (outside `sudo-fleet/` but inside `/opt/0-0`): `/opt/0-0/sudo-agent`, `/opt/0-0/sudo-letta`, `/opt/0-0/.env`, `/opt/0-0/glimors/`.
