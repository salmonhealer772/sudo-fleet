---
name: statutes-mcp
description: Read the U.S. Code (OLRC USLM) through the statutes MCP. Hermes' native MCP client registers the tools as mcp_statutes_* tools. Load this skill before using them.
---

# statutes-mcp

Read the U.S. Code — the codified statutes of the United States, parsed from
the official Office of the Law Revision Counsel USLM XML. The service is
deployed; you never authenticate it (no key). You just call the tools.

## How the tools appear

Hermes' native MCP client connects to the service at startup (via the
`mcp_servers.statutes` entry in your config) and registers every tool with a
`mcp_statutes_` prefix:

- `mcp_statutes_get_section`
- `mcp_statutes_get_by_citation`
- `mcp_statutes_search_code`
- `mcp_statutes_get_references`
- `mcp_statutes_list_titles`

To see the full live list, run `hermes tools` and look for the
`mcp_statutes_*` names.

## The real tool surface (5 tools — verified live against the deployed MCP)

| Tool (drop the `mcp_statutes_` prefix) | Use it for | Required args | Optional args |
|---|---|---|---|
| `get_section` | **Fetch one section** by title + section number. | `title` (int), `section` (string) | `as_of` |
| `get_by_citation` | Fetch a section from a free-form citation string. | `citation` | `as_of` |
| `search_code` | Full-text search across the Code (FTS5: `"child tax credit"`, `child AND credit`, `tax*`). | `query` | `limit` (int), `title` |
| `get_references` | Cross-references for one section (what it cites / what cites it). | `title` (int), `section` (string) | none |
| `list_titles` | List the U.S. Code titles in the corpus with section counts. | none | none |

## Worked example — read a section

```text
mcp_statutes_get_section  title=54 section="101913"
```

Returns **54 U.S.C. 101913 — "Award of concession contracts"** (National Park
Service and Related Programs), with citation, section title, and full text.
`get_by_citation` with `citation="54 USC 101913"` returns the same section.
`search_code` with `query="advisory council" limit=3` returns ranked hits.

## Honest behaviour — "repealed" is a real answer

**16 U.S.C. 1 returns "§ 1. Repealed. Pub. L. 113-287, § 7, Dec. 19, 2014,
128 Stat. 3272."** This is correct, not a tool failure: the National Park
Service organic act moved to Title 54. When a section comes back "Repealed",
that IS the answer — look for the recodified home (NPS organic act is now
54 U.S.C. 100101 et seq.) rather than treating it as an error or guessing.

## Important

- No auth, no API key.
- A brand-new act may postdate the corpus's release point (currently around
  PL 119-121, 2026-10-09); flag and resolve such citations separately.

## Troubleshooting

- **Tools missing**: confirm `mcp_servers.statutes` is present in
  `/opt/data/config.yaml` (url `http://statutes-mcp.dockets.svc:8080/mcp`) and
  that the pod can reach `statutes-mcp.dockets.svc:8080`. Restart the agent if
  you just added it.
- **Connection refused**: the `statutes-mcp` deployment is down — check
  `kubectl -n dockets get deploy statutes-mcp` on the cluster.
