Feature: Check a sibling agent — its trail, at any depth

  check-agent is the ONE observability read for the fleet. It reads a sibling's
  trail and answers BOTH "what has it been doing" AND "what is it doing right
  now" from that same trail — the what-is-it-doing answer falls out of the
  freshest entries, not a separate status/ps call.

  It MERGES the former check-agent-logs and check-what-agent-is-doing tools.
  There is no separate GET /status or GET /ps surface any more: to see what a
  sibling is doing right now, read its freshest trail (small n) — the newest
  events carry the current conversation and the latest process_state
  (idle vs active).

  Two modes, one tool:

  - FULL mode reads GET /events?n=N from the sibling's "-watch" sidecar: every
    event — "user", "thinking", "assistant", "tool_call", "tool_result",
    "session", "process_state". The raw, unabridged trail of everything the
    agent has thought and done.

  - COMPRESSED mode reads the sibling's transcript.txt file directly (the same
    read `stream.sh -t` already does): only real user prompts ("You:") and
    assistant replies ("Agent:"). Thinking, tool calls/results, sessions,
    process states and system reminders are stripped. The plain chat log.

  The compressed transcript (transcript.txt) is on-disk in the sibling's watch
  dir; the full trail (events.jsonl) is served by the "-watch" HTTP tap. So
  full mode goes over HTTP, compressed mode reads the file directly.

  ONE depth knob, `n`, identical in both modes: k>0 = the last k entries;
  `n=-1` = the ENTIRE file, no depth cap (so callers never guess a huge number
  like n=90000); omitted = the default depth of 100.

  It works identically on Letta planners and Hermes engineers — they keep their
  transcripts at different paths and the tool picks the right one per sibling.

  Background:
    Given a running sudo-fleet with at least two agents
    And each agent exposes its "-watch" service

  Scenario: Full mode returns the last N events (depth control)
    Given agent "ya-glm-l" is reachable at "sudo-ya-glm-l-watch:8000"
    When I call check-agent with sibling "ya-glm-l", mode full, and n=10
    Then it performs GET /events?n=10
    And it returns up to 10 event records, one JSON object per line
    And each event has a "ts", "conversation", and "event" field

  Scenario: Full mode omitted n falls back to the default depth of 100
    Given agent "ya-glm-l" is reachable at "sudo-ya-glm-l-watch:8000"
    When I call check-agent with sibling "ya-glm-l" and mode full with no n
    Then it performs GET /events
    And it returns the last 100 events

  Scenario: Full mode with large n reaches deep history
    Given agent "ya-glm-l" has logged far more than 100 events
    When I call check-agent with sibling "ya-glm-l", mode full, and n=1000
    Then it performs GET /events?n=1000
    And it returns up to 1000 events, reaching further back than the default

  Scenario: Compressed mode reads the transcript file directly
    Given agent "ya-glm-l" has its transcript.txt at "/home/node/.letta/watch/transcript.txt"
    When I call check-agent with sibling "ya-glm-l", mode compressed, and n=10
    Then it reads the last 10 lines of transcript.txt (i.e. `tail -n 10`)
    And it returns up to 10 plain-text lines of the form "[ts] You:/Agent: text"
    And no thinking, tool_call, tool_result, session, process_state, or reminder text is present

  Scenario: Compressed mode strips the agent's internal reasoning
    Given agent "ya-glm-l" logged thinking events, tool calls, and an assistant reply
    When I call check-agent with sibling "ya-glm-l" in compressed mode
    Then the returned transcript shows the assistant reply
    And it does NOT show the thinking events or tool calls

  Scenario: Compressed mode is depth-controllable
    Given agent "ya-glm-l" has a long chat history
    When I call check-agent with sibling "ya-glm-l", mode compressed, and n=200
    Then it reads the last 200 lines of transcript.txt (i.e. `tail -n 200`)
    And it returns up to 200 chat lines

  Scenario: Omitted n means the same default depth in both modes
    Given agent "ya-glm-l" has a long chat history and many events
    When I call check-agent with sibling "ya-glm-l" and no n, in both modes
    Then full mode reads GET /events (the sidecar's default of 100)
    And compressed mode reads `tail -n 100` of transcript.txt

  Scenario: n=-1 returns the entire compressed transcript (no depth cap)
    Given agent "ya-glm-l" has a chat history of unknown length
    When I call check-agent with sibling "ya-glm-l", mode compressed, and n=-1
    Then it reads the ENTIRE transcript.txt (i.e. `cat`, not a bounded `tail`)
    And it returns all chat lines, regardless of how many there are

  Scenario: n=-1 returns the entire full event trail (no depth cap)
    Given agent "ya-glm-l" has many events
    When I call check-agent with sibling "ya-glm-l", mode full, and n=-1
    Then it returns the ENTIRE events file, not just the trailing N events

  Scenario: n=-1 works identically on Letta and Hermes siblings
    Given agent "fa-glm-h" is a Hermes engineer sibling
    When I call check-agent with sibling "fa-glm-h", mode compressed, and n=-1
    Then it reads the Hermes sibling's entire transcript file
    And the sentinel behaves the same as it does for a Letta planner

  Scenario: One tool answers "what is this sibling doing right now"
    Given agent "ya-glm-l" has logged a session, some tool calls, and a process_state
    When I call check-agent with sibling "ya-glm-l", mode full, and a small n
    Then the freshest returned event is the latest process_state
    And the current conversation is readable from those newest events
    And no separate GET /status or GET /ps call is made

  Scenario: The separate status/ps surface is retired
    Given the fleet comm layer
    Then there is no check-what-agent-is-doing tool and no check-agent-logs tool
    And check-agent is the single merged tool
    And it never performs GET /status or GET /ps

  Scenario: Event schema is typed (full mode)
    Given agent "ya-glm-l" logged a user prompt, thinking, an assistant reply, a tool call, a tool result, a session, and a process state
    When I call check-agent with sibling "ya-glm-l" in full mode
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
    When I call check-agent with sibling "ya-glm-l" in full mode
    Then that tool_result event has "truncated" true
    And its "text" is capped at 4096 bytes
    And its "full_bytes" reports the untruncated size

  Scenario: Unknown sibling is reported
    Given there is no agent named "does-not-exist"
    When I call check-agent with sibling "does-not-exist"
    Then I get a clear "not found" error
