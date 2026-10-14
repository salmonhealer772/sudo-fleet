---
name: google-workspace
description: Read and write the operator's Google Drive, Docs and Sheets through the fleet-shared google-workspace MCP service. The operator already authorized once, so you never authenticate — discover the tools, then act. Load this skill before calling google_workspace_tools / google_workspace — they are blocked until it is loaded this conversation.
---

# google-workspace

Read and write the operator's Google Drive, Google Docs, and Google Sheets.
This is the ONE shared Google surface for the whole fleet: the operator has
already done the OAuth consent once, and the shared service holds the token, so
**you never authenticate** — you just name the tool and its arguments.

## The two tools

```python
google_workspace_tools()            # list every available Google tool: [{name, description}]
google_workspace(tool, arguments)   # call one tool by name; arguments is a JSON object
```

Always `google_workspace_tools()` first to discover the exact tool names and
what each takes. Then `google_workspace(name, {...})` to act.

## Common tools (Drive / Docs / Sheets)

The exact list is live — run `google_workspace_tools()` to see it. The surface
is roughly (names may differ slightly — always confirm with the lister):

- **Drive** — search files, read a file's content, create/upload, share, move,
  export Office files, manage folders.
- **Docs** — create a doc, read a doc, insert/replace text, apply styles,
  tables, comments, export.
- **Sheets** — create a spreadsheet, read a range, write a range, batch update,
  formatting, conditional rules.

## Calling pattern

```python
# discover
google_workspace_tools()

# act (arguments is a plain JSON object, per that tool's schema)
google_workspace("search_drive_files", {"query": "name contains 'Q3 report'"})
google_workspace("read_sheet_range", {"spreadsheet_id": "...", "range": "A1:D10"})
google_workspace("write_sheet_range", {"spreadsheet_id": "...", "range": "Sheet1!A1", "values": [["a","b"]]})
```

There is no `auth`, `token`, or `credentials` argument — the shared service
already has the operator's token. Do not invent one.

## When it needs the operator

If a call returns an `ACTION REQUIRED: ... Authorization URL: ...` message, the
operator has not yet completed the one-time consent. Surface that URL to the
operator (do not open it yourself, and do not retry in a loop) and stop.

## Important

- Only Drive, Docs, Sheets exist here. There is no Gmail/Calendar/Slides/Chat
  tool in this service — do not invent one; that is a different surface.
- `requiresApproval: false`, and both tools return errors as results (they
  never throw). Read the error text before retrying.
- If unsure of a tool name, do not guess — `google_workspace_tools()` first.
