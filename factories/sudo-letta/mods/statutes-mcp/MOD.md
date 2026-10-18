---
name: "@letta-ai/statutes-mcp"
description: "Agent-callable tools to read the U.S. Code through the project's statutes MCP (OLRC USLM)."
---

# statutes-mcp mod semantics

## When to use

Use `statutes_call` whenever you need to read a U.S. Code section, search the
Code, or resolve a citation. The backing service (`statutes-mcp`, namespace
`dockets`) is a streamable-HTTP MCP server with no auth and no API key.

## Tools

This package registers two tools:

- `statutes_tools()` — list the MCP's tools as `[{name, description}]`.
  Call this FIRST to discover exact names + args.
- `statutes_call(tool, arguments)` — call one MCP tool by name, passing its
  arguments as a JSON object. Returns the tool's text result.

## How it reaches the service

The tools open an MCP streamable-HTTP session against the in-cluster service at
`http://statutes-mcp.dockets.svc:8080/mcp`:

    initialize -> notifications/initialized -> tools/list -> tools/call

No auth, no key.

## Parameters

- `tool` (required string) — exact MCP tool name (from `statutes_tools`).
- `arguments` (optional object) — the tool's arguments as a JSON object, per
  that tool's schema. Omit/empty for tools that take no arguments.

## Important behavior

- `requiresApproval: false`, `parallelSafe: true`.
- The tools never throw: a connection / MCP / tool error is returned as an
  error result with the underlying detail.
- "Repealed" is a REAL answer, not a failure: e.g. `16 U.S.C. 1` returns
  "§ 1. Repealed" because the National Park Service organic act moved to
  Title 54. Do not treat it as a tool error.

## Prerequisite gate

Both tools refuse to run until the `statutes-mcp` skill has been loaded in
the current conversation (the mod observes the `Skill` tool's `tool_start`
event for that name, per conversation, in-memory). Each tool description begins
with `REQUIRES: load the statutes-mcp skill first.` A new conversation starts
blocked again.
