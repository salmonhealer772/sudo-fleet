# sudo-letta comm skills

The three comm-tool skills an agent is born with, one directory per skill (each
is a single `SKILL.md`, matching the MemFS layout Letta auto-loads from
`memfs/<agent-id>/memory/skills/<name>/SKILL.md`):

- `list-siblings/`  → the "who exists and how do I reach them" procedure
- `message-agent/`  → the reach-and-message-any-sibling recipe (the mesh's core)
- `check-agent/`    → the "read a sibling's trail at any depth" recipe

These are the SKILL half of the comm layer; the TOOL half is the matching mod
packages in this repo's `mods/` dir (installed at deploy time by
`bin/up.sh` — see the `COMM_MODS` block). Tool + skill + persona align
so the agent actually reaches for them; a tool without its skill is a bare
callable nobody uses.

`bin/up.sh` copies this `skills/` dir into the pod and drops it into
the agent's MemFS `memory/skills/` on every deploy (see the "comm-layer skills"
block there), so every planner is born able to list/message/check its siblings.

CANONICAL SOURCE: this repo on `main`, at `factories/sudo-letta/skills/`.
These are first-class files, not a vendored snapshot — edit them here; the
factory deploy ships them directly.
