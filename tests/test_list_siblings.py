"""Tests for the list-siblings tool (features/list-siblings.feature)."""

from comm_tools import list_siblings, message_agent
from fakes import make_env, services_text


def test_full_roster_lists_every_sibling_with_addresses(env):
    # Arrange (default env: fa-glm-l, ms-glm-l, fa-glm-h)
    # Act
    roster = list_siblings(fleet=env.fleet)
    # Assert
    assert {e["sibling"] for e in roster} == {"fa-glm-l", "ms-glm-l", "fa-glm-h"}
    for entry in roster:
        assert set(entry) == {"sibling", "mcp_host", "watch_host"}


def test_roster_maps_bare_name_to_addresses(env):
    # Act
    roster = list_siblings(fleet=env.fleet)
    entry = next(e for e in roster if e["sibling"] == "fa-glm-l")
    # Assert
    assert entry == {
        "sibling": "fa-glm-l",
        "mcp_host": "sudo-fa-glm-l-mcp:8000",
        "watch_host": "sudo-fa-glm-l-watch:8000",
    }


def test_reaches_host_via_docker_socket_bridge(env):
    # Act
    list_siblings(fleet=env.fleet)
    # Assert: the tool ran kubectl on the host through the bridge, not in-pod.
    assert ["kubectl", "get", "services", "-n", "default"] in env.host.commands


def test_filter_narrows_roster_by_substring():
    # Arrange
    env = make_env([("fa-glm-l", "letta"), ("ya-glm-l", "letta"), ("ms-x", "letta")])
    # Act
    roster = list_siblings(filter="glm", fleet=env.fleet)
    # Assert
    names = {e["sibling"] for e in roster}
    assert names == {"fa-glm-l", "ya-glm-l"}
    assert "ms-x" not in names


def test_unique_substring_match_returns_single_entry():
    # Arrange
    env = make_env([("fa-glm-l", "letta"), ("ms-glm-l", "letta")])
    # Act
    roster = list_siblings(filter="fa", fleet=env.fleet)
    # Assert
    assert [e["sibling"] for e in roster] == ["fa-glm-l"]


def test_no_match_returns_clear_empty_result():
    # Arrange
    env = make_env([("fa-glm-l", "letta")])
    # Act
    roster = list_siblings(filter="does-not-exist", fleet=env.fleet)
    # Assert: clear "no matching siblings" (empty, no error, no hang)
    assert roster == []


def test_roster_reflects_newly_added_sibling(env):
    # Arrange: new-glm-l is not present yet
    assert "new-glm-l" not in {e["sibling"] for e in list_siblings(fleet=env.fleet)}
    # Act: spawn new-glm-l -> the live kubectl output now includes it
    env.host.set_sub("kubectl get services", services_text([
        "sudo-fa-glm-l-mcp", "sudo-fa-glm-l-watch",
        "sudo-ms-glm-l-mcp", "sudo-ms-glm-l-watch",
        "sudo-fa-glm-h-mcp", "sudo-fa-glm-h-watch",
        "sudo-new-glm-l-mcp", "sudo-new-glm-l-watch",
    ]))
    roster = list_siblings(fleet=env.fleet)
    # Assert: no edit to any baked-in list was needed
    assert "new-glm-l" in {e["sibling"] for e in roster}


def test_roster_drops_removed_sibling():
    # Arrange
    env = make_env([("fa-glm-l", "letta"), ("ya-glm-l", "letta")])
    assert "ya-glm-l" in {e["sibling"] for e in list_siblings(fleet=env.fleet)}
    # Act: ya-glm-l is taken down
    env.host.set_sub("kubectl get services", services_text(
        ["sudo-fa-glm-l-mcp", "sudo-fa-glm-l-watch"]))
    roster = list_siblings(fleet=env.fleet)
    # Assert
    assert "ya-glm-l" not in {e["sibling"] for e in roster}


def test_roster_feeds_message_agent_directly(env):
    # Arrange: find fa-glm-l's mcp host from the roster, then message it
    roster = list_siblings(fleet=env.fleet)
    entry = next(e for e in roster if e["sibling"] == "fa-glm-l")
    env.mcp["fa-glm-l"].reply = "I am fa-glm-l"
    # Act: message-agent by the bare name the roster returned
    reply = message_agent(entry["sibling"], "hi", fleet=env.fleet)
    # Assert: it reached the sibling the roster's mcp_host points at
    assert reply == "I am fa-glm-l"
    assert env.mcp["fa-glm-l"].calls[-1][0] == "letta_prompt"


def test_empty_fleet_returns_empty_roster(env):
    # Arrange: no agent services in scope
    env.host.set_sub("kubectl get services", services_text([]))
    # Act
    roster = list_siblings(fleet=env.fleet)
    # Assert: empty roster, not an error or a hang
    assert roster == []
