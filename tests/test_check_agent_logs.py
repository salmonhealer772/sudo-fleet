"""Tests for the check-agent-logs tool
(comm/tools/features/check-agent-logs.feature)."""

import pytest

from comm_tools import (HERMES_TRANSCRIPT_PATH, SiblingNotFound,
                        TRANSCRIPT_PATH, check_agent_logs)
from fakes import event


def test_full_mode_returns_last_n_events(env):
    # Arrange
    env.watch["fa-glm-l"].events = [
        event(i, "c1", "assistant", text=f"e{i}") for i in range(1, 31)]
    # Act
    result = check_agent_logs("fa-glm-l", mode="full", n=10, fleet=env.fleet)
    # Assert
    assert env.watch["fa-glm-l"].requests[-1] == "/events?n=10"
    assert len(result) == 10
    for e in result:
        assert set(e) >= {"ts", "conversation", "event"}


def test_full_mode_omitted_n_uses_sidecar_default_100(env):
    # Arrange
    env.watch["fa-glm-l"].events = [
        event(i, "c1", "assistant", text=f"e{i}") for i in range(1, 150)]
    # Act
    result = check_agent_logs("fa-glm-l", mode="full", fleet=env.fleet)
    # Assert
    assert env.watch["fa-glm-l"].requests[-1] == "/events"
    assert len(result) == 100


def test_full_mode_large_n_reaches_deep_history(env):
    # Arrange
    env.watch["fa-glm-l"].events = [
        event(i, "c1", "assistant", text=f"e{i}") for i in range(1, 1200)]
    # Act
    result = check_agent_logs("fa-glm-l", mode="full", n=1000, fleet=env.fleet)
    # Assert
    assert env.watch["fa-glm-l"].requests[-1] == "/events?n=1000"
    assert len(result) == 1000


def test_compressed_mode_reads_transcript_tail(env):
    # Arrange
    env.host.set_file(
        TRANSCRIPT_PATH,
        "\n".join(f"[{i}] You: q{i}" for i in range(1, 51)))
    # Act
    result = check_agent_logs("fa-glm-l", mode="compressed", n=10, fleet=env.fleet)
    # Assert: issued `tail -n 10` and returned up to 10 lines
    argv = env.host.commands[-1]
    assert "tail" in argv and argv[argv.index("-n") + 1] == "10"
    assert len(result) == 10


def test_compressed_mode_depth_controllable(env):
    # Arrange
    env.host.set_file(
        TRANSCRIPT_PATH,
        "\n".join(f"[{i}] You: q{i}" for i in range(1, 501)))
    # Act
    result = check_agent_logs("fa-glm-l", mode="compressed", n=200, fleet=env.fleet)
    # Assert
    argv = env.host.commands[-1]
    assert argv[argv.index("-n") + 1] == "200"
    assert len(result) == 200


def test_compressed_mode_strips_internal_reasoning(env):
    # Arrange: full trail has thinking + tool calls; transcript has only chat
    env.watch["fa-glm-l"].events = [
        event(1.0, "c1", "user", text="hello"),
        event(2.0, "c1", "thinking", text="let me think about that"),
        event(3.0, "c1", "tool_call", name="web_search", args={"q": "x"}),
        event(4.0, "c1", "assistant", text="hi there"),
    ]
    env.host.set_file(TRANSCRIPT_PATH, "[1] You: hello\n[4] Agent: hi there\n")
    # Act
    lines = check_agent_logs("fa-glm-l", mode="compressed", n=100, fleet=env.fleet)
    # Assert: assistant reply present, internal reasoning absent
    joined = "\n".join(lines)
    assert "hi there" in joined
    assert "thinking" not in joined
    assert "tool_call" not in joined
    assert "let me think" not in joined


