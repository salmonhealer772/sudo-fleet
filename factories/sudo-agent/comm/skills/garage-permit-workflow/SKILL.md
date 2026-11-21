---
name: garage-permit-workflow
description: Santa Barbara residential garage build — the permit ground truth: what a permit-ready plan set must contain, the minor-exempt threshold, setbacks, site-plan requirements, governing codes, the submittal path, and the reality check that AI-drawn plans are working material, not a licensed stamp. Load before drafting garage plans or assembling the permit package.
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [garage, permit, santa-barbara, building-code, zoning, architecture]
---

# Garage permit workflow (Santa Barbara)

Ground truth for taking a residential garage build from idea to a permit-ready plan set and a complete permit application package. This is the verified baseline; do not re-derive it.

## The key submittal
A well-prepared plan set is the key permit submittal. Plans must be:
- complete, accurate, legible, and drawn to scale;
- each sheet labeled with address / unit / floor / level and marked "existing" / "as-built" / "proposed".

## Minor exempt work
A one-story detached accessory structure of 120 sq ft or less is exempt from permit.

## Setbacks
- Standard new-construction ADUs need at least 4 ft rear + side setback.
- Legally permitted existing garages being converted are exempt from setbacks.

## Site plan requirements
Site plans must include:
- the assessor's parcel number (APN);
- lot dimensions;
- zoning designation;
- recorded easements / deed restrictions.
Source: Santa Barbara County Assessor / city GIS.

## Governing code
- California Building Code (CBC).
- Santa Barbara Municipal Code § 22.04 (local amendments, including High Fire Hazard Area rules per Santa Barbara Fire Department).

## Submittal path
- Authority: City of Santa Barbara Building & Safety Division.
- Forms: santabarbaraca.gov/services/construction-land-development/forms-applications
- The "Project Plan Submittal Guide" is the checklist to follow.

## Reality check (do not lose this)
AI-drawn plans are working / communication material, NOT stamped or signed technical documents. A permit requires a licensed professional's stamp. This agent prepares the package and supports the architect; it does NOT replace the licensed stamp.

## How to use
- Draft plans with the archlang skill (floor plans as code); validate and gate on soundness before shipping.
- Run code-compliance and egress checks with the building-code-egress-review skill.
- Draft any zoning variance narrative with the zoning-variance-application-narrative skill.
- Assemble the final plan set and permit package in Google Drive / Docs / Sheets through google-workspace.
