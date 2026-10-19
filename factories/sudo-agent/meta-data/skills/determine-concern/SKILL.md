---
name: determine-concern
description: Scan ONE provision against your single concern and decide concern yes/no; write a persona-tailored brief (YES) or a one-line negative (NO). The first machine scan of a docket. One agent = one concern.
---

# determine-concern.md

**What this file is:** the **scan skill** — the product's brain. Given **one provision** of a
docket and **one persona concern item**, decide whether that provision is a legitimate concern
factor for that concern. This is the **first machine scan** of a docket: the step that decides
which parts get looked into further. It is a **judgment skill with no backing MCP** — no lookup
tool, no fetch. The quality bar (from the architecture): *a pipeline that flags everything is
worthless; one that misses concerns is dangerous.*

**Hard governance — read first.** This product is **decision support** for America Outdoors
(AO), whose Executive Director (Aaron Lieberman) is the human signatory. The operating rule,
stated by AO's own material, is: **AI prepares the work; a human decides what AO believes.**
This skill **never** drafts a public comment, a legal argument, or a recommendation of what AO
"should say." It does exactly two things: (a) decide **YES/NO** whether a provision is a concern
factor for your concern, and (b) if YES, write a **brief** describing the operational
consequence. Nothing produced here goes into a federal docket with AO's signature.

---

## Inputs (exactly two)

1. **One provision** — a single segment of docket text handed to you (a section, paragraph,
   subpart, or definition). Do not re-scope it to the whole docket. Do not bring in provisions
   you were not handed.
2. **Your persona concern** — the single concern item you were built around
   (`../personas/meta-data-agent-concern/<your-concern>.md`). This is your **only** lens.

**One agent = one concern, strictly.** If a provision matters to a *different* concern but not
yours, the answer is **NO** — another agent owns that concern. Multiple agents flagging the same
provision is expected and reconciled downstream. You never defer to another agent, and you never
broaden yourself to cover their concern.

---

## Step 0 — Ground the provision before you judge it

You must not judge a provision you have not placed. Run these checks and record the answers. A
provision you cannot ground is a provision you do not flag — write the negative with the reason.

1. **Temporal check — is it the CURRENT version?** Read the amendment number / effective date /
   transmittal page, **not** the body text. AO has been burned by conflation: April vs August
   2026 fee directives; "Amend 2023-3" vs "Amend 2026-1". A provision from a superseded version
   is not the provision the docket is acting on. Cite to the current baseline.
2. **Hierarchical check — what layer does it live in?** Statute, CFR, Manual, or Handbook (see
   the filter below). A binding CFR right and an advisory Handbook note are different things; do
   not read one as the other.
3. **Jurisdictional check — which agency, which scope?** USFS / BLM / NPS / FWS, and national vs
   regional vs forest-level. Do not apply a BLM wilderness guideline to a USFS docket, or a
   single-forest supplement to a national analysis.
4. **Source-integrity check — is the text clean?** Is it OCR-derived or converted? Known
   artifacts: "ocer" for "officer," "re" for "fire," mangled section numbers. A garbled section
   number produces a citation that reads fine and points nowhere. Flag derived text; never build
   a determination on an unverified cite.
5. **Statute cross-check — is the right already anchored in a statute?** Before you call
   something "exposed," ask whether Congress already fixed it. The EXPLORE Act codified several
   outfitter-guide protections (the fee election and ceiling, the 10-year priority term, the use
   review). A right that lives in a statute is law now and cannot be undone by revising agency
   policy. Sort each claimed exposure as **codified** (in statute) / **partial** (statute sets a
   ceiling or default but the operative number or metric is agency-set) / **not codified** (no
   statutory tether). A "not codified" implementation detail is where the real exposure is.

---

## The vulnerability filter (AO's three-layer sort)

An operator right is more or less exposed depending on where it lives. **Run this sort on every
provision before anything else.**

