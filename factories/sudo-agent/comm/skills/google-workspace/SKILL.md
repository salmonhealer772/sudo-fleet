---
name: google-workspace
description: Read and write the operator's Google Drive, Docs and Sheets through the fleet-shared google-workspace MCP service. The operator already authorized once, so you never authenticate — the tools appear as mcp_google_workspace_* tools. Load this skill before using them.
---

# google-workspace

Read and write the operator's Google Drive, Google Docs, and Google Sheets.
This is the ONE shared Google surface for the whole fleet: the operator did the
OAuth consent once, and the shared service (`sudo-gws`) holds the token — so
**you never authenticate**, you just call the tools.

## How the tools appear

Hermes' native MCP client connects to the shared service at startup (via the
`mcp_servers.google_workspace` entry in your config) and registers every Google
tool with a `mcp_google_workspace_` prefix. The tools are available in every
conversation like any other tool — e.g.:

- `mcp_google_workspace_search_drive_files`
- `mcp_google_workspace_read_drive_file`
- `mcp_google_workspace_create_google_doc`
- `mcp_google_workspace_read_document`
- `mcp_google_workspace_write_sheet_range`
- `mcp_google_workspace_read_sheet_range`

To see the full live list, run `hermes tools` and look for the
`mcp_google_workspace_*` names (or just call the one you need — the schemas are
the standard Google Workspace tool schemas).

## What you can do

- **Drive** — search files, read file content, create/upload, share, move,
  export, manage folders.
- **Docs** — create a doc, read a doc, edit text, styles, tables, comments,
  export.
- **Sheets** — create a spreadsheet, read/write ranges, batch updates,
  formatting, conditional rules.

Only Drive, Docs and Sheets exist in this service. There is no
Gmail/Calendar/Slides/Chat tool here — do not invent one; that is a different
surface.

## Calling pattern

There is no auth/token/credentials argument — the shared service already has
the operator's token. Call the tool with only its own arguments:

```text
mcp_google_workspace_search_drive_files  query="name contains 'Q3 report'"
mcp_google_workspace_read_sheet_range    spreadsheet_id="..." range="A1:D10"
```

## When it needs the operator

If a call returns an `ACTION REQUIRED: ... Authorization URL: ...` message, the
operator has not yet completed the one-time consent. Surface that URL to the
operator (do not open it yourself, and do not retry in a loop) and stop.

## Troubleshooting

- **Tools missing**: confirm `mcp_servers.google_workspace` is present in
  `/opt/data/config.yaml` and that the pod can reach
  `http://192.0.2.15:27462/health`. Restart the agent if you just added it.
- **Connection refused**: the `sudo-gws` service is down — bring it up with
  `bash /opt/0-0/sudo-fleet/factories/sudo-gws/kube-scripts/up.sh` on the host.
