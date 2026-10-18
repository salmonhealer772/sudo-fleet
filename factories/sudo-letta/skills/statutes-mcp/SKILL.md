---
name: statutes-mcp
description: Read the U.S. Code (OLRC USLM) through the statutes-mcp MCP at statutes-mcp.dockets.svc:8080/mcp. Load this skill before calling statutes_tools / statutes_call — they are blocked until it is loaded this conversation.
---

# statutes-mcp

Read the U.S. Code — the codified statutes of the United States, parsed from
the official Office of the Law Revision Counsel USLM XML. The service is
deployed; you never install or authenticate it. You just name the tool and its
arguments.

## The two tools

```text
statutes_tools()             # list every available MCP tool: [{name, description}]
statutes_call(tool, arguments)  # call one MCP tool by name; arguments is a JSON object
```

Always `statutes_tools()` first to discover the exact tool names. Then
`statutes_call(name, {...})` to act.

## The real tool surface (5 tools — verified live against the deployed MCP)

| Tool | Use it for | Required args | Optional args |
|---|---|---|---|
| `get_section` | **Fetch one section** by title + section number. | `title` (int), `section` (string) | `as_of` |
| `get_by_citation` | Fetch a section from a free-form citation string. | `citation` | `as_of` |
| `search_code` | Full-text search across the Code (FTS5: `"child tax credit"`, `child AND credit`, `tax*`). | `query` | `limit` (int), `title` |
| `get_references` | Cross-references for one section (what it cites / what cites it). | `title` (int), `section` (string) | none |
| `list_titles` | List the U.S. Code titles in the corpus with section counts. | none | none |

## Worked example — read a section

```text
statutes_call("get_section", {"title": 54, "section": "101913"})
```

Returns **54 U.S.C. 101913 — "Award of concession contracts"** (National Park
Service and Related Programs), with its citation, section title, and full text.
`get_by_citation` with `{"citation": "54 USC 101913"}` returns the same section.
`search_code` with `{"query": "advisory council", "limit": 3}` returns ranked
hits with highlighted snippets.

## Honest behaviour — "repealed" is a real answer

**16 U.S.C. 1 returns "§ 1. Repealed. Pub. L. 113-287, § 7, Dec. 19, 2014,
128 Stat. 3272."** This is correct, not a tool failure: the National Park
Service organic act moved to Title 54 (Pub. L. 113-287 recodified it). When a
section comes back "Repealed", that IS the answer — look for the recodified
home (e.g. the NPS organic act is now 54 U.S.C. 100101 et seq.) rather than
treating it as an error or guessing.

## Important

- If unsure of a tool name, do not guess — `statutes_tools()` first.
- The tools never throw; a connection/MCP/tool error comes back as an error
  result. Read the error text before retrying.
- No auth, no API key.
- Service address: `http://statutes-mcp.dockets.svc:8080/mcp` (streamable
  HTTP, ClusterIP in the `dockets` namespace). The mod already points at it;
  you do not pass a URL.
- A brand-new act may postdate the corpus's release point (currently around
  PL 119-121, 2026-10-09); flag and resolve such citations separately.
