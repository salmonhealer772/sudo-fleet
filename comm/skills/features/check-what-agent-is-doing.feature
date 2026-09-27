Feature: The check-what-agent-is-doing skill teaches correct usage

  The check-what-agent-is-doing skill documents when and how an agent
  should check a sibling's live activity before messaging it.

  Scenario: Agent checks before messaging
    Given an agent has the "check-what-agent-is-doing" skill
    When the agent is unsure whether a sibling is free to receive a message
    Then the skill directs the agent to check the sibling's /status first

  Scenario: Skill maps the route to the intent
    Given an agent has the "check-what-agent-is-doing" skill
    When the agent wants to know if a sibling is alive or mid-run
    Then the skill tells it to read the sibling's "-watch" /status endpoint
