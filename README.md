# sudo-fleet

A fleet of AI agents on one Linux box — planners that think, engineers that
build, and a mesh that lets them talk.

    ①  setup.sh     →    ②  k8s-up.sh     →    ③  talk.sh
    bootstrap            deploy agents         start working


## Quick start

Three commands. That is the whole install.

**①  Clone and bootstrap**

    git clone https://github.com/salmonhealer772/sudo-fleet.git && cd sudo-fleet && bash setup.sh

Installs Docker and k3s, builds the agent images, writes your config. Asks for
one LLM API key and an optional web-search key. Takes a few minutes.

**②  Put the fleet up**

    cd bin && bash k8s-up.sh

Deploys a Letta planner and a Hermes engineer, with their storage and network
wired. Override the names if you like:

    PLANNER_NAME=boss ENGINEER_NAME=worker bash k8s-up.sh

**③  Talk to your agent**

    sudo bash bin/talk.sh --planner

Opens a live Letta Code session in your terminal. Run it from the repo root.
Any agent name works: `--engineer`, or whatever you deployed.

That is it. You are in front of a working agent with persistent memory, tools,
and a teammate it can delegate to.


## What you just built

    ┌─────────────────────────────────────────────────────────────┐
    │  your Linux machine                                         │
    │                                                             │
    │  ┌────────────────────── k3s ────────────────────────────┐  │
    │  │                                                       │  │
    │  │   sudo-planner              sudo-engineer             │  │
    │  │   ┌──────────────┐          ┌──────────────┐          │  │
    │  │   │   Letta      │──── task ───▶│          │          │  │
    │  │   │  stateful    │◀── result ───┘          │          │  │
    │  │   │  remembers   │          │  does the    │          │  │
    │  │   │  everything  │          │  work        │          │  │
    │  │   └──────┬───────┘          └──────┬───────┘          │  │
    │  │          │                          │                 │  │
    │  │          └────────┬─────────────────┘                 │  │
    │  │                   ▼                                   │  │
    │  │        ┌─────────────────────┐                        │  │
    │  │        │  prompt queue       │  one prompt at a time  │  │
    │  │        │  comm layer         │  list · message · check│  │
    │  │        └─────────────────────┘                        │  │
    │  │                                                       │  │
    │  └───────────────────────────────────────────────────────┘  │
    │                                                             │
    │      memory lives here, on disk — it survives restarts      │
    └─────────────────────────────────────────────────────────────┘
                                  ▲
                                  │
                               you, talking


### The two kinds of agent

    PLANNER  (Letta)                    ENGINEER  (Hermes)
    ─────────────────────────           ─────────────────────────
    memory:   permanent, git-backed     memory:   fresh each task
    best at:  deciding, delegating      best at:  executing one job
    needs:    a conversation            needs:    a task
    you talk to it: yes                 you talk to it: usually not

Planners delegate to engineers. Engineers do the work and report back. Either
can message any other agent in the fleet.


## How the repo is laid out

    sudo-fleet/
    │
    ├── setup.sh ··············· ①  bootstrap the box
    │
    ├── bin/
    │   ├── k8s-up.sh ········· ②  deploy the fleet
    │   ├── talk.sh ··········· ③  talk to an agent
    │   ├── k8s-down.sh ······· stop · purge · teardown
    │   ├── k8s-auto-up.sh ···· re-apply after a reboot
    │   └── verify-change.sh ·· read-only health check
    │
    ├── factories/
    │   ├── sudo-agent/ ······· the engineer factory
    │   │   └── comm/ ········· the three tools every agent gets
    │   ├── sudo-letta/ ······· the planner factory
    │   │   └── mods/ ········· optional extras: dictation, google,
    │   │                        regulations, statutes
    │   └── mac/ ·············· optional Mac helpers — not needed on a server
    │
    ├── docs/ ················· see the index below
    │
    └── deployments/ ·········· saved agent identities; empty by default

Every folder, one line each:

    setup.sh                    installs Docker + k3s, builds images, writes config
    bin/k8s-up.sh               deploys the planner and engineer
    bin/talk.sh                 opens a session with any agent
    bin/k8s-down.sh             stops agents; can purge volumes or remove k3s
    bin/k8s-auto-up.sh          re-applies everything after a reboot
    bin/verify-change.sh        checks runtime, config, auth, exposure
    factories/sudo-agent/       engineer factory: image, deploy, MCP door, queue
    factories/sudo-letta/       planner factory: image, deploy, mods, skills
    factories/sudo-agent/comm/  the comm layer shared by both kinds
    factories/mac/              optional Mac helpers (keyboard, RGB, HID)
    docs/                       the documentation set
    deployments/                saved agent identities, empty by default


## Documentation

Start with the first two. The rest is reference.

    ARCHITECTURE.md          how the pieces fit: factories, ports, queue, comm
    OPERATIONS.md            deploy, inspect, debug, recover — with a table
    REPOSITORY-VS-INSTANCE.md   what belongs in this repo and what never does
    COMM-LAYER.md            how agents find and message each other
    COMPONENTS.md            every directory, and what it is for
    KNOWN-ISSUES.md          open defects, with evidence
    SPEC.md                  the original design contract

All of it lives in `docs/`.


## Security

Agent containers run privileged with the Docker socket mounted, because the comm
layer reaches the cluster through it. That is a path from the agent container to
the host kernel — treat a host running this as a host the agents can reach, not
as a sandbox.

Some values reach a Deployment as literal environment variables rather than
Secret references. `docs/ARCHITECTURE.md` says which. This repository is public:
never commit a key, a password, a token, or a real agent's identity.


    ─────────────────────────────────────────────────────────────────

    Working on this repository?

      Read           docs/ARCHITECTURE.md
      Pod spec       needs k8s-up.sh again — a rollout restart will not
                     pick up env or volume changes
      Before done    docs/CHANGE-PROTOCOL.md
