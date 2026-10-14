---
name: "@letta-ai/google-workspace"
description: "Agent-callable tools to read and write the operator's Google Drive, Docs and Sheets through the fleet-shared google-workspace MCP service."
---

# google-workspace mod semantics

## When to use

Use `google_workspace` whenever you need to read or write the operator's Google
Drive, Google Docs, or Google Sheets. The operator has done the OAuth consent
once; the shared service holds the token, so you never authenticate — you just
name the tool and its arguments.

## Tools

This package registers two tools:

- `google_workspace_tools()` — list the available Google tools as
  `[{name, description}]`. Call this FIRST to discover exact names + args.
- `google_workspace(tool, arguments)` — call one tool by name, passing its
  arguments as a JSON object. Returns the tool's text result.

Only Drive, Docs and Sheets are exposed (the service runs
`--tools drive docs sheets`). Gmail/Calendar/Slides/Chat/Forms/Tasks/etc. are
never registered.

## How it reaches the service

The tools open an MCP streamable-HTTP session against the fleet-shared
service at the baked deterministic address `http://192.0.2.15:27462/mcp`
(`27462 = 8000 + cksum("gws") % 22000`, the fleet MCP_PORT convention):

    initialize -> notifications/initialized -> tools/list -> tools/call

There is no auth step at the agent: the service's PVC already holds the
operator's refresh token (legacy OAuth 2.0 single-user).

## Parameters

- `tool` (required string) — exact tool name (from `google_workspace_tools`).
- `arguments` (optional object) — the tool's arguments as a JSON object, per
  that tool's schema. Omit/empty for tools that take no arguments.

## Important behavior

- `requiresApproval: false`, `parallelSafe: true`.
- The tools never throw: a connection / MCP / tool error is returned as an
  error result with the underlying detail.
- If the operator has not yet completed the one-time consent, `google_workspace`
  returns the service's `ACTION REQUIRED: ... Authorization URL: ...` message —
  surface that URL to the operator rather than retrying.

## Prerequisite gate

Both tools refuse to run until the `google-workspace` skill has been loaded in
the current conversation (the mod observes the `Skill` tool's `tool_start`
event for that name, per conversation, in-memory). Each tool description begins
with `REQUIRES: load the google-workspace skill first.` A new conversation
starts blocked again.
