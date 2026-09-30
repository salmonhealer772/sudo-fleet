"""comm-gate — the deterministic "load the comm skill first" gate, CLI half.

Industry pattern (Claude Agent SDK PreToolUse "block until prerequisite passed
this session"): a stateful prerequisite gate. The tool refuses to run until a
per-session prerequisite — the matching comm skill was LOADED this session — is
recorded. The recorder is the ``sudo-comm-gate`` Hermes plugin (shipped beside
these tools); this module is the enforcement half the three comm CLIs call at
the very top of their ``main()``.

Session discovery
-----------------
When a comm CLI is invoked through a Hermes engineer's terminal tool, the
subprocess inherits ``HERMES_SESSION_ID`` from the agent's environment (Hermes
sets it and keeps it in sync with the ``session_id`` its plugin hooks receive,
so it equals the id the plugin recorded the skill load under). When that
variable is ABSENT the CLI is being run by a human or a script OUTSIDE any
Hermes session, and the gate MUST NOT block — a scripted
``python3 /opt/comm-tools/list_siblings.py`` keeps working.

The plugin records skill loads keyed by session in
``<HERMES_HOME>/comm-gate/state.json``::

    {"<session_id>": {"<skill-name>": <epoch>, ...}, ...}

Policy
------
* ``HERMES_SESSION_ID`` unset  -> allow (no session context: human / script).
* ``HERMES_SESSION_ID`` set    -> require the skill in ``state[session_id]``;
                                  otherwise print ``BLOCKED: load the <skill>
                                  skill first, then retry.`` to stderr and exit
                                  ``69`` (sysexits EX_UNAVAILABLE) — WITHOUT
                                  building any transport or touching the host
                                  or the network.

Fail-closed inside a Hermes session, fail-open outside it.
"""

from __future__ import annotations

import json
import os
import sys

#: exit code for "blocked by the comm gate" — 69 is sysexits EX_UNAVAILABLE, a
#: distinctive non-zero that is trivial to grep for in transcripts.
EX_BLOCKED = 69

#: the three comm skills, by the name the plugin records (== the SKILL.md name
#: and the name taught in each SKILL.md "How to call it" section).
COMM_SKILLS = ("list-siblings", "message-agent", "check-agent")

DEFAULT_HOME = "/opt/data"


def _home() -> str:
    return os.environ.get("HERMES_HOME") or DEFAULT_HOME


def state_path() -> str:
    """Absolute path of the per-session skill-load ledger."""
    return os.path.join(_home(), "comm-gate", "state.json")


def load_state() -> dict:
    """The skill-load ledger, or {} when absent/unreadable/corrupt.

    Tolerant by design: a missing or half-written file (crash mid-replace is
    impossible thanks to atomic replace, but a bad file is still possible) must
    never raise into the caller — it is read as "nothing loaded yet", which is
    the fail-closed side of the gate.
    """
    try:
        with open(state_path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def blocked(skill_name: str, session_id: str) -> bool:
    """True when ``skill_name`` has NOT been loaded in ``session_id``."""
    state = load_state()
    loaded = state.get(session_id)
    if not isinstance(loaded, dict):
        return True
    return skill_name not in loaded


def gate(skill_name: str) -> None:
    """Enforce the load-first gate; raises SystemExit(69) when blocked.

    Called at the very top of each comm CLI's ``main()``, before any transport
    is built or any host/network work is done, so a blocked call "does nothing"
    (no bridge container, no kubectl, no MCP handshake).
    """
    session_id = os.environ.get("HERMES_SESSION_ID") or ""
    if not session_id:
        return  # no Hermes session context -> human/script -> allow
    if skill_name not in COMM_SKILLS:
        return  # defensive: never false-block an unknown skill name
    if blocked(skill_name, session_id):
        print(f"BLOCKED: load the {skill_name} skill first, then retry.",
              file=sys.stderr)
        raise SystemExit(EX_BLOCKED)
