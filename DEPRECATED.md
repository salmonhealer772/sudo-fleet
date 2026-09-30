# DEPRECATED — this branch is no longer canonical

The `comm-skills-tools` branch is **deprecated**. It was the former canonical
source for the sudo-fleet communication layer (the `list-siblings` /
`message-agent` / `check-agent` tools, their skills, their mod packages, and
their docs/tests), but that role has moved to **`main`**.

The single source of truth for the comm layer now lives on `main`, under the
factories it ships from:

- **Letta planner side (mods + skills)** — `factories/sudo-letta/mods/` and
  `factories/sudo-letta/skills/`
- **Hermes engineer side (tools + skills + persona)** —
  `factories/sudo-agent/comm/`

Do **not** add new comm-layer work here, and do **not** treat anything in this
branch as authoritative. If a fix lands here, port it to `main`'s `factories/`
tree — the factories are canonical, not this branch.

This branch is kept for history only and will not be deleted.
