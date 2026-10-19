---
name: find-regulation
description: Locate the governing CFR / Federal Register / agency-directive authority for a flagged provision via the regulations MCP (mcp_regulations_* tools). LOCATES only; download-regulation fetches.
---

# find-regulation.md

---

> ## ✅ STATUS: TOOL SURFACE RECONCILED AGAINST THE LIVE MCP (2026-10-18)
>
> **The backing MCP is now deployed and was called for real.** Every tool name, parameter name,
> required arg, and error behaviour in §0 and §3 comes from a live `tools/list` and live
> `tools/call` against `regulations-mcp` in the `dockets` namespace — not from a repo read.
>
> **What is still first-draft, and why:**
>
> - **The Layer 2/3 path (§4) is still a manual pull.** There is no MCP behind the agency
>   directive portals (FSH/FSM, BLM Manuals, NPS Policies). §4 is the human method, reconstructed
>   from AO's source list — it has not been walked end to end in this session.
> - **The §6 → `download-regulation.md` handoff is unverified.** The identifier this skill emits
>   has not been run through the matching download skill against a real docket.
> - **No end-to-end dry run on a live AO docket yet.** Run it once and correct this file wherever
>   the real behaviour differs.
>
> Treat this as the method document with a verified tool layer; the pipeline wiring is still ahead.

---
**What this file is:** the **locate skill, regulations half**. Given a flagged docket
provision, it resolves **which regulation(s) govern it** — the CFR part/section AND the
agency Manual/Handbook provisions — and hands the identifier(s) to `download-regulation.md`,
which fetches the text. **Locate only. Never download.** If a provision implicates a
statute (EXPLORE Act, FLREA, Wilderness Act, FLPMA, 54 U.S.C. §101913, ...), that is
`find-statute.md`, not this skill.

**Tool layer:** the mechanical "what to call, with what args" reference is
`regulations-mcp.md` (this dir) — the exact tool names, arguments, worked example,
and the `REGULATIONS_GOV_API_KEY` behaviour, reconciled against the live MCP
(2026-10-18). Read it for the call surface; this file is the method.

**Owner:** all meta-data-agents (shared skill; the persona supplies the concern).
Canonical name: `find-regulation.md` (singular). The split is fixed: `find-*` locate,
`download-*` fetch. Locate first, then fetch — always in that order.

---

## 0. Backing MCP — DEPLOYED and measured (2026-10-18)

The project's regulations MCP is **`cyanheads/federal-regulations-mcp-server`** (Apache-2.0,
replacing the earlier `1102tools-dev/federal-contracting-mcps` pick). It is **running** in the
`dockets` namespace on the sudo-fleet k3s box and was called for real while writing this file:

| | |
|---|---|
| Repo | `cyanheads/federal-regulations-mcp-server` |
| **Pinned commit** | `672cd269e6b2d1b10a31e83ae9414a6532396042` (v0.5.3) |
| Image | `regulations-mcp:latest` — built locally, side-loaded into k3s containerd (no registry) |
| Pod / service | `deploy/regulations-mcp` → ClusterIP `regulations-mcp:8080` |
| Endpoint | `http://regulations-mcp.dockets.svc.cluster.local:8080/mcp` — **Streamable HTTP** |
| Auth | `MCP_AUTH_MODE=none`; keyless for eCFR + Federal Register |

The ghcr image could **not** be confirmed public, so nothing here relies on it — the image is
built from the pinned source on the box.

### 0.1 The real tool surface — these exact names (from live `tools/list`)

**7 tools.** These are the only names that exist; anything else is a guess.

