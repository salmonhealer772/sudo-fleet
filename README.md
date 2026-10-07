# sudo-fleet

A disposable room you stand up anywhere: saved agents are pulled in, talk to each other, and survive the room's destruction. The full spec lives in [`docs/SPEC.md`](docs/SPEC.md).

**Next direction (2026-10-01):** [multiple independent project fleets in one
cluster](docs/NEXT.md), with namespace-scoped agents/state and fleet pause/resume.
An optional shared-services namespace is under consideration. This is the next
planned capability, not something the current setup commands already implement.

Everything lives inside ONE folder — `sudo-fleet/`. The two factory trees (`factories/sudo-agent`, `factories/sudo-letta`), your `.env` secrets, and the committed `deployments/{Marc,Caesar}/` glimors are all nested inside it. No siblings, nothing outside it.

## Your fleet is up (two commands)

On a bare Linux box (systemd + curl/wget/git/tailscale — no docker/k3s yet):

**Command 1 — bootstrap** (prompts for keys, installs docker + k3s, builds both
factory images from the vendored `factories/`). Run it from ANY directory:

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

> `sudo-fleet/.env` is gitignored — the secrets stay out of the repo.
> The two factories are IN the repo at `factories/sudo-agent/` and
> `factories/sudo-letta/` (their own live `.env`/`deployments/` stay untracked).
> `sudo-fleet/deployments/{Marc,Caesar}/` (the committed glimors) ARE tracked.

## Paperclip is built in (auto-hire)

sudo-fleet ships with **Paperclip**, the agent control plane, and every agent it
stands up is **hired automatically** — Marc, Caesar, ONalwase, and any new agent
you build. `bin/k8s-up.sh` deploys the control plane after the router pair and
hires everything; each `up.sh --<agent>` hires the agent it just built; and
`bin/k8s-auto-up.sh` reconciles on every boot. Hired means: an agent record on
the `letta_local` MCP-door adapter pointed at the LIVE pod, `runtimeConfig`
heartbeat enabled, and `PAPERCLIP_*` credentials injected into the agent's own
Deployment so it can close the issue it was woken for. See
[`docs/PAPERCLIP.md`](docs/PAPERCLIP.md).

## Custom / Featherless provider

To use a custom OpenAI-compatible endpoint (e.g. Featherless), set the
following in `sudo-fleet/.env` alongside the existing `LLM_API_KEY`:

```
LLM_BASE_URL=https://api.featherless.ai/v1
LLM_PROVIDER=openai
LLM_MODEL=deepseek-ai/DeepSeek-V4-Pro
```

- `LLM_BASE_URL` — the full base URL of your OpenAI-compatible endpoint.
  Defaults to `https://api.deepseek.com/v1` if left blank.
- `LLM_PROVIDER` — derived from `LLM_BASE_URL` by default; override
  explicitly when the auto-detection is wrong (e.g. `openai` for
  Featherless).
- `LLM_MODEL` — **must be set explicitly** for non-DeepSeek providers.
  Pick a model with a large context window (>=64K tokens). Hermes
  rejects models under 64K context; a model like `deepseek-ai/DeepSeek-V4-Pro`
  satisfies this requirement.

The `.env` vars `LLM_MODEL`, `LLM_BASE_URL`, and `LLM_PROVIDER` are the
single source of truth consumed by both agent factories. Do not put real
API keys in the repo — use a placeholder such as `<LLM_API_KEY>`.

**Command 2 — bring up the cluster + stand up Marc + Caesar:**

```bash
cd bin && bash k8s-up.sh
```

This deploys `sudo-marc` (Letta planner) and `sudo-caesar` (Hermes engineer),
seeding their identity from the committed glimors via an initContainer — Marc
wakes up AS Marc (the renamed psnvc), Caesar AS Caesar (the renamed forge) —
and they diverge independently from there.

## One-folder layout

```
sudo-fleet/
├── setup.sh              # Command 1 — prompt keys, docker+k3s, build images from factories/
├── README.md
├── docs/                 # spec + status + plans (SPEC, KNOWN-ISSUES, NEXT, …)
├── .gitignore
├── down.sh               # thin pointer -> bin/k8s-down.sh
├── .env                  # your keys (gitignored, written by setup.sh)
├── factories/            # the two default agent factories (in-repo)
│   ├── sudo-agent/       # Hermes engineer factory
│   └── sudo-letta/       # Letta planner factory
├── deployments/          # committed glimors (the router pair's identity)
│   ├── Marc/             # Letta planner (renamed from psnvc)
│   └── Caesar/           # Hermes engineer (renamed from forge)
└── bin/
    ├── k8s-up.sh         # Command 2 — deploy Marc + Caesar, seed from committed glimors
    └── k8s-down.sh       # stop / purge / teardown
```

## Glimor seed (committed identity)

A **glimor** is a committed snapshot of one agent's full resumable state, stored
under `sudo-fleet/deployments/`:

- `deployments/Marc/`   — the Letta planner (renamed from psnvc): its identity
  files (`name`, `kind`, `meta.yaml`, `allowlist.txt`, `settings.json`),
  scrubbed for the public repo. Its regenerable state (the `memfs` brain, agent
  records, sessions) is NOT committed — a fresh box seeds the identity and lets
  the agent rebuild its working state.
