---
name: toolbox
description: Exact call shapes and worked examples for the talker's four MCP servers (status, dockets, regulations, statutes) and the read-only /opt/dockets filesystem. Load when you need the precise tool names, arguments, or filesystem layout to answer a question.
---

# Toolbox — the exact shapes for my four MCPs and the filesystem

This is the reference I load when I need the precise arguments. The persona's capability map tells me *which* source to use; this file tells me *how* to call it.

## How to call an MCP tool (read this first)

Every MCP tool is called by its **full prefixed name** `mcp__<server>__<tool>`, via Bash:

```
letta mcp call mcp__<server>__<tool> --args '<json>'
```

Examples (real, working):
```
letta mcp call mcp__status__fleet_status --args '{}'
letta mcp call mcp__regulations__regulations_get_cfr_section --args '{"title": 36, "part": 7, "section": "7.99"}'
letta mcp call mcp__dockets__query_sql --args '{"query": "SELECT * FROM dockets LIMIT 5"}'
letta mcp call mcp__statutes__get_by_citation --args '{"citation": "16 USC 6802"}'
```

**Never use the short name** (`fleet_status`, `regulations_get_cfr_section`) — those are the `title` labels, not the call names, and they fail with `tool_not_found`. The call name is always `mcp__<server>__<tool>`. To see a server's tools and their exact names: `letta mcp tools <server>`, and to see one tool's argument schema: `letta mcp schema <tool-name>`.

## Filesystem — /opt/dockets (read-only)

The pipeline output, mounted read-only at `/opt/dockets`. Read it with the `read`/`bash` base tools (e.g. `ls`, `cat`).

Layout:
```
/opt/dockets/
  <docket-id>/                         e.g. NPS-2026-0133
    .docket-context.txt                Title / Agency / Type / RIN / Abstract
    .split-manifest.json               provisions[] = {citation, heading, slug, order, start, end}
    FULLTEXT.txt                       the whole docket text
    <slug>/                            one directory per provision, named by its slug
      provision.txt                    the provision's text
      meta.json                        {docket_id, provision_slug, heading, order, source_line_range}
      concern-<persona>.md             present  => FLAGGED (a concern brief exists)
      regulation.md                    present  => the governing regulation (flagged bundle)
      statute.md                       present  => the governing statute (flagged bundle)
      .no-concern-<persona>            present (0 bytes) => read and NOT a concern
```

The flagged / not-flagged distinction is a filesystem fact, never a guess:
- flagged = a `concern-*.md` file exists in the provision dir.
- not flagged = `.no-concern-*` markers exist.
- unprocessed = neither (no markers and no concern file).

## status MCP — live fleet state

Three tools, all no-arg except `recent_activity`:

- `mcp__status__fleet_status` — roster of every workload across the fleet, each with `name`, `namespace`, `group` (product/data/agents/platform), `ready`, `restarts`, `last_activity`, `last_event`, and a real `health` probe (healthy/degraded/down/unknown). Returns `{agents, count, groups, healthy, degraded, down, source, generated_at}`.
- `mcp__status__pipeline_summary` — `{dockets_total, dockets_flagged, issues_open, issues_done, issues_source, dockets_source}`. Counts of docket dirs, how many are flagged, and Paperclip issue counts (0 + "unavailable" if Paperclip is unreachable).
- `mcp__status__recent_activity` — arg `limit` (default 20, clamped 1..200). Newest-first timeline of recently touched docket dirs/files: `{root, count, items:[{name, path, type, mtime, size}]}`.

Use for "is the pipeline running?", "what's the fleet doing?", "what changed recently?".

## dockets MCP — Spicy Regs dataset (read-only SQL)

Three tools:

- `mcp__dockets__list_sources` — no args. Lists the logical tables in the Spicy Regs R2 dataset.
- `mcp__dockets__describe_table` — arg: the table name. Returns its column schema.
- `mcp__dockets__query_sql` — arg: a SQL query (SELECT only; writes are refused). Always add `LIMIT` on exploratory queries. Returns up to `max_rows` rows.

Use for docket metadata/text not yet under `/opt/dockets`, or to count/filter the source data.

## regulations MCP — Federal Register + eCFR

- `mcp__regulations__regulations_search_rules` — full-text search of the Federal Register (1994–present). Filters: query text, document type, agency slug, published_after/published_before, affected CFR title/part, docket number, RIN. Returns FR document numbers (open each with `regulations_get_document`). A page cite like "89 FR 49102" resolves to the documents on that page.
- `mcp__regulations__regulations_get_document` — arg: FR document number. Full metadata + body. `include_full_text` returns the plain-text body (windowed; page with `offset`, `max_chars` up to 200,000). Also carries the Regulations.gov docket ID and affected CFR parts.
- `mcp__regulations__regulations_get_cfr_section` — read codified CFR text. Args: title + part + section (e.g. title 36, part 7, section "7.99"), or title + part alone (whole part), or title + appendix. Optional `as_of` ISO date for a point-in-time read. Accepts "61", "§ 141.61", "141.61(c)", "40 CFR 141.61".
- `mcp__regulations__regulations_browse_cfr` — mode "structure" lists titles/divisions/sections; mode "search" full-text searches the CFR. Args: title, part.
- `mcp__regulations__regulations_get_docket` — arg: docket_id (e.g. "EPA-HQ-OAR-2025-0194"). Docket metadata + filed documents. Needs REGULATIONS_GOV_API_KEY.
- `mcp__regulations__regulations_find_comments` — public comments. Exactly one target: docket_id, document_object_id, fr_document_number, or comment_id. Needs REGULATIONS_GOV_API_KEY.
- `mcp__regulations__regulations_list_open_comments` — FR documents currently open for comment, soonest first. No key needed.

Use for "what does 36 CFR 7.99 say?", "what's the Federal Register rule behind this citation?".

## statutes MCP — U.S. Code

- `mcp__statutes__get_section` — args: title (number), section (e.g. "6802"), optional `as_of`. Returns citation, title_name, section_title, text, subsections, source_url, references.
- `mcp__statutes__search_code` — args: query (FTS5: `"child tax credit"`, `child AND credit`, `tax*`), limit (1-100), optional title. Returns matches with citation + snippet.
- `mcp__statutes__get_by_citation` — arg: citation ("16 USC 1", "43 USC 1701"), optional as_of.
- `mcp__statutes__list_titles` — no args. Titles present with section counts.
- `mcp__statutes__get_references` — cross-references for one section.

Use for "what does 16 USC 6802 say?", "find the statute that governs X.".
