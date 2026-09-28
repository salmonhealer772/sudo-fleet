"""Tests for the message-agent tool (comm/tools/features/message-agent.feature)."""

import pytest

from comm_tools import (AmbiguousSibling, Distributor, SiblingNotFound,
                        message_agent, queue_status)
from fakes import make_env


def test_direct_mode_calls_letta_prompt_and_returns_reply(env):
    # Arrange
    env.mcp["fa-glm-l"].reply = "I am fa-glm-l"
    # Act
    reply = message_agent("fa-glm-l", "Who are you?", mode="direct", fleet=env.fleet)
    # Assert
    tool, args = env.mcp["fa-glm-l"].calls[-1]
    assert tool == "letta_prompt"
    assert args == {
        "prompt": "Who are you?", "stream": False, "json": False,
        "new_chat": False, "mode": "direct", "source": None,
    }
    assert reply == "I am fa-glm-l"


def test_default_mode_is_direct(env):
    # Act (no mode given)
    message_agent("fa-glm-l", "hi", fleet=env.fleet)
    # Assert
    assert env.mcp["fa-glm-l"].calls[-1][1]["mode"] == "direct"


def test_inbox_mode_returns_id_and_status(env):
    # Act
    result = message_agent("fa-glm-l", "do a long task", mode="inbox", fleet=env.fleet)
    # Assert
    assert env.mcp["fa-glm-l"].calls[-1][1]["mode"] == "inbox"
    assert result == {"id": "msg-0001", "status": "pending"}


def test_inbox_reply_fetched_later_by_id(env):
    # Arrange
    env.mcp["fa-glm-l"].inbox_id = "abc"
    env.mcp["fa-glm-l"].queue_status = {
        "pending": [],
        "recent": [{"id": "abc", "status": "completed", "reply": "done"}],
    }
    sent = message_agent("fa-glm-l", "do a long task", mode="inbox", fleet=env.fleet)
    assert sent["id"] == "abc"
    # Act: fetch the reply later via the recipient's queue-status tool
    status = queue_status("fa-glm-l", fleet=env.fleet)
    # Assert
    assert env.mcp["fa-glm-l"].calls[-1][0] == "letta_queue_status"
    completed = next(r for r in status["recent"] if r["id"] == "abc")
    assert completed["status"] == "completed"
    assert completed["reply"] == "done"


def test_source_tag_passed_through(env):
    # Act
    message_agent("fa-glm-l", "hi", source="me", fleet=env.fleet)
    # Assert
    assert env.mcp["fa-glm-l"].calls[-1][1]["source"] == "me"


def test_default_resumes_persisted_conversation(env):
    # Act
    message_agent("fa-glm-l", "hi", fleet=env.fleet)
    # Assert
    assert env.mcp["fa-glm-l"].calls[-1][1]["new_chat"] is False


def test_new_chat_true_starts_fresh(env):
    # Act
    message_agent("fa-glm-l", "hi", new_chat=True, fleet=env.fleet)
    # Assert
    assert env.mcp["fa-glm-l"].calls[-1][1]["new_chat"] is True


def test_json_mode_returns_structured_reply(env):
    # Act
    result = message_agent("fa-glm-l", "hi", json=True, fleet=env.fleet)
    # Assert
    assert env.mcp["fa-glm-l"].calls[-1][1]["json"] is True
    assert result == {"reply": "hi", "status": "ok"}


def test_stream_mode_joins_deltas(env):
    # Arrange
    env.mcp["fa-glm-l"].stream_deltas = ["Hel", "lo, ", "world"]
    # Act
    result = message_agent("fa-glm-l", "hi", stream=True, fleet=env.fleet)
    # Assert
    assert env.mcp["fa-glm-l"].calls[-1][1]["stream"] is True
    assert result == "Hello, world"


def test_engineer_sibling_uses_hermes_prompt(env):
    # Arrange
    env.mcp["fa-glm-h"].reply = "hello"
    # Act
    reply = message_agent("fa-glm-h", "say hi", fleet=env.fleet)
    # Assert
    tool, args = env.mcp["fa-glm-h"].calls[-1]
    assert tool == "hermes_prompt"
    assert args == {"prompt": "say hi", "json": False, "mode": "direct", "source": None}
    assert reply == "hello"


