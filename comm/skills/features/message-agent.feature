Feature: The message-agent skill teaches correct usage

  The message-agent skill documents how an agent messages a sibling. Its
  instructions must tell the agent HOW to invoke the tool in each case —
  the exact arguments — so the agent does not reason from the raw MCP
  plumbing. It also teaches that messages are QUEUED and fed to the sibling
  one at a time, so the agent does not expect an instant answer when the
  sibling is busy. It generalizes "reaching-my-engineer" to
  "reaching-any-sibling".

  Scenario: Skill gives the concrete invocation for a plain message
    Given an agent has the "message-agent" skill
    When the agent wants a single plain-text reply from a sibling
    Then the skill says: message-agent with sibling "<name>" and prompt "<message>"
    And the skill notes the default mode is direct (waits for the reply)

  Scenario: Skill teaches the two delivery modes and when to use each
    Given an agent has the "message-agent" skill
    When the agent is deciding how to send
    Then the skill teaches:
      | mode   | behavior                                     | use when                                          |
      | direct | enqueue + wait for the reply                 | you need the answer now, in one call              |
      | inbox  | enqueue only, get a message id, no wait      | fire-and-forget, or let the sibling get to it     |

  Scenario: Skill tells the agent messages are queued, not instant
    Given an agent has the "message-agent" skill
    When the agent messages a sibling that may be busy
    Then the skill teaches that the message is held in a queue and fed one at a time
    And that the reply may be delayed if the sibling is mid-task
    And the skill suggests inbox mode when the agent does not need to wait

  Scenario: Skill tells the agent how to pick the sibling by name
    Given an agent has the "message-agent" skill
    When the agent messages a sibling by name
    Then the skill teaches that the sibling is the bare name (deploy name minus "sudo-")
    And that an ambiguous/partial name errors or lists candidates, so the agent should use the exact name

  Scenario: Skill gives the concrete invocation for a structured reply
    Given an agent has the "message-agent" skill
    When the agent needs the reply plus metadata (result, agent_id, conversation_id, usage)
    Then the skill says: message-agent with json=true
    And the skill notes this returns a JSON object instead of plain text

  Scenario: Skill gives the concrete invocation for a streamed reply
    Given an agent has the "message-agent" skill
    When the agent wants the stream-json delta path (live token output)
    Then the skill says: message-agent with stream=true
    And the skill notes the reply arrives as the joined deltas

  Scenario: Skill gives the concrete invocation for a fresh planner conversation
    Given an agent has the "message-agent" skill
    When the agent wants to start fresh (not resume) with a planner sibling
    Then the skill says: message-agent with new_chat=true
    And the skill notes the default (new_chat=false) resumes the planner's persisted conversation

  Scenario: Skill teaches that engineers are stateless one-shots
    Given an agent has the "message-agent" skill
    When the agent messages a Hermes engineer sibling
    Then the skill notes the engineer only accepts prompt (and optional json)
    And the skill directs the agent to NOT pass stream or new_chat to an engineer (they are ignored)

  Scenario: Skill teaches the no-timeout path for long jobs
    Given an agent has the "message-agent" skill
    When the agent sends a long-running request to a sibling
    Then the skill tells it the call is not cut off at 120s and the full reply will be returned

  Scenario: Skill preserves the orchestrator/engineer split
    Given an agent is a planner with an engineer sibling
    When the agent reads the "message-agent" skill
    Then the skill directs it to delegate heavy technical work to its engineer
    And not to do the engineering itself
