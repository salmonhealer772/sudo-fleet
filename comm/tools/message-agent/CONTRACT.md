# message-agent — tool contract

**The most important tool in the communication layer.** Message any sibling agent by name and get its reply, via the sibling's `-mcp` service.

## Contract

- **Inputs:** `sibling` (agent name, e.g. `fa-glm-l` / `ms-glm-l`), `prompt` (the message), optional `new_chat` (bool, default false).
- **Behavior:** reach `http://sudo-{sibling}-mcp:8000/mcp` → MCP `initialize` → `tools/call` the sibling's prompt tool (`letta_prompt` for Letta planners, `hermes_prompt` for Hermes engineers) with `prompt` → return the reply string.
- **Session semantics:** planner sibling = stateful (resumes its persisted conversation unless `new_chat=true`); engineer sibling = stateless one-shot.
- **No-timeout:** long jobs must not be cut (`HERMES_STREAM_*_TIMEOUT=inf` equivalent on the call path).

## Backend

Undecided (operator: "shit idk") — shell script vs. Letta mod tool. forge decides during build; this file pins the contract only.
