Feature: Check a sibling agent's logs

  The check-agent-logs tool tails a sibling's event trail from its "-watch"
  sidecar at "http://sudo-{name}-watch:8000". It reads GET /events?n=N for the
  trailing history and GET /stream for a live tail.

  Background:
    Given a running sudo-fleet with at least two agents
    And each agent exposes its "-watch" service

  Scenario: Read the last N events (history)
    Given agent "ya-glm-l" is reachable at "sudo-ya-glm-l-watch:8000"
    When I call check-agent-logs with sibling "ya-glm-l" and n=10
    Then it performs GET /events?n=10
    And it returns up to 10 event records, one JSON object per line
    And each event has a "ts", "conversation", and "event" field

  Scenario: Omitted n falls back to the sidecar default of 100
    Given agent "ya-glm-l" is reachable at "sudo-ya-glm-l-watch:8000"
    When I call check-agent-logs with sibling "ya-glm-l" and no n
    Then it performs GET /events
    And it returns the last 100 events

  Scenario: No events yet returns empty
    Given agent "ya-glm-l" has no logged events
    When I call check-agent-logs with sibling "ya-glm-l"
    Then it returns an empty event list without error

  Scenario: Live tail via /stream
    Given agent "ya-glm-l" is reachable at "sudo-ya-glm-l-watch:8000"
    When I call check-agent-logs with sibling "ya-glm-l" in stream mode
    Then it performs GET /stream
    And it dumps the last 20 events as a backlog, then follows new events
    And it uses "Connection: close" with unframed NDJSON (no chunked encoding)

  Scenario: Event schema is typed
    Given agent "ya-glm-l" logged a user prompt, thinking, an assistant reply, a tool call, a tool result, a session, and a process state
    When I call check-agent-logs with sibling "ya-glm-l"
    Then the returned events carry these fields:
      | event         | fields                       |
      | user          | text, reminder               |
      | thinking      | text                         |
      | assistant     | text                         |
      | tool_call     | name, args                   |
      | tool_result   | text, truncated, full_bytes  |
      | session       | id, cwd                      |
      | process_state | state, processes             |

  Scenario: Tool results are truncated to 4096 bytes
    Given agent "ya-glm-l" logged a tool result larger than 4096 bytes
    When I call check-agent-logs with sibling "ya-glm-l"
    Then that tool_result event has "truncated" true
    And its "text" is capped at 4096 bytes
    And its "full_bytes" reports the untruncated size

  Scenario: Unknown sibling is reported
    Given there is no agent named "does-not-exist"
    When I call check-agent-logs with sibling "does-not-exist"
    Then I get a clear "not found" error
