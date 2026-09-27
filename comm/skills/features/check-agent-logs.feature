Feature: The check-agent-logs skill teaches correct usage

  The check-agent-logs skill documents how an agent reads a sibling's recent
  activity. Its instructions must tell the agent HOW to invoke the tool in
  each case — which mode, and how to set the depth (`n`) — so the agent does
  not have to work out the mechanics itself.

  Scenario: Skill tells the agent how to pick a mode
    Given an agent has the "check-agent-logs" skill
    When the agent wants to read a sibling's activity
    Then the skill tells it to pass a "mode" argument, one of:
      | mode       | use when you want                                    |
      | compressed | to see the conversation — what was said               |
      | full       | to see everything — reasoning, tools, each step       |

  Scenario: Skill tells the agent how to set depth with n
    Given an agent has the "check-agent-logs" skill
    When the agent wants to control how far back it looks
    Then the skill tells it to set the "n" argument to the number of items to read:
      - n small (e.g. 5-20)   -> a quick recent check
      - n large (e.g. 100-500) -> deep history
    And that "n" is honored in BOTH modes (full and compressed)

  Scenario: Skill gives the concrete invocation for compressed mode
    Given an agent has the "check-agent-logs" skill
    When the agent wants the recent conversation only
    Then the skill says: call check-agent-logs with mode "compressed" and a small n (e.g. 20)
    And the skill says the tool reads the sibling's transcript.txt (real prompts + replies only)

  Scenario: Skill gives the concrete invocation for full mode
    Given an agent has the "check-agent-logs" skill
    When the agent wants the full unabridged trail including thinking and tools
    Then the skill says: call check-agent-logs with mode "full" and set n for how far back
    And the skill says the tool reads the sibling's /events?n=N

  Scenario: Skill tells the agent to go deep when context is missing
    Given an agent has the "check-agent-logs" skill
    When the agent lacks context and needs a lot of history
    Then the skill tells it to use a LARGE n (e.g. 200+) rather than the small default

  Scenario: Skill tells the agent how to follow live
    Given an agent has the "check-agent-logs" skill
    When the agent wants to watch a sibling as it happens
    Then the skill says to use full mode's /stream (live tail) instead of a fixed n

  Scenario: Skill tells the agent to read before messaging
    Given an agent has the "check-agent-logs" skill
    When the agent is about to message a sibling it has not followed recently
    Then the skill directs it to first check-agent-logs (compressed, small n) to catch up
    And then message the sibling
