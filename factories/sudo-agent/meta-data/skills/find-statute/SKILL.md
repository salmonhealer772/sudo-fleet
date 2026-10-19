---
name: find-statute
description: Locate the governing U.S. Code statute for a flagged provision via the statutes MCP (mcp_statutes_* tools). LOCATES only; download-statute fetches.
---

# find-statute.md

---

> ## ⚠️ STATUS: FIRST DRAFT — NEAR-TERM REFINEMENT REQUIRED
>
> **This skill will need further detail and refinement before it is trusted in the pipeline.**
> Its purpose now is to state *what* this locate step is for and *how* AO thinks about the
> material — it is not yet wired exactly to the tools and MCPs the agent will actually look
> through.
>
> **What refinement means, concretely:**
>
> - **Exact tool-surface alignment.** Every tool named here must be reconciled against the real,
>   running MCP the agent will call — exact tool names, exact parameter names and types, exact
>   return shapes, and the actual error behaviour. Where this skill names a tool from a repo
>   read rather than from a live call, that must be re-verified against the deployed service
>   before the skill is used in production.
> - **In-cluster deployment reality.** A skill can only call what is stood up. Any MCP that is
>   not yet running as a kube service (see the transport notes in this file) cannot be reached by
>   an agent, regardless of what this skill says. The skill must be reconciled with what is
>   actually deployed, and re-checked whenever that changes.
> - **Tool-coverage gaps.** Where this skill's method requires a source the backing MCP cannot
>   see, the fallback path must be made explicit and executable — not left as a description of
>   how a human would find it.
> - **Identifier plumbing.** The exact identifier this skill emits must be the exact identifier
>   the matching `download-*` skill consumes, verified end-to-end rather than by naming
>   convention.
> - **Live verification pass.** Run the skill against a real AO docket end to end, and correct it
>   wherever the actual tool behaviour differs from what is written here.
>
> Treat this as the method document. The implementation pass — matching it precisely to the
> deployed tools and MCPs — is still ahead of us.

---
**What this file is:** the **locate skill, statutes half**. Given one flagged provision of a
docket, resolve **which U.S. Code section(s) govern it** — the "look around" step. It does NOT
fetch text; it hands a citation + package identifier to `download-statute.md`, which fetches.
Locate first, then fetch — always in that order.

**Tool layer:** the deployed `statutes-mcp` (namespace `dockets`) is live and its
exact call surface — `get_section`, `search_code`, `get_by_citation`, `list_titles`,
`get_references` — is documented in `statutes-mcp.md` (this dir). Read that for the
tool names/args; this file is the method.

**Backing MCP:** statutes MCP — repo `TheAxiomFoundation/axiom-corpus` (self-hosted REST API of
parsed U.S. Code; needs a thin MCP wrapper).
**Owner:** all meta-data-agents (shared skill set; only the persona differs).

**Provenance — this skill is derived from AO source material, not general legal knowledge.**
Every statute and citation below traces to AO's own documents (read in full 2026-10-14):

| AO source (Drive ID) | What it gave this skill |
|---|---|
| `AO Docket Auditors Reference Dump` (`12NlJ2_…-sadM`) Tab 1 + Tab 2 | scope; the four comment targets; agency authorization types (Tab 2 §5, incl. **54 U.S.C. §101913**); the legislative-acts list (Tab 2 §6); the CFR/Manual/Handbook vulnerability filter |
| `directives — fee piece, EXPLORE xcheck` (`13CbvwAc…_HIM`) | EXPLORE fee provisions verbatim: **16 U.S.C. §6801(5)/(7)/(14)**, **§6802(b)**, **§6802(h)(2)(A)–(H)**, **§6803(a)–(b)/(d)**; CODIFIED / PARTIAL / NOT-CODIFIED classification |
| `directives — first read + source pull` (`1wR9BMo3…nCEM`) | the **§497c** miscitation trap; FLREA **§803(h)(2)(B)** as amended by EXPLORE; **16 U.S.C. §1612(a)**; OCR damage; dead/unstable cross-refs |
| `tips — proposed rule read` (`1OClnb-2…mo5JM`) | **IRC §224** / **OBBBA §70201**; §224(d)(1) "qualified tips … as provided by the Secretary" |
| Filed comment letters (case `03_Outputs/`): `…RIN_0596-AD74_FINAL`, `…EXPLORE Sec 133` | **16 U.S.C. §8546(a)** review frequency; **§8547** 100/125 formula; EXPLORE §133 = **16 U.S.C. §8443**; the "visitor-use day" vs "service day" terminology rule |

