---
name: regulations-mcp
description: Read federal regulations — the codified CFR, the Federal Register, and Regulations.gov dockets/comments — through the regulations MCP. Hermes' native MCP client registers the tools as mcp_regulations_* tools. Load this skill before using them.
---

# regulations-mcp

Read the codified Code of Federal Regulations, search the Federal Register,
and pull Regulations.gov dockets and comments — the three federal-regulation
datasources behind one MCP service. The service is deployed; you never
authenticate it (no key for eCFR + Federal Register). You just call the tools.

## How the tools appear

Hermes' native MCP client connects to the service at startup (via the
`mcp_servers.regulations` entry in your config) and registers every tool with a
`mcp_regulations_` prefix. They are available in every conversation like any
other tool:

- `mcp_regulations_get_cfr_section`
- `mcp_regulations_browse_cfr`
- `mcp_regulations_search_rules`
- `mcp_regulations_get_document`
- `mcp_regulations_list_open_comments`
- `mcp_regulations_get_docket`
- `mcp_regulations_find_comments`

To see the full live list, run `hermes tools` and look for the
`mcp_regulations_*` names.

## The real tool surface (7 tools — verified live against the deployed MCP)

| Tool (drop the `mcp_regulations_` prefix) | Use it for | Required args | Key optional args |
|---|---|---|---|
| `get_cfr_section` | **Read codified text.** One section, a whole part, or an appendix; current or `date` point-in-time. | `title` (int) | `part`, `section`, `appendix`, `date`, `offset`, `max_chars` |
| `browse_cfr` | Walk eCFR structure (`mode:"structure"`) or full-text search the CFR (`mode:"search"`). | `mode` | `title`, `part`, `query`, `date`, `page`, `per_page` |
| `search_rules` | Search the Federal Register (1994–present). | none | `query`, `type`, `agencies`, `published_after`, `published_before`, `cfr_title`, `cfr_part`, `docket_id`, `rin`, `citation`, `citation_date`, `order`, `per_page`, `page` |
| `get_document` | One FR document by FR document number. | `document_number` | `include_full_text`, `offset`, `max_chars` |
| `list_open_comments` | FR documents open for comment, soonest first. Keyless. | none | `query`, `type`, `agencies`, `closing_before`, `per_page`, `page` |
| `get_docket` | Regulations.gov docket + filed documents. **Needs `REGULATIONS_GOV_API_KEY`.** | `docket_id` | `document_types`, `per_page`, `page` |
| `find_comments` | Public comments on a docket/document/FR number. **Needs `REGULATIONS_GOV_API_KEY`.** | none | `docket_id`, `document_object_id`, `fr_document_number`, `comment_id`, `search_term`, `posted_after`, `posted_before`, `per_page`, `page` |

## Worked example — read a CFR section

```text
mcp_regulations_get_cfr_section  title=36 part="251" section="64"
```

Returns the codified text of **36 CFR 251.64** — "Reauthorization of existing
uses". `title` is required; `section` can be written as people cite it (`"64"`,
`"251.64"`, `"§ 251.64"`). Add `date="YYYY-MM-DD"` for point-in-time (eCFR
retains 2017 → today).

## Which tools need a key — fail honestly

Only two tools need `REGULATIONS_GOV_API_KEY`, and it is **not set** in the
deployed service:

- `get_docket` → `auth_required`: `REGULATIONS_GOV_API_KEY is not configured`.
- `find_comments` → same.

Everything else (eCFR reads, Federal Register search/get-document/open-comments)
is keyless and works. Never fabricate a docket or comment result when the call
fails — report the `auth_required` message instead.

## Hard caveat — this MCP is CFR-only (Layer 1)

This MCP does **not** reach agency Manuals/Handbooks — no FSH/FSM, no BLM
Manuals, no NPS Management Policies. **17 of AO's 21 known exposures live in
that Handbook layer, not the CFR** (AO's own count: 17 "Handbook only", 2
Manual, 2 CFR). An agent that stops at the CFR and thinks it found the
authority is the failure mode: 36 CFR 251.64(b) delegates the renewal standard
to "applicable Forest Service directives", and the actual standard sits in
FSH 2709.14 §53.1m — which no regulations MCP can see. For Layers 2–3 use the
agency portals directly (fs.usda.gov Directives, blm.gov/policy, nps.gov
policy); the Handbook/Manual (Layers 2–3) path is not covered by this MCP.

## Troubleshooting

- **Tools missing**: confirm `mcp_servers.regulations` is present in
  `/opt/data/config.yaml` (url `http://regulations-mcp.dockets.svc:8080/mcp`)
  and that the pod can reach `regulations-mcp.dockets.svc:8080`. Restart the
  agent if you just added it.
- **Connection refused**: the `regulations-mcp` deployment is down — check
  `kubectl -n dockets get deploy regulations-mcp` on the cluster.