- `deployments/Caesar/` — the Hermes engineer (renamed from forge): `SOUL.md` +
  `config.yaml` + `name`/`kind`/`meta.yaml`/`allowlist.txt`, scrubbed. Live
  state (`state.db`, `.hermes_history`, `.local/`) is NOT committed.

They are **committed** (not gitignored), so a fresh box gets them with the repo.
`k8s-up.sh` passes each to the factory `up.sh --from-glimor <dir>`; the factory
deploys an **initContainer** that copies the glimor into the PVC *before* the
agent process starts. A missing or invalid glimor fails the deploy loudly — a
blank Tutor / bare Hermes can never come up.

## Native comm layer (every agent is born able to talk)

Both factories ship three comm abilities as a spawn-time default — `list-siblings`
(the live roster), `message-agent` (message any sibling by name), `check-agent`
(read a sibling's trail) — each as a tool + skill + a shared persona-awareness
block. Two mechanisms make them stick:

- **Load-skill-first gate** — a tool refuses to run until its matching skill is
  loaded in the current conversation (Hermes: `comm_gate.py` exit 69 + the
  `sudo-comm-gate` plugin; Letta: each comm mod's `gate.mjs`). Fail-closed in a
  session, fail-open for a human/script.
- **Factory-managed FLEET-COMM-AWARENESS block** — the shared awareness text
  (`factories/sudo-agent/comm/PERSONA-SNIPPET.md`) is applied to `SOUL.md`
  (Hermes) / `system/persona.md` (Letta) on EVERY boot, between fixed BEGIN/END
  markers, so an agent can't permanently lose or stale its fleet awareness.

The full contract is in `docs/SPEC.md` ("Native cross-agent communication"); the
known gaps are in `docs/KNOWN-ISSUES.md`.

## Tear down

```bash
cd bin && bash k8s-down.sh                 # stop agents, PRESERVE PVCs (state)
cd bin && bash k8s-down.sh --purge          # also delete PVCs
cd bin && bash k8s-down.sh --teardown-k3s   # uninstall k3s too
```

(The repo-root `down.sh` is a thin pointer to `bin/k8s-down.sh`.)

## Durable cluster (comes back on its own)

The two commands above are the *only* commands you ever run. After that the
cluster is durable:

- **k3s starts on boot** — `setup.sh` ensures `k3s.service` + `docker.service`
  are enabled (and, on WSL2, writes `/etc/wsl.conf` `[boot] systemd=true` so
  systemd actually boots).
- **Images survive a restart** — the agent images are imported into the k3s
  containerd store, which lives on disk, so no pod ever needs to pull a
  local-only image.
- **Everything up.sh created is recreated on boot** — `setup.sh` installs a
  oneshot systemd unit (`sudo-fleet-boot.service`) that runs
  `bin/k8s-auto-up.sh` on every boot: it waits for k3s to be Ready,
  re-imports any missing images, and re-runs the idempotent bring-up.
- **Pods restart themselves on crash/hang** — every agent and watch container
  ships a `startupProbe` + `readinessProbe` + `livenessProbe`, so a crashed or
  hung pod is restarted by kubelet without any operator action.

The result: reboot the box (or your WSL2 distro) and the fleet is simply back,
with memory intact and zero commands run.

> WSL2 note: Linux cannot force Windows to start WSL2 itself. The one manual
> step — run once, from an admin PowerShell — is:
> `schtasks /create /tn "WSL2-sudo-fleet" /tr "wsl.exe -d <distro>" /sc onlogon /rl highest`
> (`setup.sh` prints this too.)

## What setup.sh touches on your box (outside sudo-fleet/)

`setup.sh` (Command 1) is a bootstrap and by design writes system-wide. FLEET_HOME is now the `sudo-fleet/` folder itself, so the repos, `.env`, and `deployments/` glimors all live INSIDE it — nothing fleet-related is written outside `sudo-fleet/`. What it does touch outside `sudo-fleet/` is limited to the system-level tooling:

- **Docker** (get.docker.com): `/usr/bin/` docker binaries, `/etc/systemd/system/docker.service` + `containerd.service`, `/var/lib/docker` (images), `/var/lib/containerd`, adds the invoking user to the `docker` group, `/etc/docker/`.
- **k3s** (get.k3s.io): `/usr/local/bin/k3s` (+ `kubectl`/`crictl`/`ctr` symlinks), `/etc/systemd/system/k3s.service`, `/var/lib/rancher/k3s/` (all cluster data), `/etc/rancher/k3s/k3s.yaml` (kubeconfig), `/var/lib/kubelet`.
- **Durable boot** (new): `/etc/systemd/system/sudo-fleet-boot.service` (a oneshot unit that re-runs the bring-up on every boot) and, on WSL2, `/etc/wsl.conf` `[boot] systemd=true`.
- **`/etc/hosts`** may be touched by docker/k3s (rare); docker also installs its own iptables rules.
- **Hidden/other**: `~/.docker` (docker CLI config). `~/.kube` is NOT created by us — the fleet scripts use `/etc/rancher/k3s/k3s.yaml`.
