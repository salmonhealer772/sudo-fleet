Feature: Check what a sibling agent is doing

  The check-what-agent-is-doing tool reads a sibling's live activity from its
  "-watch" sidecar at "http://sudo-{name}-watch:8000". It answers "is this
  sibling alive, and is it mid-run right now?" from GET /status, plus the exact
  process list from GET /ps.

  Background:
    Given a running sudo-fleet with at least two agents
    And each agent exposes its "-watch" service

  Scenario: Read the full status snapshot
    Given agent "ya-glm-l" is reachable at "sudo-ya-glm-l-watch:8000"
    When I call check-what-agent-is-doing with sibling "ya-glm-l"
    Then it performs GET /status
    And it returns the fields "agent", "deploy", "uptime_s", "agent_container_up", "active", "current_conversation", "last_event_ts", "events_logged", "transcript_bytes", and "watch_port"

  Scenario: Is the sibling alive
    Given agent "ya-glm-l" has its agent container running
    When I call check-what-agent-is-doing with sibling "ya-glm-l"
    Then the returned "agent_container_up" is true

  Scenario: Sibling is idle when no letta process runs
    Given agent "ya-glm-l" has no letta process running
    When I call check-what-agent-is-doing with sibling "ya-glm-l"
    Then the returned "active" is false

  Scenario: Sibling is active when a letta process runs
    Given agent "ya-glm-l" has a letta process running
    When I call check-what-agent-is-doing with sibling "ya-glm-l"
    Then the returned "active" is true

  Scenario: Report the current conversation
    Given agent "ya-glm-l" is mid-conversation "local-conv-123"
    When I call check-what-agent-is-doing with sibling "ya-glm-l"
    Then the returned "current_conversation" is "local-conv-123"

  Scenario: Report the age of the last event
    Given agent "ya-glm-l" logged an event at a known timestamp
    When I call check-what-agent-is-doing with sibling "ya-glm-l"
    Then the returned "last_event_ts" is that timestamp
    And the returned "events_logged" is greater than 0
    And the returned "uptime_s" is greater than 0

  Scenario: List the running processes
    Given agent "ya-glm-l" is reachable at "sudo-ya-glm-l-watch:8000"
    When I call check-what-agent-is-doing with sibling "ya-glm-l" for facet "processes"
    Then it performs GET /ps
    And it returns a list of processes, each with "pid", "ppid", "uid", "age_s", and "cmdline"

  Scenario: Unknown sibling is reported
    Given there is no agent named "does-not-exist"
    When I call check-what-agent-is-doing with sibling "does-not-exist"
    Then I get a clear "not found" error
