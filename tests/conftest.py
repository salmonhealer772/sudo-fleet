"""Shared fixtures for the comm-layer tool tests.

Provides a single `env` fixture -- a fully-wired fake fleet with a default
roster of three siblings (two Letta planners, one Hermes engineer). Tests that
need a different roster build their own via fakes.make_env(...).
"""

import pytest

from fakes import make_env

DEFAULT_SPECS = [
    ("fa-glm-l", "letta"),
    ("ms-glm-l", "letta"),
    ("fa-glm-h", "hermes"),
]


@pytest.fixture
def env():
    """A wired fake fleet: fleet, transport, host, mcp{}, watch{}."""
    return make_env(list(DEFAULT_SPECS))
