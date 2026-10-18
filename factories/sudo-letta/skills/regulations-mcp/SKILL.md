---
name: regulations-mcp
description: Read federal regulations — the codified CFR, the Federal Register, and Regulations.gov dockets/comments — through the regulations-mcp MCP at regulations-mcp.dockets.svc:8080/mcp. Load this skill before calling regulations_tools / regulations_call — they are blocked until it is loaded this conversation.
---

# regulations-mcp

Read the codified Code of Federal Regulations, search the Federal Register,
and pull Regulations.gov dockets and comments — the three federal-regulation
datasources behind one MCP service. The service is already deployed; you never
install or authenticate it. You just name the tool and its arguments.

## The two tools

```text
regulations_tools()             # list every available MCP tool: [{name, description}]
regulations_call(tool, arguments)  # call one MCP tool by name; arguments is a JSON object
```

Always `regulations_tools()` first to discover the exact tool names and what
each takes. Then `regulations_call(name, {...})` to act.

## The real tool surface (7 tools — verified live against the deployed MCP)

These are the only names that exist; anything else is a guess. Call them with
`regulations_call(name, {args})`.

| Tool | Use it for | Required args | Key optional args |
|---|---|---|---|
| `regulations_get_cfr_section` | **Read codified text.** One section, a whole part, or an appendix; current or `date` point-in-time. | `title` (int) | `part`, `section`, `appendix`, `date`, `offset`, `max_chars` |
| `regulations_browse_cfr` | Walk eCFR structure (`mode:"structure"`) or full-text search the CFR (`mode:"search"`). | `mode` | `title`, `part`, `query`, `date`, `page`, `per_page` |
| `regulations_search_rules` | Search the Federal Register (1994–present): query, type, agency, date window, CFR title/part, docket, RIN, or FR cite. | none | `query`, `type`, `agencies`, `published_after`, `published_before`, `cfr_title`, `cfr_part`, `docket_id`, `rin`, `citation`, `citation_date`, `order`, `per_page`, `page` |
| `regulations_get_document` | One FR document by its FR document number → metadata + cross-source handles. | `document_number` | `include_full_text`, `offset`, `max_chars` |
| `regulations_list_open_comments` | FR documents open for comment, soonest closing first. Keyless. | none | `query`, `type`, `agencies`, `closing_before`, `per_page`, `page` |
| `regulations_get_docket` | Regulations.gov docket + its filed documents. **Needs `REGULATIONS_GOV_API_KEY`.** | `docket_id` | `document_types`, `per_page`, `page` |
| `regulations_find_comments` | Public comments on a docket/document/FR number. **Needs `REGULATIONS_GOV_API_KEY`.** | none | `docket_id`, `document_object_id`, `fr_document_number`, `comment_id`, `search_term`, `posted_after`, `posted_before`, `per_page`, `page` |

## Worked example — read a CFR section

```text
regulations_call("regulations_get_cfr_section", {"title": 36, "part": "251", "section": "64"})
```

Returns the codified text of **36 CFR 251.64** — "Reauthorization of existing
uses" — with its heading, hierarchy path, body text, and FR source note.
`title` is required; `section` can be written as people cite it (`"64"`,
`"251.64"`, `"§ 251.64"`). Add `"date": "YYYY-MM-DD"` for point-in-time
(eCFR retains 2017 → today).

## Which tools need a key — fail honestly

Only two tools need `REGULATIONS_GOV_API_KEY`, and it is **not set** in the
deployed service:

- `regulations_get_docket` — returns `auth_required`: `REGULATIONS_GOV_API_KEY is not configured`.
- `regulations_find_comments` — same.

Everything else (eCFR reads, Federal Register search/get-document/open-comments)
is **keyless** and works. Do not plan a comment pull through the two keyed
tools unless the key has been configured on the server; and never fabricate a
docket or comment result when the call fails — report the `auth_required`
message instead.

## Hard caveat — this MCP is CFR-only (Layer 1)

This MCP does **not** reach agency Manuals/Handbooks — no FSH/FSM, no BLM
Manuals, no NPS Management Policies. It knows the CFR, the Federal Register,
and Regulations.gov, and nothing else. **17 of AO's 21 known exposures live in
that Handbook layer, not the CFR** (AO's own count: 17 "Handbook only", 2
Manual, 2 CFR). An agent that stops at the CFR and thinks it found the
authority is the failure mode: 36 CFR 251.64(b) delegates the renewal standard
to "applicable Forest Service directives", and the actual standard sits in
FSH 2709.14 §53.1m — which no regulations MCP can see. For Layers 2–3 use the
agency portals directly (fs.usda.gov Directives, blm.gov/policy, nps.gov
policy); see the project skill `find-regulation.md` for that path.

## Important

- If unsure of a tool name, do not guess — `regulations_tools()` first.
- The tools never throw; a connection/MCP/tool error comes back as an error
  result. Read the error text before retrying.
- Service address: `http://regulations-mcp.dockets.svc:8080/mcp` (streamable
  HTTP, ClusterIP in the `dockets` namespace). The mod already points at it;
  you do not pass a URL.
