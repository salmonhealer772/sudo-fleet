# skills/

The "how to use the tools" layer lives here — one skill per tool, written as procedural guidance for an agent (when + why to reach for each tool, the exact invocation, the gotchas).

These are **not** code and **not** the mechanism. The mechanism lives in `tools/`, its contract in `docs/<name>-CONTRACT.md`, its behavior in `features/<name>.feature`, its tests in `tests/test_<name>.py`. The **skill** here is the thing that makes an agent actually *use* the tool instead of ignoring it.

Three skills, matching the three tools:

- `list-siblings` — when to list the roster before messaging/checking
- `message-agent` — how to reach and message a sibling (the primary one)
- `check-agent` — when to read a sibling's trail: what it's doing right now (small `n`) and what it's done

Empty now — the landing zone for forge's skill layer. Drop each skill in here once its tool is built.
