Feature: The list-siblings skill teaches correct usage

  The list-siblings skill documents how an agent discovers what other agents
  exist before messaging or checking on them. It tells the agent to consult
  the live roster first — not to guess a sibling name or ask a human.

  Scenario: Skill tells the agent to list before messaging an unknown sibling
    Given an agent has the "list-siblings" skill
    When the agent needs to reach a sibling whose exact name it is unsure of
    Then the skill says: call list-siblings first to see the roster
    And then message the sibling by the exact bare name the roster returned

  Scenario: Skill gives the concrete invocation for the full roster
    Given an agent has the "list-siblings" skill
    When the agent wants to see the whole fleet
    Then the skill says: call list-siblings with no filter
    And the skill notes each entry gives the sibling name, its -mcp host, and its -watch host

  Scenario: Skill gives the concrete invocation for a filtered roster
    Given an agent has the "list-siblings" skill
    When the agent wants only agents matching a fragment
    Then the skill says: call list-siblings with filter "<fragment>"
    And that a unique match returns one entry, multiple returns all matches, none says "no match"

  Scenario: Skill teaches that the roster is live, not baked
    Given an agent has the "list-siblings" skill
    When the agent wonders whether to trust a previously-seen list
    Then the skill teaches that the roster is read live (kubectl get services, reached through the agent's docker socket), so it reflects newly-spawned and removed agents automatically

  Scenario: Skill teaches the flow: list -> message / list -> check
    Given an agent has the "list-siblings" skill
    When the agent wants to coordinate with a sibling
    Then the skill directs it to list-siblings to confirm the name and address
    And then message-agent to talk to it, or check-agent-logs / check-what-agent-is-doing to observe it

  Scenario: Skill preserves the orchestrator/engineer split
    Given an agent is a planner with an engineer sibling
    When the agent reads the "list-siblings" skill
    Then the skill reminds it to find its engineer in the roster and delegate heavy technical work to it