Where this skill INFERS something AO did not state verbatim, it is marked **[inferred]**.

---

## 1. Authority ordering — READ THIS FIRST

AO's legal hierarchy, in order of precedence:

```
STATUTE (U.S. Code / Public Law)    ← primary, controlling
  > REGULATION (CFR)                 ← implements the statute
    > MANUAL (FSM / BLM Manual)      ← mandatory direction, sub-statutory
      > HANDBOOK (FSH / BLM Handbook)  ← advisory guidance
```

**Statutes take PRIMARY precedence over regulations, manuals, and handbooks.** This ordering is
non-negotiable and is the reason this skill exists.

Grounded in AO material:

- Reference Dump Tab 2 §3 (the three-layer vulnerability filter) ranks **CFR (protected) >
  Manual (partially protected) > Handbook-only (fully exposed)**; Tab 1 places a binding statute
  above all three.
- Reference Dump Tab 1 ("Strategic Voice"): AO fights for "enforceable regulations codified in
  the CFR over discretionary, advisory agency guidelines," rooted in the fact that commercial
  recreation is "a vital, statutory component of multiple-use mandates."
- `first read` doc: "O&G permitting was always policy not reg… BUT EXPLORE codified some of it
  (3% fee, 10 yr term, use review) so those are law now, can't be undone by revising policy."

Consequence: locating a statute means locating the **highest** authority in the chain. If the
provision implements a statute, say so and name the tie — the statute↔provision tie is the
strongest fact any AO brief can lead with. Never present a Manual or Handbook citation as if it
outranked a statute.

---

## 2. When this skill runs

**Input:** one flagged provision (from `determine-concern.md`) — a specific rule change with its
agency and docket, e.g. *"FSH 2709.11 ch. 30 §36.21d — service-day counting methodology."*

**Output:** one or more **located-statute records** (format in §7) — the governing U.S. Code
section(s), with citation, Public Law, codification status, and a package ID for
`download-statute.md`.

**Boundary:** locate only. No fetching of section text, no drafting of legal argument, no opinion
on what AO should argue. This is decision support; Customer Contact A is the signatory.

---

## 3. AO's statute landscape — the lookup map

Start here. Map the flagged provision to its agency/concern, then to the candidate statute. These
are the anchors AO actually cites; **always re-verify the exact section against the statutes source at locate
time (§5), never cite from this table alone.**

### 3a. The legislative acts AO tracks

Reference Dump Tab 2 §6, verbatim list: **EXPLORE Act (Public Law 118-234), FLREA, Wilderness
Act, FLPMA, Antiquities Act, ICOR Section 133 Visitation Pilot.** Named elsewhere in AO material:
**54 U.S.C. §101913** (NPS concession contracts, Tab 2 §5) and **IRC §224** (qualified tips,
`tips` doc).

### 3b. Statute-by-statute (what AO actually cites)

**EXPLORE Act — "Expanding Public Lands Outdoor Recreation Experiences Act," Public Law 118-234,
138 Stat. 2891–2898.** It does three things that matter to AO, in three distinct places:

1. **Fee chapter (amends FLREA).** EXPLORE §311 struck FLREA §803(h) and rewrote it as
   **16 U.S.C. §6802(h)(2)(A)–(H)**. Definitions live at **§6801**: "visitor-use day" is
   **§6801(5)** ("a visitor-use day, user day, launch, or other metric used by the Secretary");
   "recreation fee" is **§6801(7)** (and **§6801(14)**). The fee standard is **§6802(b)** —
   "commensurate with the benefits and services provided to the visitor" (NOT "fair market
   value"). The fee-change process is **§6803(a)–(b)** (public participation + local newspaper
   notice) and **§6803(d)** (RRAC review, aimed at standard/expanded amenity fees, not SRPs).
2. **Outfitter/guide allocation provisions.** The filed AD74 letter cites **16 U.S.C. §8546(a)**
   (performance review frequency) and **16 U.S.C. §8547** (the 5-year review / 125%-restoration
   "100/125 formula") as statutory.
3. **§133 Visitation Pilot (the "ICOR" pilot).** The filed EXPLORE §133 letter cites it as
   "Section 133 of the EXPLORE Act (Public Law 118-234, codified at 16 U.S.C. 8443)". ICOR =
   FICOR = the Federal Interagency Council on Outdoor Recreation.

