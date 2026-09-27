Feature: The check-agent-logs skill teaches correct usage

  The check-agent-logs skill documents when and how an agent should
  read a sibling's recent activity trail to catch up before messaging.

  Scenario: Agent catches up before messaging
    Given an agent has the "check-agent-logs" skill
    When the agent needs context on what a sibling has been doing
    Then the skill directs the agent to read the sibling's event trail

  Scenario: Skill maps the route to the intent
    Given an agent has the "check-agent-logs" skill
    When the agent wants the trailing history (or a live tail)
    Then the skill tells it to read "/events?n=N" for history or "/stream" for live tail