| Tool | Use it for | Required args | Key optional args |
|---|---|---|---|
| `regulations_browse_cfr` | Walk eCFR structure — `mode:"structure"`: all titles → a title's divisions → a part's sections/appendices — or full-text search the CFR with `mode:"search"`. | `mode` | `title`, `part`, `query`, `date`, `page`, `per_page` |
| `regulations_get_cfr_section` | **Read codified text.** One section, a whole part, or an appendix; current or `date` point-in-time. Returns `cfrCite`, `heading`, `hierarchyPath`, `bodyText`, `sourceNote`, `source`. | `title` | `part`, `section`, `appendix`, `date`, `offset`, `max_chars` |
| `regulations_search_rules` | Search the Federal Register (1994–present): query, type, agency slug, date window, CFR title/part, docket, RIN, or FR page cite. Discovery entry point. | none | `query`, `type`, `agencies`, `published_after`, `published_before`, `cfr_title`, `cfr_part`, `docket_id`, `rin`, `citation`, `citation_date`, `order`, `per_page`, `page` |
| `regulations_get_document` | One FR document by FR number → metadata + Regulations.gov docket/document IDs + comment count/URL + affected CFR parts. Full text only with `include_full_text`. | `document_number` | `include_full_text`, `offset`, `max_chars` |
| `regulations_list_open_comments` | FR documents open for comment, soonest closing first. Keyless. | none | `query`, `type`, `agencies`, `closing_before`, `per_page`, `page` |
| `regulations_get_docket` | Regulations.gov docket + its filed documents. **Needs `REGULATIONS_GOV_API_KEY`.** | `docket_id` | `document_types`, `per_page`, `page` |
| `regulations_find_comments` | Public comments on a docket/document/FR number, or one comment by `comment_id`. **Needs `REGULATIONS_GOV_API_KEY`.** | none | `docket_id`, `document_object_id`, `fr_document_number`, `comment_id`, `search_term`, `posted_after`, `posted_before`, `per_page`, `page` |

Plus **2 resources**: `regulations://cfr/{title}/{part}/{section}` and
`regulations://document/{frNumber}`.

### 0.2 Measured behaviour — including what fails

- **The two Regulations.gov tools fail in this deployment.** No key is set. A real call returns
  `isError: true` with `Error: REGULATIONS_GOV_API_KEY is not configured. (reason auth_required)`.
  So comments and Regulations.gov dockets are **not reachable** here. Do not plan an AO comment
  pull through them. `regulations_search_rules` and `regulations_get_document` still carry
  comment *counts* and Regulations.gov IDs from the Federal Register — those need no key.
- **Every CFR read reports `source: "live"`.** The baked-in SQLite/FTS5 mirror is empty in this
  deployment, so reads go to the live eCFR versioner API. Functionally correct; depends on egress
  to ecfr.gov, and slower than a populated mirror.
- **Point-in-time works, but only from 2017 onward** for eCFR (`date` outside the retained window
  is rejected with the window named).

**Honest verdict — partial fit.** The MCP covers the CFR (Layer 1), but it has **zero coverage**
of Layer 2 (FSM, BLM Manuals, NPS Management Policies) and Layer 3 (FSH, BLM Handbooks,
sub-regulatory guidance). It does not know fs.usda.gov directives, BLM Manual 6340, or NPS
management policies. This matters because **the bulk of AO's regulatory provisions live in the
Handbook layer, not the CFR** — in the exposure matrix AO itself counts **17 of 21 exposed
provisions as "Handbook only"** vs **2 Manual** and **2 CFR**. The CFR delegation
`36 CFR 251.64(b)` outsources the renewal standard to "applicable Forest Service directives" —
the actual standard sits in FSH 2709.14 §53.1m, which no regulations MCP can see. This skill
therefore runs **two locate paths**: the MCP for Layer 1, and **direct agency sources** (§4) for
Layers 2-3 — which is exactly the analyst's own source-pull method.

**Transport: Streamable HTTP only, as deployed.** `MCP_SESSION_MODE=stateless`, so no session id
is needed; `POST /mcp` with `Accept: application/json, text/event-stream` and answers may come
back as SSE `data:` lines or bare JSON. (The same binary also speaks stdio if ever run that way —
no shim needed either way.)

---

## 1. The 3-Layer Vulnerability Filter — run on EVERY located provision

This is the core decision rule (AO "Reference Dump", Tab 2 §3). Every provision you locate is
classified into exactly one layer. The layer determines how much AO cares and what "current,
authoritative" means.

| Layer | Anchor | Status | AO read | Example (from AO material) |
|---|---|---|---|---|
| **1 — CFR** | Exists in 36 CFR Part 251 (or 43/50 CFR) | **Protected — low exposure.** Only amendable by notice-and-comment rulemaking. | Locate, cite, done. Usually *not* the thing AO is fighting about. | Revocation grounds under `251.60(a)` |
| **2 — Manual** | Exists in FSM 2700 (or BLM Manual / NPS Mgmt Policies) | **Partially protected** — deviation requires public-interest justification. | Locate and note as the "backstop" — safer than a Handbook-only provision. | GRFS mechanics under `FSM 2715.11` |
| **3 — Handbook Only** | Only in FSH 2709.11 / 2709.14 (or BLM Handbook / guidance) | **Fully exposed — vulnerable zone.** Becomes discretionary the moment Handbooks are reclassified advisory. | **This is where the comment goes.** Locate with maximum care. | Fee rate structures, renewal standard |

