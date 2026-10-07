"""ops-gate — the deterministic "load the ops skill first" gate, CLI half.

Mirrors comm_gate.py (see comm/tools/comm_gate.py for the full
specification). The gate is the enforcement half the ops CLIs call at
the very top of their main().

Session discovery
-----------------
When an ops CLI is invoked through a Hermes engineer's terminal tool,
the subprocess inherits HERMES_SESSION_ID from the agent's environment.
When that variable is ABSENT the CLI is being run by a human or a
script OUTSIDE any Hermes session, and the gate MUST NOT block.

The plugin records skill loads keyed by session in
<HERMES_HOME>/ops-gate/state.json.

Policy
------
* HERMES_SESSION_ID unset  -> allow (no session context: human / script).
* HERMES_SESSION_ID set    -> require the skill in state[session_id];
                                  otherwise print "BLOCKED: load the <skill>
                                  skill first, then retry." to stderr and
                                  exit 69 (sysexits EX_UNAVAILABLE) —
                                  WITHOUT building any transport or
                                  touching the host or the network.

Fail-closed inside a Hermes session, fail-open outside it.
"""

from __future__ import annotations

import json
import os
import sys

EX_BLOCKED = 69

OPS_SKILLS = (
    "paperclip-api",
    "goal-decompose",
    "assign-picker",
    "attention-detector",
    "issue-triage",
    "task-planning",
    "summarize-status",
    "status-card-query",
)

DEFAULT_HOME = "/opt/data"


def _home() -> str:
    return os.environ.get("HERMES_HOME") or DEFAULT_HOME


def state_path() -> str:
    """Absolute path of the per-session skill-load ledger."""
    return os.path.join(_home(), "ops-gate", "state.json")


def load_state() -> dict:
    """The skill-load ledger, or {} when absent/unreadable/corrupt."""
    try:
        with open(state_path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def blocked(skill_name: str, session_id: str) -> bool:
    """True when skill_name has NOT been loaded in session_id."""
    state = load_state()
    loaded = state.get(session_id)
    if not isinstance(loaded, dict):
        return True
    return skill_name not in loaded


def gate(skill_name: str) -> None:
    """Enforce the load-first gate; raises SystemExit(69) when blocked."""
    session_id = os.environ.get("HERMES_SESSION_ID") or ""
    if not session_id:
        return
    if skill_name not in OPS_SKILLS:
        return
    if blocked(skill_name, session_id):
        print(f"BLOCKED: load the {skill_name} skill first, then retry.",
              file=sys.stderr)
        raise SystemExit(EX_BLOCKED)