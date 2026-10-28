# sudo-fleet — documentation

Living documents for the repository.

Before any of it, one idea: this repository is the **product**, not one running
fleet. Read [`REPOSITORY-VS-INSTANCE.md`](REPOSITORY-VS-INSTANCE.md) first — it
governs every other document here.

## Read this if you are a person

Four documents are written for someone deciding what this thing is and whether
it works. The rest are reference you open when something breaks.

| Read | When | Takes |
|---|---|---|
| [`../README.md`](../README.md) | You want to install it. Three commands. | 2 min |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | You want to know how it works, or you are about to change it. | 15 min |
| [`OPERATIONS.md`](OPERATIONS.md) | Something is broken and you need the symptom table. | On demand |
| [`REPOSITORY-VS-INSTANCE.md`](REPOSITORY-VS-INSTANCE.md) | You are about to commit something and are not sure it belongs. | 5 min |

If you only ever read one, read `ARCHITECTURE.md`. Everything else assumes it.

## Read this if you are an agent

The documents below are written to be used, not read end to end. Each one is
loadable on its own and states its own scope. When a task touches one of these
areas, load the matching document instead of inferring from nearby code — the
prose carries the failure modes that the code does not comment.

- Changing the deploy path → `ARCHITECTURE.md` §4 (ports) and §9 (lifecycle)
- Touching the comm layer → `COMM-LAYER.md`
- Adding or moving a directory → `COMPONENTS.md`
- Deciding whether something belongs in the repo → `REPOSITORY-VS-INSTANCE.md`
- After a complex change → `CHANGE-PROTOCOL.md`
- Before claiming a fact about the system → `DOC-FACTS.md` says whether it was
  verified and where

`DOC-FACTS.md` exists so a claim can be checked rather than trusted. If you
assert something and it is not there, add it with its evidence.

## Full index

| Document | What it is | Written for |
|---|---|---|
| [`REPOSITORY-VS-INSTANCE.md`](REPOSITORY-VS-INSTANCE.md) | The distinction between the repository and any instance of it, and the rules that follow. | both |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | The system as built: factories, per-agent shape, port scheme, queue, observability, identity, lifecycle. | both |
| [`OPERATIONS.md`](OPERATIONS.md) | Deploy, inspect, debug, recover. Symptom-first, with a failure table. | human |
| [`COMM-LAYER.md`](COMM-LAYER.md) | The communication contract: three tools, addressing, the gate, the transport, and what it does not guarantee. | both |
| [`COMPONENTS.md`](COMPONENTS.md) | Every directory, and whether it is fleet infrastructure or optional tooling. | both |
| [`CHANGE-PROTOCOL.md`](CHANGE-PROTOCOL.md) | The four checks after a complex change: runtime, config drift, auth, exposure. | both |
| [`DOC-FACTS.md`](DOC-FACTS.md) | Every checkable claim, with where it was verified and its status. | agent |
| [`KNOWN-ISSUES.md`](KNOWN-ISSUES.md) | Open defects with evidence. | both |
| [`SPEC.md`](SPEC.md) | The original design contract. Decisions stand; details were built differently. Read its status note. | human |
| [`NEXT.md`](NEXT.md) | Agreed next direction: multiple fleets in one cluster. Not built. | human |
| [`IMPROVEMENTS.md`](IMPROVEMENTS.md) | Historical backlog. Check against the code before acting. | human |
| [`PAPERCLIP.md`](PAPERCLIP.md) | The optional control plane. | both |
| [`verifications/`](verifications/) | Dated verification records for specific changes. | both |

## Phase records

Dated records of a change, with the evidence behind it. Read the one covering
the area you are about to touch; they carry the measurements the prose above
does not.

| Document | What it records |
|---|---|
| [`h1-P1-A-REPORT.md`](h1-P1-A-REPORT.md) | Phase 1 record: the pinned base, the deleted memory patch, and the `setup.sh` retag hazard. |
| [`hermes-v0.22.5-build-result.md`](hermes-v0.22.5-build-result.md) | Phase 1 record: the build checks on the v0.22.5 image, and what "the patch is gone" was measured with. |
| [`hermes-v0.22.5-plugin-compat.md`](hermes-v0.22.5-plugin-compat.md) | Phase 1 record: whether the two plugins still fire on v0.22.5 — all nine hooks, at the fire sites. |
| [`P1-B-MEMORY-AND-IDENTITY.md`](P1-B-MEMORY-AND-IDENTITY.md) | Phase 1 record: the memory budget, the memory instruction, and where it does and does not reach. |
| [`P2-C-MEMORY-CONTRACT.md`](P2-C-MEMORY-CONTRACT.md) | Phase 2 record: the memory contract the agent is actually told, and where it is enforced. |
| [`h5-P2-E-REPORT.md`](h5-P2-E-REPORT.md) | Phase 2 record: the documentation audit — what was false, what it says now, and where a stranger still gets stuck. |

## Keeping these honest

A document is a claim about the code. When the two disagree, the code wins and
the document is the bug. When a change makes a sentence here false, fix the
sentence in the same change — do not leave a stale page for the next reader to
trip over.
