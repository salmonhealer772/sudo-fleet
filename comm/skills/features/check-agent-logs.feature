Feature: The check-agent-logs skill teaches correct usage

  The check-agent-logs skill documents how an agent reads a sibling's recent
  activity, across TWO modes (full vs compressed) with depth control in both.

  Scenario: Skill teaches the two modes and their meanings
    Given an agent has the "check-agent-logs" skill
    When the agent wants to read a sibling's trail
    Then the skill teaches:
      | mode       | what it shows                                        | how to read it                                |
      | full       | every event incl. thinking/tools/sessions            | GET /events?n=N (the -watch HTTP tap)         |
      | compressed | only real prompts + replies (chat log)               | read transcript.txt directly (tail -n N)      |

  Scenario: Skill teaches when to use compressed vs full
    Given an agent has the "check-agent-logs" skill
    When the agent is deciding which mode to read
    Then the skill teaches it to use compressed mode to see what was said (the conversation)
    And to use full mode to see everything the sibling thought and did (reasoning, tool use)

  Scenario: Skill teaches depth control in both modes
    Given an agent has the "check-agent-logs" skill
    When the agent wants to control how far back it looks
    Then the skill teaches it to set n small for a quick recent check
    And to set n large to reach deep history
    And that n is honored by BOTH /events?n=N (full) and tail -n N (compressed)

  Scenario: Skill teaches the live tail
    Given an agent has the "check-agent-logs" skill
    When the agent wants to follow a sibling live
    Then the skill tells it to use /stream (full-mode live tail)

  Scenario: Skill teaches the full event schema
    Given an agent has the "check-agent-logs" skill
    When the agent reads a full-mode trail
    Then the skill tells it each event carries ts, conversation, and event
    And the event types are user, thinking, assistant, tool_call, tool_result, session, and process_state

  Scenario: Skill teaches catch-up-before-messaging
    Given an agent has the "check-agent-logs" skill
    When the agent needs context on what a sibling has been doing
    Then the skill directs the agent to read the sibling's recent activity before messaging it
