---
name: download-statute
description: Fetch the full statute text for a citation resolved by find-statute and write it into the provision directory as a .md summary plus a verbatim .txt evidence file.
---

# download-statute.md

**What this file is:** the **fetch skill for statutes**. Given a
citation that `find-statute.md` resolved, it retrieves the full
statute text and writes it into the provision directory as both a
reviewable `.md` summary and a verbatim `.txt` evidence file.

**Backing MCP:** statutes MCP — thin FastMCP wrapper over
`TheAxiomFoundation/axiom-corpus` (5 tools: `get_section`,
`search_code`, `get_by_citation`, `list_titles`, `get_references`).
Deployed in `dockets` namespace, ClusterIP `statutes-mcp:8080`,
endpoint `http://statutes-mcp.dockets.svc.cluster.local:8080/mcp`.
**Owner:** meta-data-agents (shared skill; the persona supplies
the concern).
**Status:** rewritten 2026-10-18 to match the four settled design
decisions. Replaces the 22-line placeholder seed.

---

## 0. The method in one sentence

Call `get_section` on the statutes MCP with the exact
identifier that `find-statute.md` resolved, write the verbatim
text to `<provision-dir>/statute.txt`, and write a structured
summary to `<provision-dir>/statute.md`. If the citation points
to a source the MCP cannot reach (e.g. a state code not in the
corpus), write the gap marker instead (§5).

---

## 1. Input shape

The skill receives a single statute identifier from
`find-statute.md`:

```
citation:     54 U.S.C. 101913        # exact, current
layer:        1 (USC)                  # from find-statute.md §1
title:        54 (National Park Service and Related Programs)
section:      101913
source_url:   https://www.law.cornell.edu/uscode/text/54/101913
as_of:        <USC current-as-of date>
version_note: current (no amendment since last FR notice)
```

If `layer` is **3 (state code or non-federal)**, skip to §5 —
the statutes MCP covers federal USC only.

---

## 2. MCP tool call — the exact recipe

### 2.1 For a known section (layer 1)

```
Tool: get_section
Arguments:
  title:   <title number, e.g. 54>
  section: <section number, e.g. "101913">
  as_of:   <optional ISO date for point-in-time, e.g. "2026-10-13">
```

Returns (structure from the statutes MCP `get_section`):

```json
{
  "citation": "54 U.S.C. 101913",
  "title_name": "National Park Service and Related Programs",
  "section_title": "§ 101913 <section heading>",
  "text": "<full section text>",
  "subsections": [ ... ],
  "source_url": "https://uscode.house.gov/view.xhtml?req=54+USC+101913",
  "retrieved_at": "<ISO timestamp>",
  "references_to": [ ... ],
  "referenced_by": [ ... ]
}
```

### 2.2 For uncertain section numbers

```
Tool: search_code
Arguments:
  query: <search string; FTS5 syntax, e.g. "101913">
  limit: <max results, 1-100, default 10>
  title: <optional title filter, e.g. 54>
```

Returns matching sections with their cites and section numbers.
Use this to discover the correct section number before the
content call in §2.1.

### 2.3 Point-in-time reads

Add `as_of: "YYYY-MM-DD"` to the `get_section` call. The
corpus retains historical versions; dates outside the retained
window are rejected with the window named.

---

## 3. Output contract — TWO files per authority

Write **both** files into `<provision-dir>/` (the directory that
`find-statute.md` handed you):

### 3.1 `<provision-dir>/statute.txt` — verbatim evidence

The full `text` from the MCP, verbatim, UTF-8. No stripping, no
summarisation, no HTML. If `text` exceeds 200,000 characters
(whole title), write the full text and note the truncation in the
`.md` sidecar.

### 3.2 `<provision-dir>/statute.md` — structured summary

```markdown
# statute: <citation>

citation:      <exact citation, e.g. "54 U.S.C. 101913">
layer:         1 (USC)
section_title: <section heading from the MCP `section_title` field>
title_name:    <title name from the MCP `title_name` field, e.g. "National Park Service and Related Programs">
source_url:    <the MCP `source_url` (uscode.house.gov view URL)>
as_of:        <date of the USC read>
version_note: <current-amendment note or supersession info>
ocr_flag:     false
excerpt:      <first 700 characters of text, trimmed, no trailing ellipsis>

<full text verbatim — or, if text is too long for the .md,
include the first 2,000 chars here and point to statute.txt for the
full text>
```

**Field names match `lookup_authority.py`** (`citation`,
`section_title`, `title_name`, `source_url`) so the agent path
and the script path produce interchangeable artifacts.

### 3.3 Multiple authorities