**FLREA (Federal Lands Recreation Enhancement Act).** Its fee section is **§803(h) → 16 U.S.C.
§6802(h)**; the short-stop fee's basis is "FLREA §803(h)(2)(B) as amended by EXPLORE"
(`first read` doc).

**Wilderness Act.** "extent necessary" for commercial services in designated wilderness — the
test named in Tab 1 scope and Tab 2 §5 (BLM). Section pin: **§4(d)(5) = 16 U.S.C. §1133(d)(5)**
[inferred — AO names the "extent necessary" test but not the section; the section is the standard
codification of that test].

**FLPMA (Federal Land Policy and Management Act).** Underlies BLM SRP authority (Tab 1
"underlying laws like FLPMA"; Tab 2 §6). [AO names the act, no section — locate at runtime.]

**Antiquities Act.** Named in Tab 2 §6; relevant to National Monument boundary adjustments
(Tab 1 scope). [AO names the act, no section.]

**54 U.S.C. §101913** — NPS Concession Contracts, named verbatim (Tab 2 §5).

**IRC §224 (26 U.S.C. §224)** — "qualified tips," added by **OBBBA §70201**. §224(d)(1):
"cash tips received by an individual in an occupation that customarily and regularly received
tips on or before December 31, 2024, **as provided by the Secretary**" (`tips` doc). The phrase
"as provided by the Secretary" makes the Secretary's occupation list the eligibility gate — a
definitional-scope trap (see §6).

