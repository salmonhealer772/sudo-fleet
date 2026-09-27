Feature: Check what a sibling agent is doing

  The check-what-agent-is-doing tool reads a sibling's live activity
  from its "-watch" sidecar /status endpoint.

  Background:
    Given a running sudo-fleet with at least two agents
    And each agent exposes its "-watch" service

  Scenario: Read a sibling's status snapshot
    Given agent "ya-glm-l" is reachable at "sudo-ya-glm-l-watch:8000"
    When I call check-what-agent-is-doing with sibling "ya-glm-l"
    Then I get back a status object
    And the status includes "active", "current_conversation", and "last_event_ts"

  Scenario: Distinguish idle from active
    Given agent "ya-glm-l" is idle
    When I call check-what-agent-is-doing with sibling "ya-glm-l"
    Then the status reports "active" is false

  Scenario: Unknown sibling is reported
    Given there is no agent named "does-not-exist"
    When I call check-what-agent-is-doing with sibling "does-not-exist"
    Then I get a clear "not found" error
