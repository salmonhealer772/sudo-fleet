Feature: Message a sibling agent

  The message-agent tool is the primary way agents in the fleet talk to each
  other. It sends a prompt to any sibling by name and returns that sibling's
  reply.

  The tool is deliberately SIMPLE: it just sends. The RECIPIENT's own prompt
  distributor — a Redis-backed queue in front of the agent's MCP door — does
  all the ordering and concurrency. The sender's job is only to address a
  sibling and hand it a prompt; the recipient's stack feeds the agent ONE
  message at a time, drops nothing, and never races the agent's state.

  Delivery has TWO modes, matching the shipped mcp_server on both factories:
    - inbox (default) — send and return a message id immediately; fetch the reply later
    - direct — send and WAIT for the reply (no timeout; long jobs fine; explicit opt-in)
  A "source" tag groups messages for the group-by-source ordering rule.

  A sibling is addressed by its bare name (the deployment name minus the
  leading "sudo-"; e.g. deployment "sudo-fa-glm-l" -> name "fa-glm-l"). The
  tool reaches the sibling at "http://sudo-{name}-mcp:8000/mcp", performs the
  MCP handshake (initialize), and calls the sibling's prompt tool:
    - a Letta planner exposes "letta_prompt(prompt, json, new_chat, mode, source)"
    - a Hermes engineer exposes "hermes_prompt(prompt, json, mode, source)"

  Background:
    Given a running sudo-fleet with at least two agents
    And each agent exposes its "-mcp" service
    And a Redis-backed distributor sits in front of each agent's MCP door

  Scenario: Send a prompt to a planner and get the reply (direct mode)
    Given agent "fa-glm-l" is reachable at "sudo-fa-glm-l-mcp:8000"
    When I call message-agent with sibling "fa-glm-l", prompt "Who are you?", and mode "direct"
    Then it calls letta_prompt with prompt "Who are you?", json=false, new_chat=false, mode="direct"
    And it waits for and returns the plain-text reply string from "fa-glm-l"

  Scenario: Default mode is inbox (send and return an id)
    Given agent "fa-glm-l" is reachable at "sudo-fa-glm-l-mcp:8000"
    When I call message-agent with sibling "fa-glm-l" and prompt "hi" (no mode given)
    Then it calls letta_prompt with mode "inbox"
    And it returns a JSON object with a message "id" and status "pending"

  Scenario: inbox mode enqueues and returns a message id immediately
    Given agent "fa-glm-l" is reachable at "sudo-fa-glm-l-mcp:8000"
    When I call message-agent with sibling "fa-glm-l", prompt "do a long task", and mode "inbox"
    Then it calls letta_prompt with mode "inbox"
    And it returns a JSON object with a message "id" and status "pending"
    And it does NOT block waiting for the full reply

  Scenario: inbox reply is fetched later by message id
    Given a message was sent to "fa-glm-l" in inbox mode and returned id "abc"
    When I later call the sibling's queue-status tool and look up id "abc"
    Then I get the completed reply (or "still pending") for that id

  Scenario: source tag drives group-by-source ordering
    Given agent "fa-glm-l" is reachable at "sudo-fa-glm-l-mcp:8000"
    When I call message-agent with sibling "fa-glm-l", prompt "hi", and source "me"
    Then it calls letta_prompt with source "me"
    And the recipient's distributor groups that message under source "me"

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
    And it returns the structured JSON reply

  Scenario: Message an engineer sibling (stateless one-shot)
    Given agent "fa-glm-h" is reachable at "sudo-fa-glm-h-mcp:8000"
    When I call message-agent with sibling "fa-glm-h" and prompt "say hi"
    Then it calls hermes_prompt with prompt "say hi", json=false, and mode inbox
    And it returns a message id immediately instead of blocking

  Scenario: Engineer sibling has no new_chat mode
    Given agent "fa-glm-h" is reachable at "sudo-fa-glm-h-mcp:8000"
    When I call message-agent with sibling "fa-glm-h", prompt "hi", and new_chat=true
    Then it calls hermes_prompt with only prompt, json, mode, and source
    And the new_chat flag is ignored for the engineer

  Scenario: Engineer json mode pretty-prints only valid JSON
    Given agent "fa-glm-h" is reachable at "sudo-fa-glm-h-mcp:8000"
    When I call message-agent with sibling "fa-glm-h", prompt "hi", and json=true
    Then it calls hermes_prompt with json=true
    And it pretty-prints the reply when it is valid JSON, otherwise returns the raw text

  Scenario: Engineer inbox mode also enqueues and returns an id
    Given agent "fa-glm-h" is reachable at "sudo-fa-glm-h-mcp:8000"
    When I call message-agent with sibling "fa-glm-h", prompt "long build", and mode "inbox"
    Then it calls hermes_prompt with mode "inbox"
    And it returns a message id immediately instead of blocking

  Scenario: The sender does not manage ordering — the recipient does
    Given agent "fa-glm-l" is busy and three more messages are sent to it
    When I call message-agent to "fa-glm-l"
    Then the tool simply sends each message
    And the recipient's distributor queues and feeds them one at a time (not the sender's concern)
    And no message is dropped or raced by the sending tool

  Scenario: The recipient feeds one message at a time, never concurrent
    Given agent "fa-glm-l" receives N rapid messages from multiple sources
    When the recipient's drain worker processes them
    Then at most ONE prompt runs against the agent at any moment
    And every message is eventually processed (none dropped)
    And ordering is: FIFO by arrival, then all remaining from the same source, then next source

  Scenario: Long job is not cut off (direct mode)
    Given agent "fa-glm-l" is reachable at "sudo-fa-glm-l-mcp:8000"
    When I call message-agent with sibling "fa-glm-l", mode "direct", and a prompt that takes longer than 120s
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
