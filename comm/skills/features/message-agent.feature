Feature: The message-agent skill teaches correct usage

  The message-agent skill documents when and how an agent should
  message a sibling. It generalizes "reaching-my-engineer" to
  "reaching-any-sibling".

  Scenario: Agent loads the skill and learns the reach syntax
    Given an agent has the "message-agent" skill in its skills directory
    When the agent needs to delegate or coordinate with a sibling
    Then the skill is loaded
    And the agent follows the documented reach syntax to message the sibling by name

  Scenario: Skill names the no-timeout requirement
    Given an agent has the "message-agent" skill
    When the agent sends a long-running request to a sibling
    Then the skill tells it to use the no-timeout path so the job is not cut off

  Scenario: Skill preserves the orchestrator/engineer split
    Given an agent is a planner with an engineer sibling
    When the agent reads the "message-agent" skill
    Then the skill directs it to delegate heavy technical work to its engineer
    And not to do the engineering itself