If `find-statute.md` returned more than one citation, suffix the files
with the citation slug: `statute-101913.txt` / `statute-101913.md`,
`statute-101914.txt` / `statute-101914.md`, etc. Use the citation slug
(e.g. `101913`) as the suffix — never a bare sequential number — so the
file is self-describing. One consistent rule, applied identically to the
regulation side.

---

## 4. Script contract (for `process-docket.sh` and `lookup_authority.py`)

This subsection documents the exact handoff so the pipeline script
can follow it mechanically.

### 4.1 MCP tool name and arguments

| Field | Value |
|---|---|
| Tool | `get_section` |
| `title` | int, e.g. `54` |
| `section` | string, e.g. `"101913"` |
| `as_of` | optional ISO date string |

### 4.2 Output paths

| Path | Content |
|---|---|
| `<provision-dir>/statute.txt` | Full verbatim `text` |
| `<provision-dir>/statute.md` | Structured summary with excerpt |

### 4.3 Known divergence from `lookup_authority.py`

`lookup_authority.py` currently writes **only** a `.md` file with
an excerpt (700 chars) and does **not** produce a `.txt` file with
the full verbatim text. This is a known divergence from this spec.
The script follows the older contract; the skill is the spec. Fix
`lookup_authority.py` to also write `<provision-dir>/statute.txt`
with the full `text` in a future iteration — do not silently match
the script gap.

---

## 5. State codes / non-federal — honest gap marker

**The statutes MCP covers federal USC only.** When
`find-statute.md` returns a state code citation (layer 3), this
skill writes a `statute.md` that says explicitly:

```markdown
# statute: <citation>

citation:     <exact citation, e.g. "Cal. Civ. Code § 1714">
layer:        3 (state code)
jurisdiction: California
source_url:   https://leginfo.legislature.ca.gov/ (or the relevant state site)
version_note: state code; verify against the current session law
ocr_flag:     false

---

**NOT INCLUDED IN THIS BUNDLE — human action required**

This provision exists in a state code and cannot be fetched
automatically. The statutes MCP covers federal USC only. Look it
up by hand at the relevant state legislative site and paste the
text into the provision directory manually.
```

**Do not web-scrape it.** A scraped page with no provenance in a
legal bundle is worse than an honest gap. The marker must be loud
enough that a reviewer cannot mistake it for a result.

---

## 6. Failure modes

| Failure | What to do |
|---|---|
| MCP returns `isError: true` or `McpUnavailable` | Write `statute.md` with a `DEPENDENCY MISSING` marker and the citation. Exit non-zero. |
| `text` is empty or null | Write `statute.md` with a `NO TEXT RETURNED` marker. Do not write an empty `.txt`. |
| Citation is a point-in-time date outside the corpus window | Note `version_note: "date outside corpus retained window — verify against session law"` and proceed with the current version text. |
| The statute is a session law (not yet codified) | `source_url` will point to the FR notice or session law. Fetch the session law text via `search_code` and include it in `statute.txt`. |
| Multiple sections in one title requested | Fetch each section individually; concatenate in `statute.txt` with `===== SECTION <cite> =====` delimiters. |

---

## 7. Boundary

- **In scope:** the section text, its title name, its source credit,
  and its parent chapter/part where the tool returns it.
- **Out of scope:** the parent public law, the amending act,
  legislative history. That is research, not fetch. If an agent
  concludes it needs the underlying act, that is another run of
  `find-statute.md`, not an expansion of this skill.
- **Not a search skill:** `find-statute.md` locates; this skill
  fetches. Do not call `search_code` to *find* a section — use it
  only to *discover* the correct section number when the identifier
  is uncertain (§2.2).

---

## 8. References

- `find-statute.md` — the matching locate skill; the identifier
  this skill consumes is what `find-statute.md` emits.
- `../architecture/ops-mds.md` line 55 (defines this file: fetch
  the located statute(s) into the provisions directory; backed by
  the statutes MCP; owner = meta-data-agents).
- `../../Project-Overview.txt` line 53 (find-* skills LOCATE the
  authority; matching download skills FETCH it and place it in the
  provision directory).
- `lookup_authority.py` — the pipeline script that does a version
  of this authority lookup; the script contract in §4 documents the
  handoff so the agent path and the script path agree.
- `TheAxiomFoundation/axiom-corpus` (pinned SHA
  `c4943e087b38888d6a3c0b9f3351e30bf5798eef`) — the backing corpus +
  REST API; `containerize/dockets/statutes-mcp/mcp_server.py` is the thin
  FastMCP wrapper over it. Corpus DB required (built by `ingest2.py` from
  official OLRC USLM XML).
