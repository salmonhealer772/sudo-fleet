---
name: download-regulation
description: Fetch the full regulation text for a citation resolved by find-regulation and write it into the provision directory as a .md summary plus a verbatim .txt evidence file.
---

# download-regulation.md

**What this file is:** the **fetch skill for regulations**. Given a citation
that `find-regulation.md` resolved, it retrieves the full regulation text
and writes it into the provision directory as both a reviewable `.md` summary
and a verbatim `.txt` evidence file.

**Backing MCP:** regulations MCP — `cyanheads/federal-regulations-mcp-server`
(7 tools, eCFR/FR/Regulations.gov). Deployed in `dockets` namespace,
ClusterIP `regulations-mcp:8080`, endpoint
`http://regulations-mcp.dockets.svc.cluster.local:8080/mcp`.
**Owner:** meta-data-agents (shared skill; the persona supplies the concern).
**Status:** rewritten 2026-10-18 to match the four settled design decisions.
Replaces the 22-line placeholder seed.

---

## 0. The method in one sentence

Call `regulations_get_cfr_section` (or `regulations_browse_cfr` for the
part-level view) on the regulations MCP, write the verbatim text to
`<provision-dir>/regulation.txt`, and write a structured summary to
`<provision-dir>/regulation.md`. If the citation points to a Manual or
Handbook that no MCP can reach, write the gap marker instead (§5).

---

## 1. Input shape

The skill receives a single regulation identifier from `find-regulation.md`:

```
citation:     36 CFR 251.64(b)       # exact, current-amendment
layer:        1 (CFR)                # from find-regulation.md §1
agency:       USFS
source_url:   https://www.ecfr.gov/current/title-36/.../part-251/subpart-B
as_of:        <eCFR current-as-of date>
version_note: current (no superseding amendment)
```

If `layer` is **3 (Handbook only)**, skip to §5 — no MCP can fetch it.

---

## 2. MCP tool call — the exact recipe

### 2.1 For a CFR section (layer 1)

```
Tool: regulations_get_cfr_section
Arguments:
  title:  <title number from citation, e.g. 36>
  part:   <part number, e.g. "251">
  section: <section number, e.g. "251.64">
  date:   <optional ISO date for point-in-time, e.g. "2026-10-18">
  max_chars: 200000
```

Returns (verbatim from the live MCP `structuredContent`, 2026-10-18):

```json
{
  "cfrCite": "36 CFR 251.64",
  "title": 36,
  "part": "251",
  "section": "251.64",
  "appendix": null,
  "heading": "§ 251.64 Reauthorization of existing uses.",
  "hierarchyPath": "Title 36 › Chapter II › Part 251 › Subpart B › § 251.64",
  "date": "2026-10-13",
  "source": "live",
  "bodyText": "<full section text>",
  "bodyTextOffset": 0,
  "bodyTextLength": 1538
}
```

`bodyTextLength` is the **total** section length, not the returned window.
`bodyTextNextOffset` is present **only when the section is truncated** by
`max_chars`; pass it as `offset` on the next call to page forward. On a full
(untruncated) read the field is **absent** — do not assume `1538`.

There is **no** separate `sourceNote` field — the Federal Register source
credit (e.g. `[88 FR 84709, Dec. 6, 2023]`) is the final line of `bodyText`.

### 2.2 For a whole part or subpart (when the section number is uncertain)

```
Tool: regulations_browse_cfr
Arguments:
  mode: "structure"
  title: <title number>
  part:  <part number>
```

Returns every section and appendix in the part, paged. Use this to discover
the correct section number before the content call in §2.1.

### 2.3 Point-in-time reads

Add `date: "YYYY-MM-DD"` to the `regulations_get_cfr_section` call.
eCFR retains 2017 → today; dates outside the window are rejected with the
window named.

---

## 3. Output contract — TWO files per authority

Write **both** files into `<provision-dir>/` (the directory that
`find-regulation.md` handed you):

### 3.1 `<provision-dir>/regulation.txt` — verbatim evidence

The full `bodyText` from the MCP, verbatim, UTF-8. No stripping, no
summarisation, no HTML. If `bodyText` exceeds 200,000 characters (whole
part), write the full text and note the truncation in the `.md` sidecar.

### 3.2 `<provision-dir>/regulation.md` — structured summary

```markdown
# regulation: <citation>

citation:      <exact citation, e.g. "36 CFR 251.64(b)">
layer:         1 (CFR)
agency:        <agency from find-regulation.md>
section_title: <section heading, from the MCP `heading` field>
title_name:    <CFR title name, e.g. "Parks, Forests, and Public Property" for Title 36>
source_url:    <eCFR URL or FR source note URL>
as_of:        <date of the eCFR read>
version_note: <current-amendment note or supersession info>
ocr_flag:     false
excerpt:      <first 700 characters of bodyText, trimmed, no trailing ellipsis>

<full bodyText verbatim — or, if bodyText is too long for the .md,
include the first 2,000 chars here and point to regulation.txt for the
full text>
```

**Field names match `lookup_authority.py`** (`citation`, `section_title`,
`title_name`, `source_url`) so the agent path and the script path produce
interchangeable artifacts. Mapping: the regulations MCP returns the section
heading as `heading` (→ `section_title`), and does **not** return `title_name`
or `source_url` directly — derive `title_name` from the CFR title (e.g. via
`regulations_browse_cfr` `structure` mode) and construct `source_url` from
the citation.

### 3.3 Multiple authorities

