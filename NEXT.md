# Next direction: multiple project fleets, one cluster

**Recorded 2026-10-01 with Aidan. Status: direction agreed; implementation not started by this change.**

sudo-fleet has reached a usable foundation. The point of the next step is to
put that foundation to work for Docket Atlas and America Outdoors (AO), not to
restart the infrastructure build or invent a generic SaaS platform.

There is **no completed Docket Atlas product yet**. We have tools and earlier
demo components; we are about to combine them into the lobbying/research
workflow. The intention is to fork and modify this base for Docket Atlas,
keeping general fleet machinery reusable and AO-specific behavior in the
application layer. No fork is created by this documentation change.

## The next capability

Move from **one installation = one fleet** to:

> **One Kubernetes cluster, multiple separate fleets, one namespace per project.**

Each project owns its agents, orchestrator, working memories, research state,
queue state, and scoped data access. A project can contain one docket or several
related dockets. It must be possible to turn a project on and off without losing
its work or interrupting another project.

An **optional common namespace** that project namespaces can talk to is part of
the proposed direction, not a settled service inventory. It could host model
access, public regulatory-data access, fleet templates, and lifecycle management.
It must not silently become shared project memory or a shared research
orchestrator. Shared facilities; separate project brains.

Illustrative names, not a CLI or deployment contract:

```text
cluster
├── fleet-platform                 # optional shared services / lifecycle
├── ao-project-wilderness          # its own fleet, queue, state and access
└── ao-project-permits             # another independent fleet
```

## What belongs in the base repo

Make fleet identity first-class alongside agent identity:

- **Addressing and spawning:** create agents inside a selected fleet/namespace;
  the same agent name can exist in different fleets without collision.
- **Discovery and communication:** list, message, inspect and read queue results
  within the caller's fleet by default. Cross-namespace access is explicit and
  limited to approved services, not a cluster-wide sibling list.
- **State and access:** scope queues, credentials, service accounts, storage,
  configuration and resource budgets to the project.
- **Lifecycle:** create, inspect, pause, resume, save, restore and explicitly
  delete a fleet as a unit. These are desired operations, not existing commands.
- **Templates:** seed a fresh fleet from clean agent identities, skills, tools
  and configuration. A reusable template is different from a saved project's
  private memories and research history; do not copy those into new projects.
- **Compatibility:** preserve the usable single-fleet path while introducing
  fleet scope deliberately. Do not silently move or redeploy existing agents.

### Off means paused, not deleted

A namespace has no native power switch. The lifecycle layer must implement it:

1. Stop admitting new work and suspend scheduled triggers/autoscaling that could
   wake the project back up.
2. Drain active work or checkpoint/requeue it according to an explicit policy.
3. Persist queue and project state, then scale project compute to zero.
4. Resume from that state when switched on again.

Keep the namespace and persistent data. Deletion is a separate, explicit action.
Queue persistence and pod restart are not, by themselves, scan checkpointing or
exactly-once execution; replayed jobs need safe handling. Pausing compute does
not eliminate storage or shared-cluster costs.

### A namespace label alone is not isolation

Current fleet mechanisms include host networking, node-global ports/Redis
addresses, privileged agents, Docker socket access and host-side discovery.
Those assumptions need review, not just an extra `-n` on kubectl calls.

Project agents need namespace-scoped RBAC, network policy, credentials and
storage permissions. They must not use host-level privileges to bypass project
boundaries. Privileged lifecycle administration belongs in a separately trusted
management role, not every docket investigator. The exact deployment profile
and compatibility path remain to be designed; the historical GKE Autopilot
target cannot be assumed to accept the existing k3s privilege/network model.

## First implementation slice when we pick this up

1. Trace namespace/name/port assumptions through both factories, deployment
   scripts, comm discovery, queue keys/backing, state paths and save/restore.
2. Define fleet identity and the pause/resume contract, including work already
   in flight. Decide which shared services, if any, the first slice needs.
3. Prove two small fleets in different namespaces, including repeated agent
   names, local-only discovery and denied cross-project state/tool access.
4. Pause one fleet, keep the other working, then resume the paused fleet with
   its memories, artifacts and queued work intact. Test restart/replay behavior.
5. Prove fleet save/restore and the existing single-fleet path still work.

Use throwaway test fleets. This note does not authorize migrating live agents,
changing cluster infrastructure or implementing the above immediately.

## Then: build the AO intelligence on top

Once the base supports independent fleets, focus on **AO-informed agents and
agent behavior**, and test what actually works:

**scan → flag → verify → package → hand to AO.**

The immediate deliverable is a review bundle containing the relevant **docket
passage + statute + regulation**, with a supported explanation and explicit
uncertainty. AO decides whether to act. An agent's agreement, a runtime log or
a plausible citation is not legal verification. No autonomous filing.

The existing Docket Atlas plans provide seven regulatory lenses: wilderness
access, permit tenure, fees/cost recovery, travel/access, NEPA/objection windows,
capacity methodology, and labor/operational mandates. Experiment with how agents
use those skills, split documents, retrieve authorities, investigate omissions,
challenge findings and retain AO feedback within a project. Seven skills do not
require seven permanently running agents.

Historical dossier material included demand-driven intake and downstream
comment/survey drafting. The current direction above is continuous scanning
with verified bundles for human review; do not silently restore the old scope.

**Division of responsibility:** sudo-fleet manages reusable, independent fleets;
the Docket Atlas fork teaches them how to investigate for AO. Namespace support
is the next enabling step, not a reason to delay the domain experiments behind
unrelated platform work.
