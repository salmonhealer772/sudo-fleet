"""Tests for the check-what-agent-is-doing tool
(comm/tools/features/check-what-agent-is-doing.feature)."""

import pytest

from comm_tools import SiblingNotFound, check_what_agent_is_doing


def test_status_returns_full_snapshot(env):
    # Arrange
    env.watch["fa-glm-l"].status = {
        "agent": "fa-glm-l", "deploy": "sudo-fa-glm-l", "uptime_s": 3600,
        "agent_container_up": True, "active": False,
        "current_conversation": "local-conv-123", "last_event_ts": 1720000000.0,
        "events_logged": 42, "transcript_bytes": 9000, "watch_port": 8000,
    }
    # Act
    snap = check_what_agent_is_doing("fa-glm-l", fleet=env.fleet)
    # Assert
    assert env.watch["fa-glm-l"].requests[-1] == "/status"
    assert set(snap) == {
        "agent", "deploy", "uptime_s", "agent_container_up", "active",
        "current_conversation", "last_event_ts", "events_logged",
        "transcript_bytes", "watch_port",
    }


def test_alive_when_container_up(env):
    # Arrange
    env.watch["fa-glm-l"].status["agent_container_up"] = True
    # Act
    snap = check_what_agent_is_doing("fa-glm-l", fleet=env.fleet)
    # Assert
    assert snap["agent_container_up"] is True


def test_idle_when_no_letta_process(env):
    # Arrange
    env.watch["fa-glm-l"].status["active"] = False
    # Act
    snap = check_what_agent_is_doing("fa-glm-l", fleet=env.fleet)
    # Assert
    assert snap["active"] is False


def test_active_when_letta_process_runs(env):
    # Arrange
    env.watch["fa-glm-l"].status["active"] = True
    # Act
    snap = check_what_agent_is_doing("fa-glm-l", fleet=env.fleet)
    # Assert
    assert snap["active"] is True


def test_reports_current_conversation(env):
    # Arrange
    env.watch["fa-glm-l"].status["current_conversation"] = "local-conv-123"
    # Act
    snap = check_what_agent_is_doing("fa-glm-l", fleet=env.fleet)
    # Assert
    assert snap["current_conversation"] == "local-conv-123"


def test_reports_last_event_age(env):
    # Arrange
    env.watch["fa-glm-l"].status.update(
        last_event_ts=1720000000.0, events_logged=7, uptime_s=120)
    # Act
    snap = check_what_agent_is_doing("fa-glm-l", fleet=env.fleet)
    # Assert
    assert snap["last_event_ts"] == 1720000000.0
    assert snap["events_logged"] > 0
    assert snap["uptime_s"] > 0


def test_processes_facet_lists_running_processes(env):
    # Arrange
    env.watch["fa-glm-l"].ps = [
        {"pid": 100, "ppid": 1, "uid": 1000, "age_s": 300, "cmdline": "letta run"},
        {"pid": 200, "ppid": 100, "uid": 1000, "age_s": 290, "cmdline": "python -m letta"},
    ]
    # Act
    procs = check_what_agent_is_doing("fa-glm-l", facet="processes", fleet=env.fleet)
    # Assert
    assert env.watch["fa-glm-l"].requests[-1] == "/ps"
    assert len(procs) == 2
    for p in procs:
        assert set(p) == {"pid", "ppid", "uid", "age_s", "cmdline"}


def test_unknown_sibling_reports_not_found(env):
    # Act / Assert
    with pytest.raises(SiblingNotFound):
        check_what_agent_is_doing("does-not-exist", fleet=env.fleet)
