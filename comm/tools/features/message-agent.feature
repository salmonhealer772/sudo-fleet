Feature: Message a sibling agent

  The message-agent tool is the primary way agents in the fleet talk to each other.
  It sends a prompt to any sibling by name and returns that sibling's reply.

  Background:
    Given a running sudo-fleet with at least two agents
    And each agent exposes its "-mcp" service

  Scenario: Message a planner sibling by name
    Given agent "fa-glm-l" is reachable at "sudo-fa-glm-l-mcp:8000"
    When I call message-agent with sibling "fa-glm-l" and prompt "Who are you?"
    Then I get back a reply string from "fa-glm-l"
    And the reply identifies the agent as "fa-glm-l"

  Scenario: Message an engineer sibling (stateless one-shot)
    Given agent "fa-glm-h" is reachable at "sudo-fa-glm-h-mcp:8000"
    When I call message-agent with sibling "fa-glm-h" and prompt "say hi"
    Then I get back a reply string from "fa-glm-h"

  Scenario: Long job is not cut off
    Given agent "fa-glm-l" is reachable
    When I call message-agent with sibling "fa-glm-l" and a prompt that takes longer than 120s
    Then the call does not time out at 120s
    And I eventually get the full reply

  Scenario: Unknown sibling is reported, not hung
    Given there is no agent named "does-not-exist"
    When I call message-agent with sibling "does-not-exist" and prompt "hi"
    Then I get a clear "not found" error
    And the call returns promptly instead of hanging
