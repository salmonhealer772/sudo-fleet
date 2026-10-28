# The repository and an instance

sudo-fleet exists at two levels, and they are not the same object.

The **repository** is the product: `setup.sh`, the factory trees, the manifest and
config templates, the communication contract, the queue contract, the port scheme,
and the documentation describing all of it. It is general purpose — written for a
Linux machine that has never run it, cloned by someone with no relationship to the
people who wrote it, embedded in other software as a component.

An **instance** is one use of that product: one Linux machine, or one k3s cluster
on one laptop, running some number of agent deployments, with names, keys,
addresses, and state that belong to whoever stood it up. Neither defines the other:
the repository describes no particular instance, and an instance describes no
repository, so one deployment and a dozen are equally valid instances of it.

**The consequence for maintainers is direct.** A change here is a change to a
product whose users are not in the room, so it must be justified for a generic
user: a different machine, different model keys, a different number of agents, a
different set of names. "It is required on this host" is not a justification for a
repository change; it is a justification for a local configuration change, and the
generic requirement wins.

## What belongs to which side

| Material | Side | Note |
|---|---|---|
| `setup.sh`, `bin/*.sh`, factory `up.sh` / `down.sh` | Repository | the factory itself |
| Manifest and config templates | Repository | shapes, not values |
| Communication contract (`list-siblings`, `message-agent`, `check-agent`, the load-skill gate) | Repository | identical for every user |
| Queue contract (per-agent MCP door, Redis backing, ordering rule, direct and inbox modes) | Repository | semantics, not endpoints |
| Port scheme (bands and the derivation function) | Repository | see the contrast below |
| `docs/SPEC.md` and the contract files under `comm/docs/` | Repository | describe the product |
| The default seed pair (one planner, one engineer, from committed glimors) | Repository | a default, not a fixed roster |
| Hostnames, node addresses, IPs | Instance | never repository material |
| Deployed agent names, and which agents exist at all | Instance | a local decision |
| Agent count, pod count, restart counts, uptime, local checkout paths | Instance | changes hourly |
| API keys, sudo passwords, tokens, credentials | Instance | secrets |
| Personal identities, personas, running memory, state volumes, event logs | Instance | owner data |

Instance facts may appear in repository material only as **labelled examples**,
marked as an example in the same sentence that introduces them, never as the
definition of the thing being described.

## Why the confusion is expensive

**A document that names one deployment stops being a specification.** Once the
prose says "the fleet is these agents", it answers what happened on one machine in
October rather than what this product does. The next user cannot tell requirements
from recollections; the document becomes a memory with a version number.

**A requirement derived from one host breaks every other user.** A rule that holds
because of one machine's kernel, port occupancy, or pinned runtime is not a
property of the product. Encoded as a requirement it fails on the next user's host,
and the failure looks like a bug in the software rather than a fact about a laptop.

**A public repository that carries live agent identities leaks their owners.**
Agent names, personas, and saved state are not neutral strings: they encode who
someone is, what they work on, and how they talk. Committed once, every clone
carries them.

## Rules that follow

1. **Do not harden an instance fact into a requirement.** If a rule exists because
   of one host, state it as an observation about that host or leave it out. Only
   invariants that hold for any conforming install are requirements.
2. **Do not name a specific agent as the canonical one.** Contracts take a `sibling`
   parameter and a prompt, not a preferred target; no document designates one
   deployment as the reference.
3. **Mark every example**, in the same sentence that introduces it, with values
   that are obviously placeholders.
4. **Keep secrets and personal identities out of the repository.** Keys, passwords,
   tokens, personas, and state belong to the instance: the template carries a
   placeholder, the instance carries the value.
5. **Use a neutral example when a running example is needed.** A single planner plus
   a single engineer, named generically, demonstrates any mechanism here; those are
   the shapes the two factories produce. A real deployed name is never required.
6. **Describe the scheme, not the assignment.** The derivation, the band, and the
   collision rule are repository material; the numbers an install derives are not.

## Worked contrast

### Which agents exist

*Describes an instance:* "The fleet runs these agents", followed by a list of
specific deployment names, their roles, and their count.

*Describes the product:* the repository ships two factories, one for planners and
one for engineers, plus a default seed pair (a single planner and a single engineer)
that a user may rename, replace, or multiply. How many agents exist, and what they
are called, is decided per instance. The roster is discoverable at runtime through
`list-siblings`, which is why no document needs to enumerate it.

### What ports are used

*Describes an instance:* a table of concrete port numbers observed on one host,
presented as the product's port allocation.

*Describes the product:* every per-pod MCP surface has a stable Service port of
`8000` and an internal port derived deterministically from the agent name, because
each agent pod runs `hostNetwork: true` and a fixed port would collide. The Hermes
`api_server` listener is confined to `61000-65535`, a band above the MCP and watch
window (`8000-29999`), the NodePort and ephemeral ranges, and the offline Redis
fallback, so it cannot collide with any of them by construction. Queue Redis is
node-global and therefore one instance per factory: the planner queue owns `6379`
and the engineer queue owns `6380`, and the bring-up aborts loudly rather than
binding a port already held. Those are properties of the scheme; the values a given
install derives follow from its own agent names.

### What an agent can reach

*Describes an instance:* named agent A can message named agent B, and reads B's
stream at a specific address on a specific node.

*Describes the product:* the mesh is full. Any agent may message any sibling through
that sibling's per-agent MCP surface, and read any sibling's watch surface at any
depth. The documented address form is the per-agent Service
(`sudo-<name>-mcp:8000/mcp`); the deployment reality is that agent pods run
`hostNetwork: true` on a single node without cluster DNS, so a peer is reached on
the node at that agent's derived port. Reachability is a network surface only: it
grants no visibility into another agent's volumes or processes, which stay separate.
Web search is available only when a search provider key is configured; without one
the agents run with no web tool, and the bring-up says so.

## If you are cloning this repository

Cloning gives a factory, not a fleet. The repository supplies the scripts that
install docker and k3s on a bare Linux host, the two agent factories and their
images, the templates that turn a name into a Deployment, Service and PVC, the
deterministic port scheme, the MCP door and its queue, the watch sidecar, the three
communication tools with their skills and the load-skill gate, the persona block
that makes an agent aware of them, and the docs describing the contracts.

The default pair ships with **no identity**: `deployments/` holds only its
`README.md`, and `bin/k8s-up.sh` passes `--from-glimor` only when a saved package
exists, so a fresh clone deploys two clean agents. A saved identity is instance
material — gitignored by default, never part of the product.

The instance supplies what is specific to the user: an LLM API key and base URL
(one key serves both agent kinds), optionally a web-search key, the host it runs on,
the agent names, the personas and identities, any additional factories for other
agent kinds, and the saved state. None of these are in the repository, and none
should be added to it. A clone that never runs `setup.sh` describes nothing
and proves nothing; a clone that runs it produces one instance among many.
