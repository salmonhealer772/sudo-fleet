# sudo-fleet — documentation

Living documents for the repository. This is the index; start with the first two
rows and read the rest as the work requires.

Before any of it, one idea: this repository is the **product**, not one running
fleet. Read [`REPOSITORY-VS-INSTANCE.md`](REPOSITORY-VS-INSTANCE.md) first — it
governs every other document here.

## Start here

| Document | What it is |
|---|---|
| [`REPOSITORY-VS-INSTANCE.md`](REPOSITORY-VS-INSTANCE.md) | The distinction between the repository and any instance of it, and the rules that follow from it. Its own thing; read before changing anything. |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | The system as built: the two factories, per-agent shape, port scheme, queue, observability, identity, lifecycle. |

## Operating a fleet

| Document | What it is |
|---|---|
| [`OPERATIONS.md`](OPERATIONS.md) | Deploy, inspect, debug, and recover a fleet. Symptom-first debugging and a failure table. |
| [`COMM-LAYER.md`](COMM-LAYER.md) | The cross-agent communication contract: the three tools, the addressing model, the gate, the transport, and what it does not guarantee. |
| [`CHANGE-PROTOCOL.md`](CHANGE-PROTOCOL.md) | The mandatory four checks after a complex change: runtime, config drift, auth, exposure. |

## Design and direction

| Document | What it is |
|---|---|
| [`SPEC.md`](SPEC.md) | The original design contract. Decisions still stand; several details were never built or were built differently. Read the status note at the top before trusting any figure in it. |
| [`NEXT.md`](NEXT.md) | The agreed next direction: multiple independent fleets in one cluster, one namespace per project, with pause and resume. Not built. |
| [`IMPROVEMENTS.md`](IMPROVEMENTS.md) | Historical backlog. Superseded in places by shipped work; check against the code before acting on an entry. |

## Reference and records

| Document | What it is |
|---|---|
| [`DOC-FACTS.md`](DOC-FACTS.md) | Every checkable claim in these documents, with where it was verified and its status. Read this when you doubt a sentence. |
| [`KNOWN-ISSUES.md`](KNOWN-ISSUES.md) | Open defects with evidence. Includes the 2026-10-27 documentation-pass findings D1–D6. |
| [`MARC_CAESAR_STATUS.md`](MARC_CAESAR_STATUS.md) | Historical: the router-pair onboarding story. Note that the identity packages it describes have since been removed; see `KNOWN-ISSUES.md` D1. |
| [`verifications/`](verifications/) | Dated verification records for specific changes. |

## Not documentation

- [`../SOURCE-OF-TRUTH.md`](../SOURCE-OF-TRUTH.md) — which repository owns which
  content (factory here, workload elsewhere).
- `../PAPERCLIP-INTEGRATION-STATUS.md` — the control-plane integration record,
  kept at the repository root for historical reasons.

## Keeping these honest

A document is a claim about the code. When a claim and the code disagree, the
code wins and the document is the bug. When a change makes a sentence here
false, fix the sentence in the same change — do not leave a stale page for the
next maintainer to trip over. `DOC-FACTS.md` exists so that a stale claim is
findable rather than merely wrong.