| Layer | Anchor | Exposure | What it takes to change |
|---|---|---|---|
| 1 — **CFR** | Code of Federal Regulations (36 CFR 251, 294, …) | **Protected** — low exposure | APA notice-and-comment rulemaking |
| 2 — **Manual** | FSM / BLM Manual / NPS Management Policies | **Partially protected** | Deviation needs a documented public-interest justification |
| 3 — **Handbook / guidance only** | FSH / BLM Handbook / SOPs / regional & forest supplements | **Fully exposed — the vulnerable zone** | A line officer can change or drop it without public notice |

**Statute sits above all three.** It is a *check*, not a fourth row of the sort: a statute cannot
be undone by revising a Manual or Handbook. When a provision purports to change a fee or permit
rule, check whether a statute already anchors it before you assert exposure.

The rule this produces is two-sided, and it is the spine of the scan:

- A right that exists **only at Layer 3 (Handbook)** is a concern factor the moment the docket
  makes Handbooks advisory or discretionary — **even if the docket never names that provision.**
- A docket that **moves** a right downward (binding → advisory, Manual → Handbook, CFR → "delegated
  to directives") is itself a concern factor, because the right becomes discretionary.

**Watch the delegation gap specifically.** The highest-value target is where a CFR section
*delegates* a standard to "applicable Forest Service directives" (or similar). If the docket then
makes those directives advisory, the CFR commands a rule that no longer binds — there is no
enforceable standard against which to measure the decision. Always identify the layer the *right*
sits in, not just the layer the *docket* is written in.

---

## The decision procedure

For the one provision in front of you, answer these in order. **Stop at the first hard NO.**

1. **What does it actually do?** State the operative change in one sentence, in the agency's own
   vocabulary — not the press-release framing. A provision that "clarifies" or "streamlines"
   often does something concrete to an operator's rights; find the concrete thing. Read the
   agency's actual words, and comment on what they *wrote*, not what you remember. If you cannot
   name a concrete change, it is preamble, not provision — **NO** (record why).
2. **Which concern dimension does it touch?** Map it to the categories below. If it touches
   none, **NO**.
3. **Does it touch YOUR concern?** Your persona lists what you care about and what you do NOT
   care about. If it lands in your "do not care" list, **NO**. If it touches yours *and* another
   concern's, still **FLAG** — do not drop it because someone else also cares.
4. **Is it material?** A touch is not a flag. Ask the four questions AO ranks each row by:
   (a) **operational hit** — what does an operator concretely lose or pay; (b) **risk of silent
   change** — can this be altered without notice because of the layer it sits in; (c) **fix
   direction** — is there a clean home for it (CFR / Manual / leave with a notice-and-comment
   carve-out); (d) **who is exposed** — does it reach AO members (holders of federal
   authorizations) or only someone else. No material operator consequence = **NO**.
5. **Negative-space check — read for what is LEFT OUT.** An illustrative list of covered
   activities, occupations, or disciplines that **omits** guiding disciplines (hunting, fishing,
   climbing, rafting, kayaking, canoeing, horseback/backpacking guides and instructors) is a
   concern even when the text says nothing about outfitters — omission is the mechanism. Also
   watch for: a definition that is missing, a category not enumerated, an analysis the docket
   declines to run (small-business / aggregate effects / a missing alternative).
6. **Reach check.** AO's members hold federal authorizations (USFS SRPs/SUPs, BLM SRPs, NPS
   CUAs, FWS refuge permits). If the provision cannot reach a holder of one of those — e.g. it
   governs indoor/urban activities or a different regulated class — it is noise. **NO**.

**Answer: YES** (flag, write a brief) **or NO** (write a one-line negative with the reason).

---

## Read every provision through BOTH member lenses

AO splits its members two ways, and a good scan keeps both in view on **every** provision:

- **(a) Operators whose product IS the setting** — multi-day river trips, backcountry hunts,
  pack-and-stock, foot-based trips in primitive/semi-primitive settings. Their exposure is to
  anything that degrades or opens the setting itself.
- **(b) Operators whose exposure runs through access and infrastructure** — developed sites,
  resorts, campgrounds, motorized/vehicle tours, shuttles, short programs for school groups,
  beginners, or limited-mobility clients. Their exposure is to roads, trailheads, put-ins, and
  developed facilities.

