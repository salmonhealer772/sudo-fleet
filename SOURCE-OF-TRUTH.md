# Source of truth — which repository owns what

This file answers one question: when you want to change something about a fleet
built from this repo, which repository does the change belong in?

It is **not** the same question as "which agent is running where". For that
distinction — the repository versus any single instance of it — read
[`docs/REPOSITORY-VS-INSTANCE.md`](docs/REPOSITORY-VS-INSTANCE.md) first.

## The split

**sudo-fleet (this repo) owns how agents are deployed and configured:**

- `factories/sudo-agent/` — the Hermes engineer factory: `up.sh`, the config
  template, `mcp_servers_enable.py`, `Dockerfile`, `bin/`, `comm/`.
- `factories/sudo-letta/` — the Letta planner factory: `up.sh`, `mods/`,
  `skills/`, the watch sidecar wiring.
- `setup.sh`, `down.sh`, everything under `bin/`.
- The comm contract, the queue contract, and the port scheme.

**A separate product repository owns the workload content** — domain skills,
personas, the work itself, and the pipeline that drives it. That content is
mounted read-only into running agents from a path on the host, so an edit plus a
push there reaches every affected agent with no copy and no image rebuild.

The name and location of that second repository belong to whoever is running
the fleet. It is configured per instance, not fixed here.

## Do not

- Do not edit workload content (domain skills, personas, the work itself) inside
  this repo.
- Do not vendor a copy of sudo-fleet inside the workload repository.
- Do not record a path from one particular machine as though it were part of the
  contract. It is a default in one instance.

## A tension this repo currently carries

`deployments/` contains committed agent identity packages — memory, personas,
and settings — for two agents. That is workload content living in the factory
repository.

It is visible in one place and contradicts the split above in another. It has
not been removed: those packages are the only record of identities that were
built here, and deleting them is a decision for the maintainer, not a
documentation cleanup.

Any new identity package committed under `deployments/` should be treated the
same way: justified explicitly, scrubbed of secrets and personal data, and
understood as an exception to the split rather than an example of it.
