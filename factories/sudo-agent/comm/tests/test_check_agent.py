"""Tests for the merged check-agent tool (features/check-agent.feature).

check-agent replaces the former check-agent-logs AND check-what-agent-is-doing:
ONE tool, ONE depth knob `n` (the last n entries; n=-1 = the whole file), two
modes (full raw trail / compressed chat log), and NO separate /status or /ps
surface — the "what is it doing right now" answer falls out of the trail.
"""

import inspect

import pytest

import comm_tools
from comm_tools import (HERMES_TRANSCRIPT_PATH, SiblingNotFound,
                        TRANSCRIPT_PATH, check_agent)
from fakes import event


# --- full mode: the raw event trail ----------------------------------------

def test_full_mode_returns_last_n_events(env):
    # Arrange
    env.watch["fa-glm-l"].events = [
        event(i, "c1", "assistant", text=f"e{i}") for i in range(1, 31)]
    # Act
    result = check_agent("fa-glm-l", n=10, fleet=env.fleet)
    # Assert
    assert env.watch["fa-glm-l"].requests[-1] == "/events?n=10"
    assert len(result) == 10
    for e in result:
        assert set(e) >= {"ts", "conversation", "event"}


def test_full_mode_omitted_n_uses_default_100(env):
    # Arrange
    env.watch["fa-glm-l"].events = [
        event(i, "c1", "assistant", text=f"e{i}") for i in range(1, 150)]
    # Act: no mode -> full is the default
    result = check_agent("fa-glm-l", fleet=env.fleet)
    # Assert
    assert env.watch["fa-glm-l"].requests[-1] == "/events"
    assert len(result) == 100


def test_full_mode_large_n_reaches_deep_history(env):
    # Arrange
    env.watch["fa-glm-l"].events = [
        event(i, "c1", "assistant", text=f"e{i}") for i in range(1, 1200)]
    # Act
    result = check_agent("fa-glm-l", mode="full", n=1000, fleet=env.fleet)
    # Assert
    assert env.watch["fa-glm-l"].requests[-1] == "/events?n=1000"
    assert len(result) == 1000


def test_mode_defaults_to_full_not_the_file(env):
    # Arrange
    env.watch["fa-glm-l"].events = [event(1.0, "c1", "assistant", text="x")]
    # Act: no mode given
    check_agent("fa-glm-l", n=-1, fleet=env.fleet)
    # Assert: it used the HTTP trail, never a host/file read
    assert env.watch["fa-glm-l"].requests[-1] == "/events?n=-1"
    assert not any("tail" in argv or "cat" in argv for argv in env.host.commands)


# --- compressed mode: the plain chat log -----------------------------------

def test_compressed_mode_reads_transcript_tail(env):
    # Arrange
    env.host.set_file(
        TRANSCRIPT_PATH,
        "\n".join(f"[{i}] You: q{i}" for i in range(1, 51)))
    # Act
    result = check_agent("fa-glm-l", n=10, mode="compressed", fleet=env.fleet)
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
    result = check_agent("fa-glm-l", n=200, mode="compressed", fleet=env.fleet)
    # Assert
    argv = env.host.commands[-1]
    assert argv[argv.index("-n") + 1] == "200"
    assert len(result) == 200


def test_compressed_mode_omitted_n_uses_default_100(env):
    # Arrange: omitted n means the same default depth in BOTH modes
    env.host.set_file(
        TRANSCRIPT_PATH,
        "\n".join(f"[{i}] You: q{i}" for i in range(1, 501)))
    # Act
    result = check_agent("fa-glm-l", mode="compressed", fleet=env.fleet)
    # Assert
    argv = env.host.commands[-1]
    assert argv[argv.index("-n") + 1] == "100"
    assert len(result) == 100


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
    lines = check_agent("fa-glm-l", n=100, mode="compressed", fleet=env.fleet)
    # Assert: assistant reply present, internal reasoning absent
    joined = "\n".join(lines)
    assert "hi there" in joined
    assert "thinking" not in joined
    assert "tool_call" not in joined
    assert "let me think" not in joined


# --- n=-1: the whole file, both modes --------------------------------------

def test_n_minus_one_returns_entire_transcript(env):
    # Arrange
    env.host.set_file(
        TRANSCRIPT_PATH,
        "\n".join(f"[{i}] You: q{i}" for i in range(1, 301)))
    # Act
    result = check_agent("fa-glm-l", n=-1, mode="compressed", fleet=env.fleet)
    # Assert: `cat` (no tail bound), entire file
    argv = env.host.commands[-1]
    assert "cat" in argv and "tail" not in argv
    assert len(result) == 300


