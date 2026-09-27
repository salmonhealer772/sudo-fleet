Feature: Message a sibling agent

  The message-agent tool is the primary way agents in the fleet talk to each
  other. It sends a prompt to any sibling by name and returns that sibling's
  reply.

  A sibling is addressed by its bare name (the deployment name minus the
  leading "sudo-"; e.g. deployment "sudo-fa-glm-l" -> name "fa-glm-l"). The
  tool reaches the sibling at "http://sudo-{name}-mcp:8000/mcp", performs the
  MCP handshake (initialize), discovers the sibling's prompt tool via
  tools/list, and calls it via tools/call:
    - a Letta planner exposes "letta_prompt(prompt, stream, json, new_chat)"
    - a Hermes engineer exposes "hermes_prompt(prompt, json)"

  Background:
    Given a running sudo-fleet with at least two agents
    And each agent exposes its "-mcp" service

  Scenario: One-shot message to a planner (default mode)
    Given agent "fa-glm-l" is reachable at "sudo-fa-glm-l-mcp:8000"
    When I call message-agent with sibling "fa-glm-l" and prompt "Who are you?"
    Then it calls letta_prompt with prompt "Who are you?", stream=false, json=false, new_chat=false
    And it returns the plain-text reply string from "fa-glm-l"

  Scenario: Default resumes the planner's persisted conversation
    Given agent "fa-glm-l" is reachable at "sudo-fa-glm-l-mcp:8000"
    When I call message-agent with sibling "fa-glm-l" and prompt "hi"
    Then it calls letta_prompt with new_chat=false
    And the planner resumes its persisted conversation

  Scenario: new_chat=true starts a fresh conversation
    Given agent "fa-glm-l" is reachable at "sudo-fa-glm-l-mcp:8000"
    When I call message-agent with sibling "fa-glm-l", prompt "hi", and new_chat=true
    Then it calls letta_prompt with new_chat=true
    And the planner starts a fresh conversation instead of resuming

  Scenario: json mode returns the structured reply object
    Given agent "fa-glm-l" is reachable at "sudo-fa-glm-l-mcp:8000"
    When I call message-agent with sibling "fa-glm-l", prompt "hi", and json=true
    Then it calls letta_prompt with json=true
    And it returns a JSON object with "result", "agent_id", "conversation_id", and "usage" fields

  Scenario: stream mode joins the stream-json deltas into one reply
    Given agent "fa-glm-l" is reachable at "sudo-fa-glm-l-mcp:8000"
    When I call message-agent with sibling "fa-glm-l", prompt "hi", and stream=true
    Then it calls letta_prompt with stream=true
    And it returns the full reply text as the concatenation of the stream-json deltas

  Scenario: Message an engineer sibling (stateless one-shot)
    Given agent "fa-glm-h" is reachable at "sudo-fa-glm-h-mcp:8000"
    When I call message-agent with sibling "fa-glm-h" and prompt "say hi"
    Then it calls hermes_prompt with prompt "say hi" and json=false
    And it returns the reply string from "fa-glm-h"

  Scenario: Engineer sibling has no stream or new_chat mode
    Given agent "fa-glm-h" is reachable at "sudo-fa-glm-h-mcp:8000"
    When I call message-agent with sibling "fa-glm-h", prompt "hi", stream=true, and new_chat=true
    Then it calls hermes_prompt with only prompt and json
    And the stream and new_chat flags are ignored for the engineer

  Scenario: Engineer json mode pretty-prints only valid JSON
    Given agent "fa-glm-h" is reachable at "sudo-fa-glm-h-mcp:8000"
    When I call message-agent with sibling "fa-glm-h", prompt "hi", and json=true
    Then it calls hermes_prompt with json=true
    And it pretty-prints the reply when it is valid JSON, otherwise returns the raw text

  Scenario: Long job is not cut off
    Given agent "fa-glm-l" is reachable at "sudo-fa-glm-l-mcp:8000"
    When I call message-agent with sibling "fa-glm-l" and a prompt that takes longer than 120s
    Then the call is not cut off at 120s
    And I eventually get the full reply

  Scenario: Exact name match resolves
    Given the fleet knows a sibling named "fa-glm-l"
    When I call message-agent with sibling "fa-glm-l"
    Then it resolves the name to "fa-glm-l" exactly (case-insensitive)

  Scenario: Substring match resolves a unique sibling
    Given "fa-glm-l" is the only sibling whose name contains "glm"
    When I call message-agent with sibling "glm"
    Then it resolves the name to "fa-glm-l"

  Scenario: Ambiguous name lists the candidates
    Given both "fa-glm-l" and "ya-glm-l" contain "glm"
    When I call message-agent with sibling "glm"
    Then it reports an ambiguous-name error listing both candidates

  Scenario: Unknown sibling is reported, not hung
    Given there is no agent named "does-not-exist"
    When I call message-agent with sibling "does-not-exist" and prompt "hi"
    Then I get a clear "not found" error
    And the call returns promptly instead of hanging
