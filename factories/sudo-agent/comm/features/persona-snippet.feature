Feature: The persona snippet makes agents aware of fleet communication

  The persona snippet is a drop-in block added to an agent's existing persona so
  it always knows it can list, message, and check on siblings — the awareness half
  that makes the tools actually get used.

  Scenario: Snippet is a drop-in, not a full persona
    Given an existing agent persona
    When the "Fleet communication" snippet is added to it
    Then the agent's existing identity remains intact
    And the agent now knows about "list-siblings", "message-agent", and "check-agent"

  Scenario: Snippet names the three tools and their purpose
    Given an agent whose persona includes the snippet
    When the agent reads the snippet
    Then it learns "list-siblings" shows who else is in the fleet and how to reach them
    And "message-agent" sends a prompt to a sibling by name and returns its reply
    And "check-agent" reads a sibling's trail — reporting both what it is doing right now (freshest events) and its recent history

  Scenario: Snippet teaches list-before-message
    Given an agent whose persona includes the snippet
    When the agent is unsure which siblings exist
    Then the snippet directs it to list-siblings first, then message by the exact name

  Scenario: Snippet preserves the orchestrator/engineer split
    Given an agent is a planner with an engineer sibling
    When the agent reads the snippet
    Then it is directed to delegate heavy technical work to its engineer, not do it itself

  Scenario: Agent reaches for the tools unprompted
    Given an agent whose persona includes the snippet, and which has the tools and skills
    When the agent needs to ask a sibling to do something
    Then the agent reaches for "list-siblings" / "message-agent" on its own, without a human telling it the tool exists

  Scenario: Awareness without the snippet, tool goes unused
    Given an agent has the tools and skills but NOT the persona snippet
    Then the agent is likely to ignore the capability (the psy-glm lesson)
    And adding the snippet is what closes that gap