**Working rule (AO's own analytical principle, quoted):** "The proposed rule does not amend
the Handbook itself. It changes what the Handbook can and cannot do. Any provision that exists
only in the Handbook and functions as a binding constraint on permittees becomes discretionary
the moment Handbooks are reclassified as advisory." A provision's **current home** — not where
AO wishes it were — determines the layer. A fee *rate* in FSH 2709.11 ch 30 §36.21c is Layer 3
*even though* 36 CFR 251.57 authorizes fee collection generally (251.57 contains no rate).

---

## 2. AO regulation landscape (grounded target list — do not generalize beyond this)

AO = outfitted/guided recreation on federal lands. **Primary agencies: USFS and BLM.**
Secondary: NPS, FWS. The target list below comes verbatim from AO's "template of record"
(the USFS Directives Modernization project, RIN 0596-AD74) plus the filed comment letter and
the IOGA/AO gap-analysis table — **not** a generic map of the CFR.

### 2.1 Source Architecture & Hierarchy (USFS Directives project, Tab 2 §3)

- Federal Register proposed rule — RIN 0596-AD74, Document 2026-13281, 91 Fed. Reg. 39948 (July 1, 2026)
- **36 CFR Part 251, Subpart B** (special uses) — from eCFR
- **FSM 2700 series** — Manual chapters **2710, 2715, 2716, 2720** — from fs.usda.gov
- **FSH 2709.11** — all chapters **10-90** — from fs.usda.gov
- **FSH 2709.14, ch. 50** (Outfitting & Guiding and Other Concession Services) — Amendment 2709.14-**2026-1**, effective **April 28, 2026**

### 2.2 The 36 CFR sections AO actually cites (from the filed letter + gap analysis)

`251.51` (definitions), `251.54` (proposal content), `251.57` (fees — no rate), `251.58`
(appeals), `251.60(a)` (revocation/suspension; `251.60(d)` "reasonable time to cure"),
`251.64(b)` (renewal — delegates to directives), `251.124(b)` (operating plans). Plus, in the
Directives context: **36 CFR 216.1(b)** (the rule amends it — directive "formulation"), and the
procedural parts **214** (administrative appeals), **215** (appeal decisions — **empty on eCFR**,
cited as *instability evidence only*), **218** (objections).

### 2.3 The FSH/FSM provision map (exposure matrix + gap analysis — 21 rows, verbatim anchors)

These are the provisions AO has already located and layer-classified. Use them as the starting
map; **verify**, don't rebuild.

- **FEES — FSH 2709.11 ch 30:** `§36.21c(1)-(2)` flat fee vs % of AGR election ($6/service day or 3% AGR, whichever greater); `§36.21c(2)` two AGR methods + "base trip payment" definition; `§36.21c(3)` short-stop fee (new in 2026-1; basis FLREA 803(h)(2)(B) as amended by EXPLORE); `§36.21b`/`§36.21f` minimum annual fee ($70 base, GDP-IPD adj every 3 yrs) + assigned-site $140 min; `§36.21d` service-day counting (drop-off/pick-up/livery). **GRFS** = FSM **2715.11** (Manual) with handbook detail → *Manual layer*.
- **ISSUANCE / RENEWAL / TERMINATION — FSH 2709.14 ch 50:** `§53.1m(1)-(4)` priority use up to 10 yrs / renewal w/o competition on satisfactory performance (gap analysis cites `§53.1h(2)-(4)` for the same renewal standard — resolve both, they are the same provision); `§53.1q(1)` performance-review frequency (annual temp / ≥2 yrs priority) + "satisfactory" definition; `§53.1p(1)-(3)` reallocation on reduction (existing-holder preference); `§53.1k` temporary-use permits (no renewal right). **CFR anchor:** `251.60(a)` revocation grounds (protected — say so, don't waste effort). **Manual anchor:** `FSM 2716.8-.83` debarment/suspension (monitor only).
- **OPERATIONAL — FSH 2709.14 ch 50:** `§53.1n(4)(a)-(b)` use-reduction formula (≤100% of prior-yr actual use; 125% if satisfactory); `§53.1c(2)-(3)` no new O&G improvements outside wilderness absent demonstrated public need / near-total bar inside wilderness (implements Wilderness Act 1133(c) → statutory tie).
- **CAPACITY — FSH 2709.14 ch 50:** `§53.1f` resource capacity analysis + outfitted/non-outfitted, priority/temp split.
- **SCOPE / DEFINITIONS:** `§53` definitions (outfitting, guiding, priority use, temporary use, service day, quota, use area, holder) — 36 CFR Part 251 Subpart B has **zero** O&G definitions; `FSH 2709.11 ch 50` operating-plan "significant" vs "non-significant" update (authorized officer's call, no criteria).
- **APPEALS / PROCESS:** `FSH 2709.11 ch 20 §27.4` cost-recovery category/amount NOT appealable (251.58(e) provides supervisory review only); `FSH 2709.11 ch 30 §32.33` 90-day nonpayment notice (251.60(d) says only "reasonable time to cure"); `FSH 2709.11 ch 10 §12.12` 60-day target to act on a proposal (expressly no right if missed); `FSH 2709.11 §32.4` (cited in the filed letter).
- **REPORTING — FSH 2709.14 ch 50:** `§53.1j(3)-(4)` actual-use report within 30 days of season close + livestock grazing record.

**Priority recodification map (AO's top-8, "fix" column = the clean CFR/FSM home):**
1. renewal w/o competition `53.1m` → **251.64** · 2. flat fee / AGR election `36.21c(1)-(2)` → **251.57** · 3. AGR methods + base trip payment `36.21c(2)` → **251.57** · 4. scope defs `53` → **251.51** · 5. use-reduction `53.1n(4)` → **FSM 2720** · 6. capacity analysis `53.1f` → **FSM 2720** · 7. perf review `53.1q(1)` → **FSM 2720** · 8. service-day count `36.21d` → **FSM 2715 or 251.57**.

### 2.4 Authorization types by agency (Tab 2 §5 — which titles/parts matter)

| Agency | Authorizations (verbatim) | Regulatory anchors AO names |
|---|---|---|
| **USFS** | SUPs, SRPs (outfitter-guide, recreation events, recreation residences), Priority Use Permits, Temporary Use Permits (≤2 yr per EXPLORE Act), Cost Recovery fees, Fee structures (flat fee, % of AGR, short-stop fee, minimum annual land use fee) | 36 CFR 251 Subpart B; FSM 2700; FSH 2709.11 / 2709.14 |
| **BLM** | SRPs (Form 2930-2), Commercial use in Wilderness/WSA, "extent necessary" test, Travel Management Plans | **BLM Manual 6340** (wilderness "extent necessary"); SRP form 2930-2. *(AO material names the Manual + form, not a 43 CFR part — resolve the part via the regulations MCP, §3.)* |
| **NPS** | CUAs, Concession Contracts (**54 U.S.C. §101913**), Annual reporting (financial + trip-by-trip within 60 days) | 54 U.S.C. §101913 (statute → find-statute). *(AO material names the statute, not a 36 CFR concession part.)* |
| **FWS** | Special Use Permits for Refuges | *(AO material names the authorization only — resolve the 50 CFR part via the regulations MCP, §3.)* |
| **State** | Idaho (IOGLB), Oregon (OSMB) | out of scope for this skill (state, not federal CFR) |

---

## 3. Procedure (locate, in this order)

1. **Identify the agency** from the provision (USFS / BLM / NPS / FWS). If multi-agency or
   unclear, locate per-agency and keep the maps separate — **never** let BLM wilderness rules
   bleed into USFS, or regional supplements into national analysis.
2. **Layer 1 locate — CFR via the regulations MCP.** The skill is not guessing at tool names any
   more; these are the deployed calls, in the order you use them:

   a. **Confirm the part's shape** (optional but cheap when the section number is uncertain):
      `regulations_browse_cfr` with `{mode:"structure", title:36, part:"251"}` → every section and
      appendix in the part, paged, each with its subpart. Part 251 returns 48 entries over 2 pages.
   b. **Read the text** — the call that actually answers the question:
      `regulations_get_cfr_section` with `{title:36, part:"251", section:"251.64"}`.
      `title` is required; write the section as people cite it (`"61"`, `"§ 141.61"`,
      `"141.61(c)"`, or the full `"40 CFR 141.61"` in part 141 all resolve).
      Returns `cfrCite`, `heading`, `hierarchyPath`, `bodyText`, `sourceNote` (the FR cite that
      amends it), `bodyTextLength`, and `source` (`live` in this deployment).
   c. **Point-in-time** when currency matters: add `date:"YYYY-MM-DD"` (eCFR retains 2017→today).
   d. **Find the rule that made/changed it**: take the `[88 FR 84709, Dec. 6, 2023]` source note
      and call `regulations_search_rules` with `{citation:"88 FR 84709", citation_date:"2023-12-06"}`,
      or query by `{cfr_title:36, cfr_part:"251", type:["PRORULE"]}` to see pending changes.
   e. **Long reads**: `bodyText` is windowed at 64,000 chars (`max_chars` up to 200,000). If
      `bodyTextNextOffset` is present, call again with that `offset`. Whole parts run to millions
      of characters — read a single section instead unless you truly need the part.

   Record the exact `cfrCite` and the `date` the read reports. **For BLM/NPS/FWS, this MCP has no
   agency→part mapping** — it indexes the CFR by title/part only. Resolve the part yourself
   (`regulations_browse_cfr` `{mode:"search", query:"...", title:43}`) before the content call.

   **Do not** reach for `regulations_get_docket` / `regulations_find_comments` in this pipeline:
   they are `auth_required` without `REGULATIONS_GOV_API_KEY`, which is not set (§0.2). If a
   provision needs comments, that is a separate decision, not a locate step.
3. **Layer 2/3 locate — direct agency sources** (the MCP cannot see these). Navigate the agency
   directive system (§4) and resolve the Manual/Handbook chapter + section. Record the amendment
   number and effective date off the transmittal page.
4. **Version check.** Confirm you have the *current* amendment, not a superseded one (§5). For the
   USFS directives baseline this is **Amendment 2026-1, effective 2026-04-28** (FSH 2709.14).
5. **Classify by layer** (§1) and **assemble the regulation map** (§6).

Locate only: at the end you hold **citations + source URLs + layer + version flags**, not fetched
document text. Hand that map to `download-regulation.md`.

---

## 4. Source navigation — the analyst's method (the pull path)

**CFR (Layer 1):** the **primary** path is the deployed MCP —
`regulations_get_cfr_section` (§3 step 2) returns the codified text with its `hierarchyPath`, its
`date`, and its FR `sourceNote`. Use the browser only to read alongside a human or when the MCP is
down: eCFR — `https://www.ecfr.gov/current/title-36/.../part-251/subpart-B` (USFS),
`/title-43/...`, `/title-50/...`. Stamp any saved copy "current as of [date]".

**USFS directives (Layers 2-3):** index at `https://www.fs.usda.gov/cgi-bin/Directives/` (the
"Key URLs" in Tab 2 §9 is `fs.usda.gov/cgi-bin/Directives/`). Service-wide Handbooks at
`https://www.fs.usda.gov/im/directives/` → series 2000 → **2700** (Special Uses). Regional/forest
supplements are a *separate* field-issuances list (do not treat them as national).

**BLM:** Manuals/Handbooks at `https://www.blm.gov/policy` (Manual 6340, H-2930-1); NEPA planning
at `https://eplanning.blm.gov`. **NPS:** Management Policies + Director's Orders at
`https://www.nps.gov/subjects/policy/`. **FWS:** refuge manuals at fws.gov.

**Federal Register / docket pin cites** (when the provision is a proposed rule): FR HTML page for
reading; the govinfo PDF for **pin cites** (page/column exist only in the PDF); regulations.gov
for the docket.

**Traps (observed in AO's actual pulls):** chapters come **one at a time**, some **split across
files**; IDs/exhibits filed separately; **no consolidated download, no version history** — the
amendment # + effective date off the transmittal page is the *only* version signal; older chapters
shipped as **binary .doc** (OCR damage likely); earlier pulls were **not current** — re-pull against
the 2026-1 baseline rather than trusting a stale chapter.

*(Note: the working doc "directives - first read + source pull (6/30-7/16)" — which logs the analyst's
exact click-path — was **not readable** at build time (404 on Drive/Docs API for this account).
The navigation above is reconstructed from the Reference Dump's §3 source list + §9 Key URLs +
the other directive docs' traps; the specific chapter-by-chapter click-path is marked inferred.)*

---

## 5. Source handling & version control (Tab 2 §4 — hard decision rules)

**Controlling vs reference.**
- **Controlling (authoritative):** Federal Register notices, CFR from eCFR, agency Manuals/Handbooks from the official portal, Statutes (USC), prior AO comment letters.
- **Reference (consult, never override):** research briefs, member synthesis, coalition letters, news, academic analyses.
- **Conflict rule:** if a reference contradicts a controlling source, follow the controlling source and flag the conflict explicitly.

**Version / currency.** Cite to the **current amendment**, not the first one pulled. Check the
transmittal page, not the body — multiple fee directives shipped in one year (April and August
2026) and both are findable. Do not lean on dead cross-refs as live law: **36 CFR 215** is empty
on eCFR (cite only as evidence the appeal route is unstable). The short-stop fee basis is
**FLREA §803(h)(2)(B)** as amended by EXPLORE — not a generic fee statute.

**OCR / conversion artifacts.** Flag OCR-derived text: `OCR-derived — spot-check before citation`.
Common artifacts: "ocer" for *officer*, "re" for *fire*, mangled section numbers (a bad section
number makes a cite that "reads fine and points nowhere"). Prefer clean text from eCFR or agency
HTML portals; if only a PDF exists, OCR-verify against a known clean excerpt.

**Static vs live.** Live Google Docs are human-editing masters; a locate step works from
**static exports** (version-stamped) to avoid mid-process drift. Never pass a Google Doc link as
a primary locate source.

---

## 6. Output format — the regulation map

Hand this structured map to `download-regulation.md`. One block per located regulation:

```
citation:     36 CFR 251.64(b)              # exact, current-amendment
layer:        1 (CFR)
agency:       USFS
source_url:   https://www.ecfr.gov/current/title-36/.../part-251/subpart-B
as_of:        <eCFR current-as-of date>
version_note: current (no superseding amendment)
ocr_flag:     false

citation:     FSH 2709.14 ch 50 §53.1m(1)-(4)
layer:        3 (Handbook only)              # fully exposed
agency:       USFS
source_url:   https://www.fs.usda.gov/cgi-bin/Directives/ (series 2700)
amendment:    2709.14-2026-1, eff 2026-04-28
version_note: cite to Amend 2026-1; earlier pulls superseded
ocr_flag:     false
```

Always emit a one-line **gap note** when relevant, e.g. "36 CFR 251.64(b) delegates the renewal
standard to 'applicable Forest Service directives' — the actual standard is Layer 3, FSH 2709.14
§53.1m." AO's fight is almost always the gap between a Layer 1 delegation and the Layer 3 detail
that fills it.

---

## 7. Quality gates (hard stop if any fail)

- **Every citation is current-amendment and layer-classified.** No superseded, no reserved parts cited as live law (36 CFR 215 only as instability evidence).
- **Agency isolation:** no cross-agency bleed (BLM wilderness ≠ USFS; regional supplements ≠ national). Each map row names its agency.
- **OCR flags set** on anything from an old .doc or scanned PDF.
- **Source tier labeled** (controlling vs reference); conflicts resolved to controlling and flagged.
- **Layer 2/3 located via the official agency portal**, not guessed or left blank because the MCP can't see them.
- **Grounded:** no CFR part, Manual chapter, or Handbook section appears that is not in §2 or traced to an AO source. Anything beyond §2 is marked inferred and resolved via the MCP/portal.
- **Locate only** — no fetched document text in the output; the identifier goes to `download-regulation.md`.

---

## 8. Traps (from AO's actual work)

- The proposed rule may not amend a Handbook at all — it may just change *what a Handbook can do*. Locate both the text and its **home**, because the layer classification is what matters.
- FS's own directive-system framing: "the words used to issue direction, not the Manual-vs-Handbook label, decide how binding it is." Account for that sentence; don't talk past it.
- Don't rebuild the IOGA/AO gap-analysis table or the external cross-reference index — **verify** them, then use them as the starting map.
- If a provision is already Layer 1 (e.g. `36 CFR 251.60(a)` revocation grounds), say so and move on — don't waste locate effort on protected text.
- The renewal provision appears as both `53.1m` (exposure matrix) and `53.1h` (gap analysis) — treat as the same renewal-without-competition standard; confirm the current section label against the 2026-1 text.
- "Recission" (their spelling) in the proposed rule is a quote — preserve it, don't "correct" it.
