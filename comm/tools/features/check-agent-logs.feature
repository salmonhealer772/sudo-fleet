Feature: Check a sibling agent's logs

  The check-agent-logs tool tails a sibling's event trail
  from its "-watch" sidecar /events endpoint.

  Background:
    Given a running sudo-fleet with at least two agents
    And each agent exposes its "-watch" service

  Scenario: Read the last N events
    Given agent "ya-glm-l" is reachable at "sudo-ya-glm-l-watch:8000"
    When I call check-agent-logs with sibling "ya-glm-l" and n "10"
    Then I get back up to 10 event records
    And each event has a "ts", "conversation", and "event" field

  Scenario: No events yet returns empty
    Given agent "ya-glm-l" has no logged events
    When I call check-agent-logs with sibling "ya-glm-l"
    Then I get back an empty event list without error

  Scenario: Unknown sibling is reported
    Given there is no agent named "does-not-exist"
    When I call check-agent-logs with sibling "does-not-exist"
    Then I get a clear "not found" error
