Feature: The check-agent-logs skill teaches correct usage

  The check-agent-logs skill documents how an agent reads a sibling's recent
  activity trail. Its instructions map each intent to the exact endpoint:
  history vs live tail.

  Scenario: Skill maps history to /events
    Given an agent has the "check-agent-logs" skill
    When the agent wants the trailing history
    Then the skill tells it to read GET /events?n=N for the last N events

  Scenario: Skill maps live tail to /stream
    Given an agent has the "check-agent-logs" skill
    When the agent wants a live tail
    Then the skill tells it to read GET /stream for the backlog plus follow

  Scenario: Skill teaches the event schema
    Given an agent has the "check-agent-logs" skill
    When the agent reads an event trail
    Then the skill tells it each event carries ts, conversation, and event
    And the event types are user, thinking, assistant, tool_call, tool_result, session, and process_state

  Scenario: Skill teaches catch-up-before-messaging
    Given an agent has the "check-agent-logs" skill
    When the agent needs context on what a sibling has been doing
    Then the skill directs the agent to read the sibling's recent events before messaging it