def test_engineer_ignores_stream_and_new_chat(env):
    # Act
    message_agent("fa-glm-h", "hi", stream=True, new_chat=True, fleet=env.fleet)
    # Assert: hermes_prompt got only prompt/json/mode/source
    tool, args = env.mcp["fa-glm-h"].calls[-1]
    assert tool == "hermes_prompt"
    assert set(args) == {"prompt", "json", "mode", "source"}
    assert "stream" not in args and "new_chat" not in args


def test_engineer_json_pretty_prints_valid_json(env):
    # Act
    result = message_agent("fa-glm-h", "hi", json=True, fleet=env.fleet)
    # Assert
    assert env.mcp["fa-glm-h"].calls[-1][1]["json"] is True
    import json
    assert json.loads(result) == {"reply": "hi from hermes"}
    assert "\n" in result  # pretty-printed


def test_engineer_json_returns_raw_text_when_not_json(env):
    # Arrange: sidecar returns non-JSON raw text despite json=true
    env.mcp["fa-glm-h"].hermes_json_text = "not json"
    # Act
    result = message_agent("fa-glm-h", "hi", json=True, fleet=env.fleet)
    # Assert
    assert result == "not json"


def test_engineer_inbox_returns_id(env):
    # Act
    result = message_agent("fa-glm-h", "long build", mode="inbox", fleet=env.fleet)
    # Assert
    assert env.mcp["fa-glm-h"].calls[-1][1]["mode"] == "inbox"
    assert result == {"id": "msg-0001", "status": "pending"}


def test_sender_does_not_manage_ordering(env):
    # Arrange: fa-glm-l is busy; three more messages arrive
    msgs = ["m1", "m2", "m3"]
    # Act
    for m in msgs:
        message_agent("fa-glm-l", m, fleet=env.fleet)
    # Assert: the sender simply sent each, in order, none dropped
    prompts = [args["prompt"] for tool, args in env.mcp["fa-glm-l"].calls
               if tool == "letta_prompt"]
    assert prompts == msgs


def test_recipient_drains_one_at_a_time_group_by_source():
    # Arrange: N rapid messages from multiple sources, arrival order
    d = Distributor()
    for source, mid in [("x", "x1"), ("y", "y1"), ("x", "x2"), ("z", "z1"), ("x", "x3")]:
        d.enqueue(source, mid)
    # Act: drain worker yields one at a time
    drained = list(d.drain())
    # Assert: FIFO by arrival -> drain all of x -> next most-recent source...
    assert drained == ["x1", "x2", "x3", "y1", "z1"]
    assert len(drained) == 5  # none dropped


def test_long_job_not_cut_off(env):
    # Arrange: a long reply (direct mode must impose no timeout)
    long_reply = "x" * 10000
    env.mcp["fa-glm-l"].reply = long_reply
    # Act
    reply = message_agent("fa-glm-l", "big job", mode="direct", fleet=env.fleet)
    # Assert: full reply returned, no timeout on the call path
    assert reply == long_reply
    tool, args = env.mcp["fa-glm-l"].calls[-1]
    assert "timeout" not in args


def test_exact_name_match_resolves_case_insensitively(env):
    # Arrange
    env.mcp["fa-glm-l"].reply = "hi"
    # Act
    reply = message_agent("FA-GLM-L", "hi", fleet=env.fleet)
    # Assert: reached fa-glm-l's sidecar despite case difference
    assert reply == "hi"
    assert env.mcp["fa-glm-l"].calls


def test_substring_match_resolves_unique_sibling():
    # Arrange: only fa-glm-l contains "glm"
    env = make_env([("fa-glm-l", "letta"), ("ms-x", "letta")])
    env.mcp["fa-glm-l"].reply = "unique"
    # Act
    reply = message_agent("glm", "hi", fleet=env.fleet)
    # Assert
    assert reply == "unique"


def test_ambiguous_name_lists_candidates():
    # Arrange: fa-glm-l and ya-glm-l both contain "glm"
    env = make_env([("fa-glm-l", "letta"), ("ya-glm-l", "letta")])
    # Act / Assert
    with pytest.raises(AmbiguousSibling) as exc:
        message_agent("glm", "hi", fleet=env.fleet)
    assert set(exc.value.candidates) == {"fa-glm-l", "ya-glm-l"}


def test_unknown_sibling_reports_not_found(env):
    # Act / Assert
    with pytest.raises(SiblingNotFound):
        message_agent("does-not-exist", "hi", fleet=env.fleet)
