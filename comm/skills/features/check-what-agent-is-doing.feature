Feature: The check-what-agent-is-doing skill teaches correct usage

  The check-what-agent-is-doing skill documents how an agent checks a sibling's
  live activity before messaging it. Its instructions map each activity question
  to the exact /status field (or /ps endpoint) that answers it.

  Scenario: Skill maps each question to its /status field
    Given an agent has the "check-what-agent-is-doing" skill
    When the agent asks a sibling's activity questions
    Then the skill maps them to fields:
      | question             | answer                             |
      | is it alive?         | GET /status -> agent_container_up  |
      | is it mid-run?       | GET /status -> active              |
      | what conversation?   | GET /status -> current_conversation|
      | when was last event? | GET /status -> last_event_ts, events_logged |

  Scenario: Skill teaches the process-list facet
    Given an agent has the "check-what-agent-is-doing" skill
    When the agent wants to know exactly which processes a sibling is running
    Then the skill tells it to read GET /ps
    And that each process reports pid, ppid, uid, age_s, and cmdline

  Scenario: Skill teaches check-before-messaging
    Given an agent has the "check-what-agent-is-doing" skill
    When the agent is unsure whether a sibling is free to receive a message
    Then the skill directs the agent to read the sibling's /status first
