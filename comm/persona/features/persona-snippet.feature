Feature: The persona snippet makes agents aware of fleet communication

  The persona snippet is a drop-in block added to an agent's existing
  persona so it always knows it can message and check on siblings —
  the awareness half that makes the tools actually get used.

  Scenario: Snippet is a drop-in, not a full persona
    Given an existing agent persona
    When the "Fleet communication" snippet is added to it
    Then the agent's existing identity remains intact
    And the agent now knows about "message-agent", "check-what-agent-is-doing", and "check-agent-logs"

  Scenario: Agent reaches for the tools unprompted
    Given an agent whose persona includes the snippet, and which has the three tools and skills
    When the agent needs to ask a sibling to do something
    Then the agent reaches for "message-agent" on its own, without a human telling it the tool exists

  Scenario: Awareness without the snippet, tool goes unused
    Given an agent has the tools and skills but NOT the persona snippet
    Then the agent is likely to ignore the capability (the psy-glm lesson)
    And adding the snippet is what closes that gap
