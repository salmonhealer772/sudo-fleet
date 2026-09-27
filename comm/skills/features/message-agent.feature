Feature: The message-agent skill teaches correct usage

  The message-agent skill documents when and how an agent should message a
  sibling. It generalizes "reaching-my-engineer" to "reaching-any-sibling", and
  its instructions match the message-agent tool's modes exactly.

  Scenario: Skill teaches the reach path and naming
    Given an agent has the "message-agent" skill
    When the agent needs to message a sibling by name
    Then the skill tells it a sibling is addressed by its bare name (deploy name minus "sudo-")
    And that the sibling is reached at "http://sudo-{name}-mcp:8000/mcp"
    And that a Letta planner answers "letta_prompt" while a Hermes engineer answers "hermes_prompt"

  Scenario: Skill teaches one-shot as the default
    Given an agent has the "message-agent" skill
    When the agent wants a single plain-text reply
    Then the skill tells it to use the default one-shot mode (stream=false, json=false, new_chat=false)

  Scenario: Skill teaches json mode for structured replies
    Given an agent has the "message-agent" skill
    When the agent needs the reply plus metadata (result, agent_id, conversation_id, usage)
    Then the skill tells it to use json=true

  Scenario: Skill teaches stream mode selects the stream-json path
    Given an agent has the "message-agent" skill
    When the agent wants the stream-json delta path
    Then the skill tells it to use stream=true
    And that the reply is returned as the joined deltas

  Scenario: Skill teaches new_chat vs resume
    Given an agent has the "message-agent" skill
    When the agent wants a fresh conversation with a planner sibling
    Then the skill tells it to use new_chat=true
    And that the default (new_chat=false) resumes the planner's persisted conversation

  Scenario: Skill teaches the no-timeout path for long jobs
    Given an agent has the "message-agent" skill
    When the agent sends a long-running request to a sibling
    Then the skill tells it the call is not cut off at 120s and the full reply will be returned

  Scenario: Skill preserves the orchestrator/engineer split
    Given an agent is a planner with an engineer sibling
    When the agent reads the "message-agent" skill
    Then the skill directs it to delegate heavy technical work to its engineer
    And not to do the engineering itself
