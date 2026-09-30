"""Shared fixtures for the comm-layer tool tests.

Provides a single `env` fixture -- a fully-wired fake fleet with a default
roster of three siblings (two Letta planners, one Hermes engineer). Tests that
need a different roster build their own via fakes.make_env(...).

This file also puts the finished backends in `tools/` on the import path, so a
test can import them the way the backends import each other
(``real_transport``, ``check_agent``). It is APPENDED, not prepended. The
reference interface (``comm_tools``) lives in `tools/` alongside the backends,
so appending `tools/` makes both the backends and the reference importable.
"""

import os
import sys

import pytest

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_TOOLS_DIR = os.path.join(os.path.dirname(_TESTS_DIR), "tools")
if _TOOLS_DIR not in sys.path:
    sys.path.append(_TOOLS_DIR)

from fakes import make_env  # noqa: E402  (after the path is set up)

DEFAULT_SPECS = [
    ("fa-glm-l", "letta"),
    ("ms-glm-l", "letta"),
    ("fa-glm-h", "hermes"),
]


@pytest.fixture
def env():
    """A wired fake fleet: fleet, transport, host, mcp{}, watch{}."""
    return make_env(list(DEFAULT_SPECS))
