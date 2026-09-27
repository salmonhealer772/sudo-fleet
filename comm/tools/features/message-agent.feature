Feature: Message a sibling agent

  The message-agent tool is the primary way agents in the fleet talk to each
  other. It delivers a prompt to any sibling by name and (optionally) waits
  for that sibling's reply.

  Delivery is no longer direct-to-process. A message flows MCP -> a Redis
  queue in front of the sibling -> the sibling is fed ONE message at a time.
  This is what makes "messaged while busy" safe: messages are held and
  sequenced, never dropped and never raced onto the same agent at once.

  A sibling is addressed by its bare name (the deployment name minus the
  leading "sudo-"; e.g. deployment "sudo-fa-glm-l" -> name "fa-glm-l"). The
  tool reaches the sibling at "http://sudo-{name}-mcp:8000/mcp", performs the
  MCP handshake (initialize), and calls the sibling's prompt tool:
    - a Letta planner exposes "letta_prompt(prompt, stream, json, new_chat)"
    - a Hermes engineer exposes "hermes_prompt(prompt, json)"

  Delivery modes:
    - "direct"  (default): enqueue and WAIT for the reply (synchronous).
    - "inbox": enqueue only; return a message id immediately, do not wait.

  Background:
    Given a running sudo-fleet with at least two agents
    And each agent exposes its "-mcp" service
    And a Redis queue sits in front of each agent's MCP door

  Scenario: Direct message to a planner (default mode)
    Given agent "fa-glm-l" is reachable at "sudo-fa-glm-l-mcp:8000"
    When I call message-agent with sibling "fa-glm-l", prompt "Who are you?", and mode direct
    Then it enqueues the message and waits
    And when the message is fed to the agent it calls letta_prompt with prompt "Who are you?", stream=false, json=false, new_chat=false
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

  Scenario: Inbox mode enqueues and returns a message id without waiting
    Given agent "fa-glm-l" is reachable at "sudo-fa-glm-l-mcp:8000"
    When I call message-agent with sibling "fa-glm-l", prompt "do the thing", and mode inbox
    Then it enqueues the message into the sibling's queue
    And it returns a message id immediately
    And it does NOT wait for the agent to reply

  Scenario: A busy agent queues messages instead of racing them
    Given agent "fa-glm-l" is mid-run on a long prompt
    When three messages are sent to "fa-glm-l" in quick succession
    Then no more than one is fed to the agent at a time
    And the rest are held in the queue until the agent is free

  Scenario: Messages are drained one source at a time (first-in-first, then group-by-source)
    Given agent "fa-glm-l" received a first message from "msg-source-a"
    And more messages from both "msg-source-a" and "msg-source-b"
    When the queue drains
    Then the FIRST message is the first one that arrived
    And after it, every remaining message from "msg-source-a" is fed before any message from "msg-source-b"

  Scenario: When a source is empty, move to the most recent other source
    Given agent "fa-glm-l" finished draining "msg-source-a"
    And the newest remaining message is from "msg-source-c"
    When the queue drains the next message
    Then it feeds "msg-source-c"'s message next

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