def test_n_minus_one_returns_entire_transcript(env):
    # Arrange
    env.host.set_file(
        TRANSCRIPT_PATH,
        "\n".join(f"[{i}] You: q{i}" for i in range(1, 301)))
    # Act
    result = check_agent_logs("fa-glm-l", mode="compressed", n=-1, fleet=env.fleet)
    # Assert: `cat` (no tail bound), entire file
    argv = env.host.commands[-1]
    assert "cat" in argv and "tail" not in argv
    assert len(result) == 300


def test_n_minus_one_returns_entire_event_trail(env):
    # Arrange
    env.watch["fa-glm-l"].events = [
        event(i, "c1", "assistant", text=f"e{i}") for i in range(1, 251)]
    # Act
    result = check_agent_logs("fa-glm-l", mode="full", n=-1, fleet=env.fleet)
    # Assert
    assert env.watch["fa-glm-l"].requests[-1] == "/events?n=-1"
    assert len(result) == 250


def test_n_minus_one_identical_on_hermes_sibling(env):
    # Arrange
    env.host.set_file(HERMES_TRANSCRIPT_PATH, "[1] You: hi\n[2] Agent: hey\n")
    # Act
    result = check_agent_logs("fa-glm-h", mode="compressed", n=-1, fleet=env.fleet)
    # Assert: the sentinel behaves the same for a Hermes engineer
    argv = env.host.commands[-1]
    assert "cat" in argv
    assert len(result) == 2


def test_live_tail_full_mode(env):
    # Arrange
    env.watch["fa-glm-l"].stream = [
        event(1.0, "c1", "assistant", text="a"),
        event(2.0, "c1", "assistant", text="b"),
    ]
    # Act
    result = check_agent_logs("fa-glm-l", mode="full", stream=True, fleet=env.fleet)
    # Assert
    assert env.watch["fa-glm-l"].requests[-1] == "/stream"
    assert result == env.watch["fa-glm-l"].stream


def test_event_schema_is_typed(env):
    # Arrange: one of each event kind
    env.watch["fa-glm-l"].events = [
        event(1.0, "c1", "user", text="hi", reminder=False),
        event(2.0, "c1", "thinking", text="hmm"),
        event(3.0, "c1", "assistant", text="hello"),
        event(4.0, "c1", "tool_call", name="web_search", args={"q": "x"}),
        event(5.0, "c1", "tool_result", text="res", truncated=False, full_bytes=3),
        event(6.0, "c1", "session", id="s1", cwd="/home/node"),
        event(7.0, "c1", "process_state", state="running", processes=[]),
    ]
    # Act
    result = check_agent_logs("fa-glm-l", mode="full", n=-1, fleet=env.fleet)
    # Assert
    by_kind = {e["event"]: e for e in result}
    assert set(by_kind["user"]) >= {"text", "reminder"}
    assert set(by_kind["thinking"]) >= {"text"}
    assert set(by_kind["assistant"]) >= {"text"}
    assert set(by_kind["tool_call"]) >= {"name", "args"}
    assert set(by_kind["tool_result"]) >= {"text", "truncated", "full_bytes"}
    assert set(by_kind["session"]) >= {"id", "cwd"}
    assert set(by_kind["process_state"]) >= {"state", "processes"}


def test_tool_results_truncated_to_4096_bytes(env):
    # Arrange: a tool result larger than 4096 bytes
    full = "x" * 5000
    env.watch["fa-glm-l"].events = [
        event(1.0, "c1", "tool_result", text=full[:4096],
              truncated=True, full_bytes=5000),
    ]
    # Act
    result = check_agent_logs("fa-glm-l", mode="full", n=-1, fleet=env.fleet)
    # Assert
    tr = result[0]
    assert tr["truncated"] is True
    assert len(tr["text"]) == 4096
    assert tr["full_bytes"] == 5000


def test_unknown_sibling_reports_not_found(env):
    # Act / Assert
    with pytest.raises(SiblingNotFound):
        check_agent_logs("does-not-exist", fleet=env.fleet)