**16 U.S.C. §1612(a)** — the Forest Service directive notice-and-comment authority (filed AD74
letter: "after an initial round of Handbook revisions taken through comment under 16 U.S.C.
1612(a), subsequent Handbook changes would not be subject to notice and comment at all").

### 3c. Lookup by agency + concern

| Agency | Concern (AO persona axis) | Governing statute AO cites |
|---|---|---|
| USFS | fee structure (SRP/SUP fees, service-day counting, election) | FLREA §803(h)→16 U.S.C. §6802(h); §6801(5)/(7)/(14); §6802(b); §6803 |
| USFS | tenure/allocation (renewal standard, 100/125, review frequency) | EXPLORE §8546(a), §8547; note 36 CFR 251.64(b) delegates the renewal standard to "applicable Forest Service directives" |
| USFS | directive modernization (Handbook→advisory) | 16 U.S.C. §1612(a) |
| BLM | wilderness "extent necessary" | Wilderness Act §4(d)(5) [inferred pin] |
| BLM | SRPs, commercial use | FLPMA [no section named] |
| NPS | concession contracts, CUAs | 54 U.S.C. §101913 |
| any (federal lands) | monument boundaries | Antiquities Act [no section named] |
| IRS | qualified tips for guides/instructors | IRC §224 (OBBBA §70201) |
| FICOR/ICOR | visitation data pilot | EXPLORE §133 → 16 U.S.C. §8443 |

FWS (Special Use Permits for Refuges) is named in Tab 2 §5 but no statute is attached — locate at
runtime.

---

## 4. Backing MCP — verified surface (write against this, not a guess)

Repo `TheAxiomFoundation/axiom-corpus` — MIT, real, public, Dockerfile, self-hosted REST API.
**Re-audited 2026-10** (replacing `lzinga/us-gov-open-data-mcp`, which could not return a single
U.S. Code section). VERIFIED at the repo level:

- **All 54 U.S. Code titles already parsed from the official OLRC USLM XML** — the same source we
  independently verified (below).
- **REST API**, not an MCP: `uvicorn axiom_corpus.api.main:app --port 8000`. It therefore needs a
  **thin MCP wrapper** (the spicy-regs-over-DuckDB/R2 pattern) before an agent can call it through
  a skill-gated tool.
- **Self-hosted, public-domain data, no API key, no auth.**

**Exact endpoint surface: UNKNOWN here.** The audit did not enumerate axiom-corpus's REST
endpoints or response shapes. Before writing the wrapper or this skill's exact call sequence,
reconcile against `axiom_corpus/api/main.py` (and the repo README) — the FIRST-DRAFT banner above
already flags this as a required refinement pass.

**Source verification behind the pick (VERIFIED live):** the official source is the Office of the
Law Revision Counsel (OLRC). `uscode.house.gov/download/download.shtml` is a **soft-404** — the
real page is **`https://uscode.house.gov/download.html`**. The whole U.S. Code ships as one
**108.7 MB** zip (`xml_uscAll@<release>.zip`, currently release point **PL 119-121**, 2026-10-09),
697 MB uncompressed, 58 title files, **65,725 `<section>` elements**, USLM 1.0 namespace with
hierarchical identifiers (`/us/usc/t5/s101`) that give title/chapter/section/subsection for free
as the citation key, and `<sourceCredit>` carrying a machine-readable amendment trail (every
`<date date="...">` and `<ref href="/us/pl/...">`).

**Mirror-beats-live-proxy:** OLRC is currently serving a "temporary format" maintenance banner
with some paths returning HTTP 500. axiom-corpus is mirror-shaped — a mirror degrades to **stale,
never to wrong**; a live proxy fails to confident-and-wrong. A point in the pick's favor.

---

## 5. Procedure — locate the statute

### Step 1 — Classify the provision
Extract from the flagged provision: **agency**, **authorization/concern axis**, and the
**operative subject** (fee / tenure-allocation / wilderness / access / scope-definition / tax).
Use §3c to name 1–2 candidate statutes. A scope/definition change points at the statute that
defines the operative term (e.g. a "service day" counting change points at §6801(5) and §6802(h)).

### Step 2 — Locate the section (exact calls)
Run these in order until you have a pinned citation + the source's section identifier:

1. **Resolve the citation by USLM identifier.** axiom-corpus is keyed off the USLM hierarchical
   identifier (`/us/usc/t5/s101` = title/chapter/section/subsection). Map the provision's
   governing statute to its title + section, then fetch that section through the MCP wrapper.
2. **Trace the enacting Public Law** (for EXPLORE: Public Law 118-234) via the `<sourceCredit>`
   amendment trail in the USLM — it records every `<date date="...">` and
   `<ref href="/us/pl/...">`, so a section's codification history is machine-readable.
3. **Session-law / recent-act citations** that may not be in the printed USC yet — flag and
   resolve separately, since the corpus reflects a release point (currently PL 119-121,
   2026-10-09) and a brand-new act may postdate it.

(Exact call shape: reconcile against the deployed wrapper — see §4.)

### Step 3 — Verify the citation (precision gates — do not skip)
Run every check in §6. AO's documented failure mode is a citation that "reads fine and points
nowhere" (OCR-damaged section numbers, dead cross-refs).

### Step 4 — Classify codification status (for THIS provision)
The discipline from the fee-piece cross-check:

- **CODIFIED** — the rule the provision sets is already in statute (e.g. the election right and
  3% ceiling at §6802(h)(2)(E); the two AGR methods at §6802(h)(2)(F)). → protected from
  sub-regulatory change.
- **PARTIAL** — the statute mandates/benchmarks the thing, but the operative number/mechanism is
  agency-side (e.g. the $6/VUD figure is a *default* at §6802(h)(2)(B)(iii)(IV); minimum fee $ +
  GDP-IPD index; the counting rules are not codified).
- **NOT CODIFIED** — zero statutory tether (e.g. the §36.21d service-day counting rules:
  fractional-day, drop-off/pick-up, livery).

Record this status. It is the difference between "this provision is protected" and "this
provision is exposed and only the statute's outer boundary binds it."

### Step 5 — Emit the located-statute record(s)
Use §7. One record per governing section.

---

## 6. Precision traps — named, real AO failures. Check every locate against these.

1. **§497c is the ski area permit act, NOT outfitter-guide fee authority.** AO's first
   cross-reference pass listed **16 U.S.C. §497c** as fee authority; it is the *National Forest
   Ski Area Permit Act* (`first read` doc). Do not cite it for O&G fee authority, and do not cite
   it for the short-stop fee — the short-stop fee's basis is **FLREA §803(h)(2)(B) as amended by
   EXPLORE (16 U.S.C. §6802(h)(2)(B))**. Before emitting any fee citation, ask: *is this the
   ski-area statute?*
2. **"visitor-use day" is §6801(5), not "service day."** EXPLORE's statutory term is
   "visitor-use day" (§6801(5)); "service day" is the Forest Service's chosen administrative
   metric (Handbook). AO output must track the statutory term (`fee piece` + filed AD74 letter:
   "EXPLORE denominates both recreation fees and authorized use in visitor-use days… The Forest
   Service's chosen metric is the 'service day'"). A "service-day" counting change is NOT
   CODIFIED even though the rate it multiplies is.
3. **The EXPLORE fee architecture and allocation architecture are distinct.** Fee = FLREA /
   §6801–6803 (definitions, fee standard, fee-change process); allocation = §8546(a) (review
   frequency) and §8547 (100/125 formula). Pin which one governs the provision before you pin
   the section.
4. **"Fair market value" is the WRONG standard for SRP fees.** 36 CFR 251.57(a)(1) still says
   FMV, but the EXPLORE/FLREA fee standard is "commensurate with the benefits and services
   provided to the visitor" (**§6802(b)**). FMV appears in PL 118-234 only in an unrelated LWCF
   conversion provision (138 Stat. 2878); FMV for FS land-use fees is the appraisal track
   (Granger-Thye era). Do not conflate them (`fee piece`).
5. **Definitional-scope traps / delegation.** Where a statute delegates the operative definition
   to the Secretary — "qualified tips … **as provided by the Secretary**" (IRC §224(d)(1));
   "visitor-use day … or **other metric used by the Secretary**" (§6801(5)) — the *delegation
   itself* is the statute; the implementing list/metric is agency output. Locate the delegating
   section and state plainly what the Secretary's instrument controls vs. what the statute fixes.
6. **Dead / superseded / unstable citations.** A garbled or stale section number "reads fine and
   points nowhere." Watch OCR damage (`"ocer"` for officer, `"re"` for fire, mangled section
   numbers). Dead/unstable refs AO already flagged: 36 CFR 215 = RESERVED; 29 CFR 23 superseded;
   36 CFR 220 (NEPA) in flux. Use them as evidence a route is unstable, not as live authority.
7. **Temporal confusion.** AO has been burned conflating the April 2026 vs August 2026 FS fee
   directives, and "Amend 2023-3" vs "Amend 2026-1." Cite to the current amendment; a superseded
   version is not the authority the docket acts on.

---

## 7. Output format — the located-statute record

Emit one YAML-ish block per governing section. Compact, machine + human readable.

```
provision:        FSH 2709.11 ch.30 §36.21d — service-day counting
statute:          Federal Lands Recreation Enhancement Act §803(h)(2)(B), as amended by EXPLORE Act
citation:         16 U.S.C. §6802(h)(2)(B)
chapter:          FLREA fee chapter (as amended by EXPLORE §311)
public_law:       EXPLORE Act, Pub. L. 118-234 (138 Stat. 2891-2898)
codification:     CODIFIED | PARTIAL | NOT CODIFIED   (for THIS provision)
section_id:       /us/usc/t5/s101   (USLM hierarchical identifier, for download-statute.md)
confidence:       high | medium | low
flags:            [miscitation-checks-run, dead-ref?, OCR-derived?, needs-counsel?]
note:             one line on what the statute fixes vs. what the agency sets
```

- `citation` uses AO's convention: "16 U.S.C. §6802(h)(2)(B)" with the section symbol and pin
  cites; Public Laws as "Public Law 118-234"; session laws as "138 Stat. 2891–2898".
- If a provision touches two distinct statutes (e.g. a service-day change touches
  §6801(5)/§6802(h) *and* the allocation §8546–8547), emit two records and say so.
- `flags` must record that the §6 gates were run. If any check fails, do not emit the citation —
  re-query and correct it first.

---

## 8. Quality gates — self-check before handoff

- [ ] Every citation located via the statutes MCP (axiom-corpus behind its thin wrapper) — not recalled from memory, not copied from this table.
- [ ] §6 trap #1 (§497c) checked; no ski-area / wrong-purpose citation present.
- [ ] Fee chapter vs allocation chapter pinned (§6801–6803 vs §8546–8547); no conflation.
- [ ] Terminology tracks the statute ("visitor-use day", not "service day").
- [ ] `codification` status stated and matched to the *specific* provision, not the whole statute.
- [ ] `section_id` present and correct (so `download-statute.md` has a target).
- [ ] Authority ordering (§1) respected — the statute recorded as controlling over any CFR/Manual/Handbook touchpoint.
- [ ] No text fetched, no legal argument drafted.

---

## 9. Handoff

Pass the located-statute record(s) to **`download-statute.md`**, which fetches the section text
and places it in the provision directory. You emit the citation + `section_id`; it does the
fetch. Do not attempt the fetch yourself.

## 10. What this skill does NOT do

- Does **not** fetch/download section text (`download-statute.md`).
- Does **not** locate dockets (`find-docket.md`) or regulations (`find-regulation.md`).
- Does **not** draft legal argument, predict agency outcomes, or speak for AO. Customer Contact A is
  the signatory; this is decision-support.
