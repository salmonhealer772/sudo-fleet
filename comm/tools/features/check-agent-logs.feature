Feature: Check a sibling agent's logs

  The check-agent-logs tool tails a sibling's event trail from its "-watch"
  sidecar at "http://sudo-{name}-watch:8000". It supports TWO modes, both
  depth-controllable:

  - FULL mode reads GET /events?n=N (or GET /stream for a live tail): every
    event — including every "thinking", "tool_call", "tool_result",
    "session", and "process_state" event. This is the raw, unabridged trail
    of everything the agent has thought and done.

  - COMPRESSED mode reads GET /transcript?n=N: only real user prompts
    ("You:") and assistant replies ("Agent:"). Thinking, tool calls/results,
    sessions, process states, and system reminders are stripped out. This is
    the plain chat log — just what was said, not how the agent got there.
    (Parity with `stream.sh -t`, which tails transcript.txt.)

  Both modes are depth-controllable: `n` selects how far back to look
  (small n = recent, large n = deep history).

  Background:
    Given a running sudo-fleet with at least two agents
    And each agent exposes its "-watch" service

  Scenario: Full mode returns last N events (depth-controllable)
    Given agent "ya-glm-l" is reachable at "sudo-ya-glm-l-watch:8000"
    When I call check-agent-logs with sibling "ya-glm-l", mode full, and n=10
    Then it performs GET /events?n=10
    And it returns up to 10 event records, one JSON object per line
    And each event has a "ts", "conversation", and "event" field

  Scenario: Full mode omitted n falls back to the sidecar default of 100
    Given agent "ya-glm-l" is reachable at "sudo-ya-glm-l-watch:8000"
    When I call check-agent-logs with sibling "ya-glm-l" and mode full with no n
    Then it performs GET /events
    And it returns the last 100 events

  Scenario: Full mode with large n reaches deep history
    Given agent "ya-glm-l" has logged far more than 100 events
    When I call check-agent-logs with sibling "ya-glm-l", mode full, and n=1000
    Then it performs GET /events?n=1000
    And it returns up to 1000 events, reaching further back than the default

  Scenario: Compressed mode returns last N chat lines
    Given agent "ya-glm-l" is reachable at "sudo-ya-glm-l-watch:8000"
    When I call check-agent-logs with sibling "ya-glm-l", mode compressed, and n=10
    Then it performs GET /transcript?n=10
    And it returns up to 10 plain-text lines of the form "[ts] You:/Agent: text"
    And no thinking, tool_call, tool_result, session, process_state, or reminder text is present

  Scenario: Compressed mode strips the agent's internal reasoning
    Given agent "ya-glm-l" logged thinking events, tool calls, and an assistant reply
    When I call check-agent-logs with sibling "ya-glm-l" in compressed mode
    Then the returned transcript shows the assistant reply
    And it does NOT show the thinking events or tool calls

  Scenario: Compressed mode is depth-controllable
    Given agent "ya-glm-l" has a long chat history
    When I call check-agent-logs with sibling "ya-glm-l", mode compressed, and n=200
    Then it performs GET /transcript?n=200
    And it returns up to 200 chat lines

  Scenario: Live tail in full mode
    Given agent "ya-glm-l" is reachable at "sudo-ya-glm-l-watch:8000"
    When I call check-agent-logs with sibling "ya-glm-l" in full stream mode
    Then it performs GET /stream
    And it dumps a backlog then follows new full-mode events

  Scenario: Event schema is typed (full mode)
    Given agent "ya-glm-l" logged a user prompt, thinking, an assistant reply, a tool call, a tool result, a session, and a process state
    When I call check-agent-logs with sibling "ya-glm-l" in full mode
    Then the returned events carry these fields:
      | event         | fields                       |
      | user          | text, reminder               |
      | thinking      | text                         |
      | assistant     | text                         |
      | tool_call     | name, args                   |
      | tool_result   | text, truncated, full_bytes  |
      | session       | id, cwd                      |
      | process_state | state, processes             |

  Scenario: Tool results are truncated to 4096 bytes (full mode)
    Given agent "ya-glm-l" logged a tool result larger than 4096 bytes
    When I call check-agent-logs with sibling "ya-glm-l" in full mode
    Then that tool_result event has "truncated" true
    And its "text" is capped at 4096 bytes
    And its "full_bytes" reports the untruncated size

  Scenario: Unknown sibling is reported
    Given there is no agent named "does-not-exist"
    When I call check-agent-logs with sibling "does-not-exist"
    Then I get a clear "not found" error
