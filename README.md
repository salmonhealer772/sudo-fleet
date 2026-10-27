# sudo-fleet

A factory that installs an agent fleet on one Linux machine. Clone it, run one
bootstrap script, deploy agents with one command each, and they can reach each
other, watch each other, and survive a reboot.

This repository is **the product**. It is not one particular running fleet.
Read [`docs/REPOSITORY-VS-INSTANCE.md`](docs/REPOSITORY-VS-INSTANCE.md) before
changing anything here: the distinction between the repository and any single
instance of it governs every decision in this repo.

- **Repository** — the factory scripts, the two agent factories, the comm
  contract, the queue contract, the port scheme, and the docs. Generic. Something
  other people clone and other software embeds.
- **Instance** — one deployment of that factory: whatever cluster, hostnames,
  agent names and keys a user happens to have. Not part of this repo.

Instance details appearing in this repository are labelled examples. They are
never requirements.

## What you get

| Piece | What it is |
|---|---|
| `setup.sh` | Bootstrap: asks for one LLM key, writes `.env`, installs docker and k3s, builds both factory images, installs a boot-time recovery unit. |
| `bin/k8s-up.sh` | Deploys the cluster workload from the factory YAMLs. |
| `bin/k8s-down.sh` | Stops, purges, or tears down. |
| `factories/sudo-agent/` | The Hermes engineer factory. Stateless one-shot CLI agents. |
| `factories/sudo-letta/` | The Letta planner factory. Stateful agents with git-backed memory. |
| `factories/*/comm/`, `factories/sudo-letta/mods/` | The cross-agent comm layer: `list-siblings`, `message-agent`, `check-agent`. |
| `factories/sudo-letta/mods/` | Optional planner mods, including dictation (`/listen`, `/done`) and Google Workspace. |

Each factory's `bin/up.sh` deploys one agent, prepends `sudo-` to the name you
give it, writes a YAML to `factories/<factory>/deployments/`, and seeds identity
and skills.

## Requirements

A Linux box with systemd, `curl` or `wget`, `git`, and root or sudo. Docker and
k3s are installed by `setup.sh`. An SSH-less, single-node cluster is the
supported shape; the factory assumes k3s on the same host as the docker socket.

## Quick start

```bash
git clone https://github.com/salmonhealer772/sudo-fleet.git && cd sudo-fleet
bash setup.sh
```

Then deploy agents with the factory that fits the role:

```bash
bash factories/sudo-letta/bin/up.sh --planner      # a Letta planner: sudo-planner
bash factories/sudo-agent/bin/up.sh --worker       # a Hermes engineer: sudo-worker
```

Names above are placeholders. Pick your own; nothing in the repo reserves them.

## Command 2 — what it deploys

`bin/k8s-up.sh` stands up a working starter pair: a Letta planner and a Hermes
engineer, with their PVCs and Services.

```
PLANNER_NAME=planner      (default) -> deployment sudo-planner
ENGINEER_NAME=engineer    (default) -> deployment sudo-engineer
```

Override either name per install:

```bash
PLANNER_NAME=boss ENGINEER_NAME=worker bash bin/k8s-up.sh
```

**Identity is optional and never invented.** If a saved identity package exists
at `deployments/<Name>/`, it is passed to the factory as `--from-glimor` and the
agent resumes that identity. If it does not exist, the factory deploys a clean
agent and you grow its identity from there. This repository ships no identity
packages, so a fresh clone gets two working agents with empty memory — not a
blank or a crash.

To start from a saved identity, put it at `deployments/<Name>/` (or point
`GLIMORS_DIR` at a directory of your own). A glimor you do point at that is
missing or corrupt still fails loudly rather than silently yielding a blank
agent.

## Documentation

| Document | Read it for |
|---|---|
| [`docs/REPOSITORY-VS-INSTANCE.md`](docs/REPOSITORY-VS-INSTANCE.md) | The distinction this repo is built around. Start here. |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | The system as built: factories, per-agent shape, ports, queue, comm layer, lifecycle. |
| [`docs/OPERATIONS.md`](docs/OPERATIONS.md) | Deploy, inspect, debug, and recover a fleet. |
| [`docs/COMM-LAYER.md`](docs/COMM-LAYER.md) | The cross-agent communication contract in full. |
| [`docs/DOC-FACTS.md`](docs/DOC-FACTS.md) | Every checkable claim in the docs, and where it was checked. |
| [`docs/COMPONENTS.md`](docs/COMPONENTS.md) | Every directory in this repo: what it is, whether it is fleet infrastructure or optional tooling. |
| [`docs/SPEC.md`](docs/SPEC.md) | The original design contract, including what remains unbuilt. |
| [`docs/NEXT.md`](docs/NEXT.md) | The agreed next direction: multiple fleets in one cluster. |
| [`docs/KNOWN-ISSUES.md`](docs/KNOWN-ISSUES.md) | Open defects and their evidence. |
| [`docs/CHANGE-PROTOCOL.md`](docs/CHANGE-PROTOCOL.md) | The four checks to run after a complex change. |
| [`SOURCE-OF-TRUTH.md`](SOURCE-OF-TRUTH.md) | Which repository owns which content. |

## Security posture, stated plainly

The agent container runs privileged, with the docker socket mounted, because the
comm layer reaches the host through it. That is an escape path from the agent
container to the host kernel. Treat any host that runs this as a host the agents
can reach, not as a sandbox boundary you can rely on.

Some values reach a Deployment as literal env values rather than
`secretKeyRef`. `docs/ARCHITECTURE.md` states which. This repository is public:
never commit a key, a password, a token, or a real agent's private identity.

## Development notes

- Changing anything the pod spec carries requires a pod recreation through
  `up.sh`. `kubectl rollout restart` does not pick up env or volume changes.
- Changing `bin/mcp_server.py`, `mcp_entrypoint.sh`, `hermes_prompt.py`,
  `Dockerfile` or `patch_memory_review.py` requires an image rebuild. `up.sh`
  refuses to deploy a stale image unless `SUDO_AGENT_ALLOW_STALE_IMAGE=1` is set.
- Do not write "verified" in a commit message before the verification output
  exists. If a test runs after the commit, say so in a follow-up commit.
- Keep the architecture. Improve the documentation of it instead.
