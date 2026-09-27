Feature: List the sibling agents in the fleet

  The list-siblings tool is the discovery half of the mesh: it tells an agent
  which other agents exist, and how to reach them, by reading the live fleet
  roster (kubectl get services) on the HOST, reached through the agent's own
  mounted docker socket. An agent should be able to go from "what's out there"
  straight to "message it" or "check on it", without a human listing the fleet
  by hand.

  The roster is the live source of truth — not a baked-in phonebook — so a
  newly-spawned or removed agent shows up / drops off automatically.

  The agent reaches the host via the docker socket + nsenter bridge every
  agent pod already has (both planners and engineers), so no new fleet
  component and no in-pod kubectl is needed.

  Background:
    Given a running sudo-fleet with several agents
    And each agent exposes its "-mcp" and "-watch" services
    And each agent pod mounts the host docker socket at /var/run/docker.sock

  Scenario: List everything addresses a sibling, with the full roster
    Given the fleet has agents "fa-glm-l", "fa-glm-h", and "ms-glm-l"
    When I call list-siblings with no filter
    Then it runs kubectl get services on the host via the docker socket bridge
    And it returns a roster listing each sibling
    And each entry gives the bare name, its "-mcp" host, and its "-watch" host

  Scenario: Roster maps a bare name to its message and watch addresses
    Given the fleet has agent "fa-glm-l"
    When I call list-siblings
    Then the entry for "fa-glm-l" gives:
      | field      | value                    |
      | sibling    | fa-glm-l                 |
      | mcp_host   | sudo-fa-glm-l-mcp:8000   |
      | watch_host | sudo-fa-glm-l-watch:8000 |

  Scenario: The tool reaches the host through the docker socket, not in-pod kubectl
    Given agent "fa-glm-l" has no kubectl or kubeconfig inside its pod
    When I call list-siblings
    Then it still returns the roster
    Because it bridges to the host via docker run --privileged + nsenter -t 1 and runs kubectl there

  Scenario: Filter narrows the roster by substring
    Given both "fa-glm-l" and "ya-glm-l" exist
    When I call list-siblings with filter "glm"
    Then it returns the entries for both "fa-glm-l" and "ya-glm-l"
    And it does not return unrelated agents

  Scenario: Unique substring match returns a single entry
    Given "fa-glm-l" is the only sibling whose name contains "fa"
    When I call list-siblings with filter "fa"
    Then it returns the single entry "fa-glm-l"

  Scenario: No-match filter says so clearly
    Given there is no sibling whose name contains "does-not-exist"
    When I call list-siblings with filter "does-not-exist"
    Then it returns a clear "no matching siblings" result (not an error, not a hang)

  Scenario: Roster reflects a newly-added sibling automatically
    Given the fleet did not have agent "new-glm-l"
    When agent "new-glm-l" is spawned and its services come up
    Then a fresh call to list-siblings includes "new-glm-l"
    And it requires no edit to any baked-in list

  Scenario: Roster drops a removed sibling automatically
    Given the fleet had agent "ya-glm-l" and it is taken down
    When I call list-siblings after it is gone
    Then "ya-glm-l" no longer appears in the roster

  Scenario: list-siblings feeds message-agent directly
    Given an agent needs to message a sibling it is not yet sure exists
    When I call list-siblings first and find the sibling in the roster
    Then I can message-agent it by the bare name the roster returned
    And the mcp_host in the roster is the address message-agent will reach

  Scenario: Empty fleet still answers cleanly
    Given the fleet has no agent services in scope
    When I call list-siblings
    Then it returns an empty roster rather than an error or a hang