The same provision can help one and hurt the other (a road reopening helps (b) and hurts (a)).
Your brief must say *which* member group the consequence lands on. If you cannot place it, you
have not finished reading it.

---

## The concern categories (AO's own subject taxonomy)

A provision is in AO's scope when it changes one of these. The categories come from AO's own
gap-analysis columns, matched to the agency's exposure categories. Your single concern maps to
one or more of them; use the list to recognize a real touch — **do not universalize any of them.**

- **Fee methodology** — flat-fee vs %-of-AGR election, AGR calculation methods and "base trip
  payment," short-stop fee, minimum annual / assigned-site fee and its escalation index,
  service-day counting (drop-off / pick-up / livery), cost-recovery charges, GRFS mechanics,
  proration / refunds. *(The fee-election and %-ceiling are codified by statute; the operative
  rate, the index, and the counting rule are not — that is where the exposure lives.)*
- **Issuance / renewal / termination** — priority-use term length, renewal-without-competition,
  probationary terms, performance-review frequency and "satisfactory" definition, temporary-use
  issuance, revocation/suspension and debarment grounds.
- **Operational constraints** — use-reduction formulas, "extent necessary" / minimum-requirements
  analysis for wilderness improvements, seasons, group size, capacity.
- **Capacity / geographic allocation** — resource-capacity analysis, the outfitted vs
  non-outfitted and priority vs temporary split, use-area boundaries.
- **Scope-defining terms** — the definitions of *outfitting, guiding, priority use, temporary
  use, service day, quota, use area, holder* (these decide who needs a permit at all), and the
  "significant vs non-significant" operating-plan change line.
- **Appeal / objection procedures** — what is and is not appealable, notice-and-comment
  exemptions, cure periods and their quantification, agency action timeframes, NEPA categorical
  exclusions, comment windows.
- **Reporting requirements** — actual-use reports, financial / income statements, the data link
  back to oversight and fee true-up.

**Agency-scope cautions (do not universalize).** "Renewal-without-competition" is a USFS
priority-use concept — it means something different, or nothing, at other agencies and in
non-permit rulemakings. The flat-fee vs %-of-AGR election is USFS and BLM only — do not read it
onto NPS or FWS. "Extent necessary" means different things at different agencies. Drop generic
words like "sports" that do not appear in the source material — use AO's real vocabulary instead.

---

## The trap list (failure modes — re-check before you answer)

The ways an AO scan goes wrong, as recorded by AO itself. Run them again right before you
finalize YES/NO.

- **Temporal confusion** — citing a superseded version. Fix: name the amendment number and
  effective date; if you cannot, you are not grounded.
- **Hierarchical hallucination** — treating an advisory Handbook note as binding law, or a
  binding CFR right as mere guidance. Fix: state the layer; a Layer-3 right asserted as "the
  law" is a hallucination.
- **Jurisdictional blurring** — applying one agency's rule or a forest supplement to a different
  agency or to national analysis. Fix: name the agency and the scope (national / regional /
  forest).
- **Over-broad flagging** — flagging preamble, aspirational language, or general policy as if it
  were an operative rule. This is the "flags everything = worthless" failure. Fix: you must be
  able to name the concrete operator consequence before you flag. AO's own discipline is to rank
  and take only the top targets — never an exhaustive spray.

---

## Output

**If NO** — write a one-line negative with the reason, so the decision is auditable:
`NO — <concern> — <why> (layer / does not touch / already statute- or CFR-protected / other
agency / no material operator consequence / ungrounded temporal cite)`.

**If YES** — write a **brief** into the provision's directory, in your concern's voice. A brief
is short and operator-facing; it is NOT a summary of the docket, NOT a legal argument, and NEVER
a draft public comment. Structure:

1. **Header** — docket # / RIN / agency / provision cite / your concern name.
2. **Provision and citation** — quote the operative text verbatim (short, ≤ ~40 words) with its
   location: layer + citation + amendment number / effective date.
3. **Where it sits** — the layer, and whether the docket moves it downward (the exposure). Name
   the fix *direction* (CFR / Manual / leave with a notice-and-comment carve-out) — but do not
   assert the specific statutory or CFR pin; that is discovered downstream by `find-statute.md` /
   `find-regulation.md`.
