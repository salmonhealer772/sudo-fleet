"""Minimal test: ops_gate + ops_tools registry are importable and functional."""

import sys
import os

_TOOLS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools")
if _TOOLS_DIR not in sys.path:
    sys.path.append(_TOOLS_DIR)

import ops_gate
import ops_tools


def test_ops_gate_blocked_exits_69_when_skill_not_loaded():
    """ops_gate.gate() raises SystemExit(69) when the skill isn't loaded."""
    # Outside a session (no HERMES_SESSION_ID) -> always allowed.
    os.environ.pop("HERMES_SESSION_ID", None)
    try:
        ops_gate.gate("paperclip-api")
    except SystemExit as exc:
        assert False, f"Should not block outside a session, got exit {exc.code}"


def test_ops_tools_registry_is_dict():
    """discover_tools() returns a dict; may be empty if sibling tools
    haven't landed yet, but must never raise."""
    reg = ops_tools.discover_tools()
    assert isinstance(reg, dict)


def test_ops_tools_registry_keys_are_subset_of_known_names():
    """Every registered key is a known ops tool name."""
    known = set(ops_tools.OPS_TOOL_NAMES)
    reg = ops_tools.registry
    assert set(reg.keys()).issubset(known)