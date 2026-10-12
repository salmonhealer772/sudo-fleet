# comm/ — the fleet communication layer for Hermes engineers

This directory is the **Hermes-side** packaging of the native cross-agent
communication layer: three tools + three comm skills + a persona snippet, so
every Hermes engineer (`sudo-agent`) is born able to talk to, and check on, any
sibling agent.

The canonical source of truth for these is this repo on `main`, at
`factories/sudo-agent/comm/` (tools + skills + persona). This directory is what
the `sudo-agent` factory ships so the SAME three abilities are a **spawn-time
default for every Hermes engineer** — not a per-pod bolting.

Three folders, three layers that must align:

| Layer | Folder | What it is |
|---|---|---|
| **Tool** | `tools/` | the mechanism — the Python CLI backends (baked into the image at `/opt/comm-tools/`) |
| **Skill** | `skills/` | the procedure — when + how to call each tool (seeded into `$HERMES_HOME/skills/` on first boot) |
| **Persona** | `PERSONA-SNIPPET.md` | the awareness — applied to `SOUL.md` as a factory-managed block on every boot so the agent knows it has these |

## The three tools

1. `list-siblings` — see who exists and how to reach them (`kubectl get
   services` on the host via the docker-socket bridge; the live roster).
2. `message-agent` — BY FAR the most important. Message any sibling by name
   (`letta_prompt`/`hermes_prompt` via the sibling's `-mcp`).
3. `check-agent` — read a sibling's trail at any depth (`GET ...-watch/events?n=N`
   or the compressed `transcript.txt` read; `n=-1` = the whole file). Answers
   both "what has it been doing" and "what is it doing right now".

## The operations skill (shipped the same way)

- `skills/switch-agent-model/` — switch the model an agent runs on (Hermes
  engineer OR Letta planner), check a handle is available, and verify for real
  that the switch took effect. Not part of the comm layer, but it lives in
  `comm/skills/` because that is where the `sudo-agent` factory seeds
  `$HERMES_HOME/skills/` from on first boot.

## How it becomes a default (the wiring)

- **tools** → `Dockerfile` copies `comm/tools/` into the image at
  `/opt/comm-tools/` (not shadowed by the `/opt/data` PVC), so every engineer
  image has them.
- **skills** → `mcp_entrypoint.sh` seeds `comm/skills/` into `/opt/data/skills/`
  on FIRST boot only (idempotent `.comm-seeded` marker), because Hermes reads
  skills from `$HERMES_HOME/skills` (the PVC) and the agent may edit them later
  — a re-seed every boot would clobber its edits.
- **persona** → `mcp_entrypoint.sh` applies `PERSONA-SNIPPET.md` to
  `/opt/data/SOUL.md` as a **factory-managed block on EVERY boot** (not
  first-boot-only). The block lives between
  `<!-- FLEET-COMM-AWARENESS-BEGIN -->` / `<!-- FLEET-COMM-AWARENESS-END -->`
  markers; each boot replaces the content between them (or inserts the block if
  absent), so the agent can never permanently lose or stale its fleet
  awareness, and a rebuilt image ships a fresh snippet on the next restart.
  Nothing outside the markers is ever touched.

A fresh engineer is therefore born able to list, message, and check its
siblings — no post-deploy install, no one-off.