def test_n_minus_one_returns_entire_event_trail(env):
    # Arrange
    env.watch["fa-glm-l"].events = [
        event(i, "c1", "assistant", text=f"e{i}") for i in range(1, 251)]
    # Act
    result = check_agent("fa-glm-l", n=-1, mode="full", fleet=env.fleet)
    # Assert
    assert env.watch["fa-glm-l"].requests[-1] == "/events?n=-1"
    assert len(result) == 250


# --- works on both kinds (Letta planner + Hermes engineer) -----------------

def test_n_minus_one_identical_on_hermes_sibling(env):
    # Arrange
    env.host.set_file(HERMES_TRANSCRIPT_PATH, "[1] You: hi\n[2] Agent: hey\n")
    # Act
    result = check_agent("fa-glm-h", n=-1, mode="compressed", fleet=env.fleet)
    # Assert: the sentinel behaves the same for a Hermes engineer
    argv = env.host.commands[-1]
    assert "cat" in argv
    assert HERMES_TRANSCRIPT_PATH in argv
    assert len(result) == 2


def test_each_kind_reads_its_own_transcript_path(env):
    # Arrange: the two kinds keep their transcripts at different paths
    env.host.set_file(TRANSCRIPT_PATH, "[1] You: letta\n")
    env.host.set_file(HERMES_TRANSCRIPT_PATH, "[1] You: hermes\n")
    # Act + Assert: a Letta planner read hits the Letta path...
    letta = check_agent("fa-glm-l", n=-1, mode="compressed", fleet=env.fleet)
    assert env.host.commands[-1][-1] == TRANSCRIPT_PATH
    assert letta == ["[1] You: letta"]
    # ...and a Hermes engineer read hits the Hermes path
    hermes = check_agent("fa-glm-h", n=-1, mode="compressed", fleet=env.fleet)
    assert env.host.commands[-1][-1] == HERMES_TRANSCRIPT_PATH
    assert hermes == ["[1] You: hermes"]


# --- "what is it doing right now" falls out of the trail --------------------

def test_what_is_it_doing_now_falls_out_of_the_trail(env):
    # Arrange: the newest entries carry the live answer
    env.watch["fa-glm-l"].events = [
        event(1.0, "c1", "session", id="s1", cwd="/home/node"),
        event(2.0, "c1", "assistant", text="working on it"),
        event(3.0, "c1", "process_state", state="active", processes=[
            {"pid": 100, "cmdline": "letta run"}]),
    ]
    # Act: a small n — the freshest trail
    result = check_agent("fa-glm-l", n=3, fleet=env.fleet)
    # Assert: the newest event answers "what is it doing now"
    newest = result[-1]
    assert newest["event"] == "process_state"
    assert newest["state"] == "active"
    assert newest["conversation"] == "c1"


def test_never_calls_status_or_ps(env):
    # Arrange
    env.watch["fa-glm-l"].events = [event(1.0, "c1", "assistant", text="hi")]
    # Act
    check_agent("fa-glm-l", n=1, fleet=env.fleet)
    # Assert: only the trail is read — the status/ps surface is retired
    assert env.watch["fa-glm-l"].requests == ["/events?n=1"]


# --- event schema + truncation (full mode) ---------------------------------

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
    result = check_agent("fa-glm-l", n=-1, mode="full", fleet=env.fleet)
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
    result = check_agent("fa-glm-l", n=-1, mode="full", fleet=env.fleet)
    # Assert
    tr = result[0]
    assert tr["truncated"] is True
    assert len(tr["text"]) == 4096
    assert tr["full_bytes"] == 5000


# --- the merge itself: one tool, three flags -------------------------------

def test_the_two_old_tools_are_gone(env):
    # The merged tool replaced both — no legacy names survive.
    assert not hasattr(comm_tools, "check_what_agent_is_doing")
    assert not hasattr(comm_tools, "check_agent_logs")
    assert callable(comm_tools.check_agent)


def test_flag_surface_is_sibling_n_mode(env):
    # 3 flags, 1 required: (sibling, n=None, mode="full")
    params = {k: v for k, v in inspect.signature(check_agent).parameters.items()
              if k != "fleet"}
    assert list(params) == ["sibling", "n", "mode"]
    assert params["sibling"].default is inspect.Parameter.empty
    assert params["n"].default is None
    assert params["mode"].default == "full"
    # the retired flags are gone
    assert "stream" not in params
    assert "facet" not in params


# --- unknown sibling -------------------------------------------------------

def test_unknown_sibling_reports_not_found(env):
    # Act / Assert
    with pytest.raises(SiblingNotFound):
        check_agent("does-not-exist", fleet=env.fleet)