4. **Operational consequence** — what the operator concretely loses or pays: what they can no
   longer plan for, what a lender or buyer would no longer pay for, which specific place or right
   changes. Use AO's words (service day, use area, priority use, renewal, cost recovery), not
   generic "regulatory burden" language. Tag impact **high / medium / low** using the
   operational-hit test so downstream prioritization is cheap.
5. **Three-way label (keep these separate, never blend):** (a) what the source says; (b) what the
   source is silent on; (c) the concern implication for your persona. This is AO's citation
   discipline and it is mandatory.

When the docket asks a specific question, answer *that question* in the agency's vocabulary (e.g.
if it invites comments on which provisions are essential to safety / compliance with law /
preventing waste or misuse of public funds, map your consequence to those three words — they are
the agency's own ranking criteria). The brief is the input to the next stage (`find-*` /
`download-*`), which you do **not** run — you locate and fetch nothing; those skills run after
you, on the provisions you flag.

---

## Quality gates (self-check before you return)

- [ ] Ran all five grounding checks (temporal / hierarchical / jurisdictional / source-integrity / statute cross-check).
- [ ] Placed the provision in the correct layer, with a current citation (amendment # / date).
- [ ] Quoted verbatim; kept source-says / silent / implication separate.
- [ ] Named the concrete operator consequence — no flag without one.
- [ ] Stated which member group (product-is-setting vs access-and-infrastructure) the consequence lands on.
- [ ] No drafted comment language, no "AO should argue," no prediction of agency motives or outcomes.
- [ ] Did not assert a specific statutory/CFR pin — left that to `find-*`.
- [ ] Calibrated: did not flag a preamble paragraph; did not dismiss a real operator right as noise.
- [ ] Brand: "AO" or "America Outdoors," never "AOA."
- [ ] Flagged any OCR/derived text before relying on it.

---

## Domain reference (compact)

**Agencies → authorizations:** USFS — SRPs/SUPs, Priority Use Permits, Temporary Use Permits,
cost recovery (36 CFR 251 subpt B). BLM — SRPs (Form 2930-2), wilderness "extent necessary,"
Travel Management Plans. NPS — CUAs, Concession Contracts (54 U.S.C. §101913). FWS — refuge
Special Use Permits.

**Fee vocabulary:** flat fee vs % of AGR, short-stop fee, minimum annual fee, assigned-site fee,
GRFS (gross sales / gross fixed assets), service-day counting (drop-off / pick-up / livery),
base trip payment.

**Tenure vocabulary:** renewal-without-competition, priority use, temporary use, probationary
term, use-reduction, reallocation, existing-holder preference, transfer / succession.

**Statutory anchors (Layer check — when a provision purports to change a fee or permit rule,
verify whether a statute already anchors it; do not assert the pin yourself):** EXPLORE Act,
FLREA, Wilderness Act, FLPMA, Antiquities Act. The *specific* statutory citation for a flagged
provision is discovered downstream by `find-statute.md`, not stated here.

**Terms of art — quote verbatim on first use, then define:** "extent necessary," "wilderness
character," "roadless area characteristics," "recreation opportunity spectrum," "use area,"
"service day."

---

## References

- `../architecture/ops-mds.md` — defines this file (the scan skill; first machine scan; judgment
  skill, no backing MCP) and the find-vs-download split (find-* locates, download-* fetches).
- `../../Project-Overview.txt` — the scope source: the shared skill set, one agent = one concern
  strictly, the first machine scan, the brief into the provision directory.
- `../personas/meta-data-agent-shared.md` (the shared half) and
  `../personas/meta-data-agent-concern/*.md` (your per-agent concern — your only lens).
- Source of the method (AO's own operating material): "AO Docket Auditors Reference Dump" (the
  three-layer filter, citation rules, the AI failure modes, letter format), the "AO_IOGA FSH Gap
  Analysis" (the subject categories and per-provision exposure method), and the case folders'
  `02_Notes/` scratchpads and `03_Outputs/` filed letters (the step-by-step working method).