If `find-regulation.md` returned more than one citation, suffix the files
with the citation slug: `regulation-251.64.txt` / `regulation-251.64.md`,
`regulation-251.65.txt` / `regulation-251.65.md`, etc. Use the citation
slug (e.g. `251.64`) as the suffix — never a bare sequential number — so
the file is self-describing. One consistent rule, applied identically to
the statute side.

---

## 4. Script contract (for `process-docket.sh` and `lookup_authority.py`)

This subsection documents the exact handoff so the pipeline script can
follow it mechanically.

### 4.1 MCP tool name and arguments

| Field | Value |
|---|---|
| Tool | `regulations_get_cfr_section` |
| `title` | int, e.g. `36` |
| `part` | string, e.g. `"251"` |
| `section` | string, e.g. `"251.64"` |
| `date` | optional ISO date string |
| `max_chars` | int, 1–200,000, default `64,000` |

### 4.2 Output paths

| Path | Content |
|---|---|
| `<provision-dir>/regulation.txt` | Full verbatim `bodyText` |
| `<provision-dir>/regulation.md` | Structured summary with excerpt |

### 4.3 Known divergence from `lookup_authority.py`

`lookup_authority.py` currently writes **only** a `.md` file with an excerpt
(700 chars) and does **not** produce a `.txt` file with the full verbatim
text. This is a known divergence from this spec. The script follows the
older contract; the skill is the spec. Fix `lookup_authority.py` to also
write `<provision-dir>/regulation.txt` with the full `bodyText` in a future
iteration — do not silently match the script gap.

Second divergence — field mapping: `lookup_authority.py`'s regulation branch
reads the section text from `text`/`content`/`body` and the cite from
`cfrCite`, but the regulations MCP returns the clean text in
`structuredContent.bodyText` and the cite in `structuredContent.cfrCite`
(the `content[0].text` is a markdown wrapper, not the payload). As written the
script captures the markdown wrapper rather than `bodyText`, and falls back to
the candidate citation instead of the MCP's `cfrCite`. This file documents the
correct `bodyText`/`cfrCite` shape; do not bend the spec to the script's field
guesses.

---

## 5. Manuals/Handbooks — honest gap marker

**No MCP reaches agency directives (FSH/FSM, BLM Manuals, NPS Policies).**
17 of AO's 21 known exposures live there, so when `find-regulation.md`
returns a Handbook citation (layer 3), this skill writes a
`regulation.md` that says explicitly:

```markdown
# regulation: <citation>

citation:     <exact citation, e.g. "FSH 2709.14 ch 50 §53.1m">
layer:        3 (Handbook only)
agency:       USFS
source_url:   https://www.fs.usda.gov/cgi-bin/Directives/ (series 2700)
amendment:    <amendment number and effective date, if known>
version_note: cite to the amendment; earlier pulls are superseded
ocr_flag:     false

---

**NOT INCLUDED IN THIS BUNDLE — human action required**

This provision exists only in a USFS Handbook/Directive (FSH 2709.14,
series 2700) and cannot be fetched automatically. No MCP covers agency
directives. Look it up by hand at the agency directive portal and paste
the text into the provision directory manually.
```

**Do not web-scrape it.** A scraped page with no provenance in a legal
bundle is worse than an honest gap. The marker must be loud enough that a
reviewer cannot mistake it for a result.

---

## 6. Failure modes

| Failure | What to do |
|---|---|
| MCP returns `isError: true` or `McpUnavailable` | Write `regulation.md` with a `DEPENDENCY MISSING` marker and the citation. Exit non-zero. |
| `bodyText` is empty or null | Write `regulation.md` with a `NO TEXT RETURNED` marker. Do not write an empty `.txt`. |
| Citation is a point-in-time date outside the eCFR window | Note `version_note: "date outside eCFR retained window — verify against FR"` and proceed with the current-amendment text. |
| The regulation is a proposed rule (not yet codified) | It has no eCFR `bodyText`; the FR notice is the source. Fetch the notice text via `regulations_get_document` and include it in `regulation.txt`. |
| Multiple sections in one part requested | Fetch each section individually; concatenate in `regulation.txt` with `===== SECTION <cite> =====` delimiters. |

---

## 7. Boundary

- **In scope:** the section text, its heading, its source credit, and its
  parent chapter/part where the tool returns it.
- **Out of scope:** the parent public law, the amending act, legislative
  history. That is research, not fetch. If an agent concludes it needs the
  underlying act, that is another run of `find-statute.md`, not an expansion
  of this skill.
- **Not a search skill:** `find-regulation.md` locates; this skill fetches.
  Do not call `regulations_search_rules` or `regulations_browse_cfr` to
  *find* a section — use them only to *discover* the correct section number
  when the identifier is uncertain (§2.2).

---

## 8. References

- `find-regulation.md` — the matching locate skill; the identifier this
  skill consumes is what `find-regulation.md` emits.
- `../architecture/ops-mds.md` line 55 (defines this file: fetch the
  located regulation(s) into the provisions directory; backed by the
  regulations MCP; owner = meta-data-agents).
- `../../Project-Overview.txt` line 53 (find-* skills LOCATE the authority;
  matching download skills FETCH it and place it in the provision directory).
- `lookup_authority.py` — the pipeline script that does a version of this
  authority lookup; the script contract in §4 documents the handoff so the
  agent path and the script path agree.
- `cyanheads/federal-regulations-mcp-server` (pinned commit
  `672cd269e6b2d1b10a31e83ae9414a6532396042`, v0.5.3) — the backing MCP.
