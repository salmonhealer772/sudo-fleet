"""sudo-comm-gate — the "load the comm skill first" gate, plugin half.

WHY THIS EXISTS
---------------
The three comm tools (list-siblings, message-agent, check-agent) are plain
Python CLIs the engineer runs through its terminal tool. The skills teach the
exact syntax, but nothing stops a model from running the CLI without ever
loading the skill. This plugin closes that gap with a deterministic,
per-session prerequisite gate — the industry pattern of "block transfer_funds
until aml_check passed this session", here "block `message_agent.py` until the
`message-agent` skill was loaded this session".

Two hooks:

* ``on_skill_lifecycle`` — Hermes fires this when the agent loads a skill via
  ``skill_view`` (action="loaded", with ``skill_name`` + ``session_id``). The
  plugin records ``{session_id -> {skill_name: epoch}}`` in
  ``<HERMES_HOME>/comm-gate/state.json``.

* ``pre_tool_call`` — when a terminal command references one of the three comm
  CLIs and that CLI's matching skill was NOT loaded this session, return
  ``{"action": "block", "message": "BLOCKED: load the <skill> skill first,
  then retry."}``. Hermes vetoes the call and surfaces the message to the
  model, so it can load the skill and retry in the same turn.

The CLI half (``comm/tools/comm_gate.py``) enforces the same rule independently:
each CLI reads ``HERMES_SESSION_ID`` + the same state file and exits 69 with
the BLOCKED message when the skill is missing — so the gate holds even when the
plugin is somehow not in the path, and holds not at all when there is no Hermes
session (a human/script running the CLI directly keeps working).

HARD RULES (a plugin must never hurt the agent it observes)
-----------------------------------------------------------
* Every callback is wrapped in try/except and never raises.
* State writes are atomic (tmp + os.replace) and never block the agent.
* stdlib only; additive — the only file written is ``comm-gate/state.json``.
"""

from __future__ import annotations

import json
import os
import time

PLUGIN_NAME = "sudo-comm-gate"
DEFAULT_HOME = "/opt/data"

#: the three comm skills, and the CLI filename markers that identify each.
COMM_SKILLS = {
    "list-siblings": ("list_siblings.py",),
    "message-agent": ("message_agent.py",),
    "check-agent": ("check_agent.py",),
}

#: bound the ledger so a long-lived agent cannot grow it without limit.
MAX_SESSIONS = 500


def _home() -> str:
    return os.environ.get("HERMES_HOME") or DEFAULT_HOME


def gate_dir() -> str:
    return os.path.join(_home(), "comm-gate")


def state_path() -> str:
    return os.path.join(gate_dir(), "state.json")


def load_state() -> dict:
    try:
        with open(state_path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _write_state(state: dict) -> None:
    """Atomic best-effort persist. Never raises."""
    try:
        d = gate_dir()
        os.makedirs(d, exist_ok=True)
        tmp = os.path.join(d, "state.json.tmp.%d" % os.getpid())
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False)
        os.replace(tmp, state_path())
    except Exception:
        pass


def _prune(state: dict, current: str) -> dict:
    """Drop the oldest sessions past MAX_SESSIONS, always keeping `current`."""
    if len(state) <= MAX_SESSIONS:
        return state
    keys = [k for k in state if k != current]
    keep = keys[-(MAX_SESSIONS - 1):]
    return {k: state[k] for k in keep}


def _record_skill_load(session_id: str, skill_name: str) -> None:
    if not session_id or skill_name not in COMM_SKILLS:
        return
    state = load_state()
    entry = state.get(session_id)
    if not isinstance(entry, dict):
        entry = {}
    entry[skill_name] = time.time()
    state[session_id] = entry
    _write_state(_prune(state, session_id))


def _skill_loaded(session_id: str, skill_name: str) -> bool:
    state = load_state()
    entry = state.get(session_id)
    if not isinstance(entry, dict):
        return False
    return skill_name in entry


def _comm_skill_in_command(command) -> str | None:
    """Return the comm skill whose CLI the command invokes, else None."""
    if not isinstance(command, str) or not command:
        return None
    for skill, markers in COMM_SKILLS.items():
        for marker in markers:
            if marker in command:
                return skill
    return None


def _on_skill_lifecycle(**kw) -> None:
    """Record "skill X was loaded this session" (action == "loaded")."""
    try:
        if kw.get("action") != "loaded":
            return
        _record_skill_load(kw.get("session_id") or "", kw.get("skill_name") or "")
    except Exception:
        pass
    return None


def _on_pre_tool_call(**kw):
    """Block a comm-CLI terminal command until its skill was loaded."""
    try:
        args = kw.get("args")
        if not isinstance(args, dict):
            return None
        skill = _comm_skill_in_command(args.get("command"))
        if skill is None:
            return None
        session_id = kw.get("session_id") or ""
        if not session_id:
            return None  # no session context: let the CLI's own gate decide
        if _skill_loaded(session_id, skill):
            return None
        return {
            "action": "block",
            "message": f"BLOCKED: load the {skill} skill first, then retry.",
        }
    except Exception:
        return None


def register(ctx) -> None:
    """Hermes plugin entry point: register the two gate hooks."""
    try:
        ctx.register_hook("on_skill_lifecycle", _on_skill_lifecycle)
        ctx.register_hook("pre_tool_call", _on_pre_tool_call)
    except Exception:
        pass
