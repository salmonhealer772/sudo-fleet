---
name: "@letta-ai/regulations-mcp"
description: "Agent-callable tools to read federal regulations through the project's regulations MCP (eCFR + Federal Register + Regulations.gov)."
---

# regulations-mcp mod semantics

## When to use

Use `regulations_call` whenever you need to read the codified CFR, search the
Federal Register, or pull a Regulations.gov docket/comment. The backing service
(`regulations-mcp`, namespace `dockets`) is a streamable-HTTP MCP server with
no auth for eCFR + Federal Register tools; only the two Regulations.gov tools
need `REGULATIONS_GOV_API_KEY`, and the server says so honestly when it is unset.

## Tools

This package registers two tools:

- `regulations_tools()` — list the MCP's tools as `[{name, description}]`.
  Call this FIRST to discover exact names + args.
- `regulations_call(tool, arguments)` — call one MCP tool by name, passing its
  arguments as a JSON object. Returns the tool's text result.

## How it reaches the service

The tools open an MCP streamable-HTTP session against the in-cluster service at
`http://regulations-mcp.dockets.svc:8080/mcp`:

    initialize -> notifications/initialized -> tools/list -> tools/call

No auth at the agent for eCFR/Federal Register. The two Regulations.gov tools
(`regulations_get_docket`, `regulations_find_comments`) return `auth_required`
until `REGULATIONS_GOV_API_KEY` is configured on the server.

## Parameters

- `tool` (required string) — exact MCP tool name (from `regulations_tools`).
- `arguments` (optional object) — the tool's arguments as a JSON object, per
  that tool's schema. Omit/empty for tools that take no arguments.

## Important behavior

- `requiresApproval: false`, `parallelSafe: true`.
- The tools never throw: a connection / MCP / tool error is returned as an
  error result with the underlying detail.
- The MCP does NOT cover agency Manuals/Handbooks (FSH/FSM, BLM Manuals, NPS
  Policies) — it is CFR + Federal Register + Regulations.gov only. The bulk of
  AO's exposures live in that Handbook layer, not the CFR.

## Prerequisite gate

Both tools refuse to run until the `regulations-mcp` skill has been loaded in
the current conversation (the mod observes the `Skill` tool's `tool_start`
event for that name, per conversation, in-memory). Each tool description begins
with `REQUIRES: load the regulations-mcp skill first.` A new conversation
starts blocked again.
