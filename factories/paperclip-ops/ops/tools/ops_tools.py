"""ops-tools — the callable interfaces for the paperclip-ops layer.

These are the thin wrappers that discover and register every ops tool
in this tree. Discovery is tolerant: import what's present, skip what's
missing, never crash. Each registered tool exposes a (name, callable)
pair the ops_gate can enforce before dispatch.

Sibling tools (being built in parallel):
  - paperclip_api
  - goal_decompose
  - assign_picker
  - attention_detector
  - issue_triage
  - task_planning
  - summarize_status
  - status_card_query
"""

from __future__ import annotations

import importlib
import os
import sys

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS_DIR)

#: All known ops tool module names (without .py).
OPS_TOOL_NAMES = (
    "paperclip_api",
    "goal_decompose",
    "assign_picker",
    "attention_detector",
    "issue_triage",
    "task_planning",
    "summarize_status",
    "status_card_query",
)

#: Registry: {name: callable} — populated by discover_tools().
registry: dict[str, object] = {}


def discover_tools() -> dict[str, object]:
    """Import every present ops tool module and register it.

    Missing modules are silently skipped (tolerant discovery for
    parallel builds). Returns the registry dict.
    """
    global registry
    registry = {}
    for name in OPS_TOOL_NAMES:
        try:
            mod = importlib.import_module(name)
        except ImportError:
            continue
        # Each tool module must expose a run() callable.
        if hasattr(mod, "run"):
            registry[name] = mod.run
    return registry


# Auto-discover on import so the registry is ready for the gate.
discover_tools()