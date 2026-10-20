# Source of truth — sudo-fleet is the FACTORY, live-v2 is the PRODUCT

sudo-fleet (this repo) is the single source of truth for **how** agents are
deployed and configured: `factories/sudo-agent/` (`up.sh`, `config.yaml`
template, `mcp_servers_enable.py`, `Dockerfile`, `bin/`, `comm/`),
`factories/sudo-letta/`, `setup.sh`, `down.sh`.

The product content — domain skills, personas, the talker, workload specs, and
the pipeline — lives in **live-v2** (github.com/docket-atlas/live-v2), NOT here.
`up.sh` mounts the domain skills read-only into the running agents from
`/opt/live-v2/agents/skills`, so a skill edit + push in live-v2 reaches every
meta-data-agent with no copy and no image rebuild.

## Do not

- Do not edit product content (skills/personas/talker) in this repo.
- Do not vendor a copy of sudo-fleet inside live-v2.

See `live-v2/SOURCE-OF-TRUTH.md` for the full table.
