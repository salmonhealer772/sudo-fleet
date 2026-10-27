# The cross-agent communication layer

The contract that lets any agent in a fleet reach any other agent: three tools, one addressing
model, one prerequisite gate, one transport, and one factory-managed persona block. This describes
the layer as implemented on both agent kinds — Hermes engineers (Python CLIs baked into the image)
and Letta planners (native mod tools) — so either half can be reimplemented from this document.
Example agents are named `alice`, `bob`, `carol`.

## 1. What the layer guarantees, and what it does not

**It guarantees reachability.** Any agent that exposes the `-mcp` + `-watch` service pair in the
discovery namespace can be discovered, messaged, and read by any other agent running these tools.
That is the whole guarantee: a name goes in, a live endpoint comes out, the call lands. Nothing is
cached, so an agent that appears shows up on the next roster read and one that is removed drops off.

**It does not guarantee any of the following:**

- **Team membership.** There is no team, project, group, or tenant field anywhere in the contract. A
  roster row is a name and two addresses. Nothing distinguishes "my colleague" from "an unrelated
  agent on the same cluster".
- **Grouping.** No notion of a pair, a squad, or a parent/child relation. The orchestrator/engineer
  split is a social convention the persona describes; the tools know nothing about it.
- **Namespace scoping.** Discovery is one hardcoded namespace; every service whose name matches the
  pattern is in scope.
- **Trust or authorization.** The prompt path carries no key, token, or allowlist. A per-agent key
  is an open question in the spec, not a shipped feature.
- **Identity.** A name is not an authenticated identity. Nothing verifies that the agent answering
  at `alice` is the agent deployed as `alice`.

The consequence, and the most important thing to understand here: **the roster is cluster-wide.**
Discovery is a plain service list with a name-pattern filter and no scope predicate, so on a busy
instance the roster is every agent on the box, including dozens of unrelated peers (the operator's
fact sheet records this as D6). An agent that reads the roster and messages the third entry is doing
exactly what the contract permits, and may be messaging a stranger. Reachability is deliberately not
membership.

## 2. The three tools

| tool | question it answers | surface |
|---|---|---|
| `list-siblings` | who exists, and how to reach it | roster list |
| `message-agent` | say something to a sibling, get its reply | MCP `tools/call` |
| `check-agent` | what has it been doing / what is it doing now | trail read |

A fourth surface, `queue-status`, is the recipient's: how an inbox reply is collected. On Letta it
is a registered tool (`queue_status`); on Hermes it is the `--queue` flag on `message-agent`. Names
are hyphenated as skills and CLI filenames, underscored as Letta tools.

### 2.1 list-siblings — the roster

- **Inputs:** none required. Optional `filter` (`--filter`): substring match on the bare name.
- **Output:** a list of entries, each `{sibling, mcp_host, watch_host}`. The table form is a header
  row, one row per agent, then a count line (`3 siblings`); `--json` emits the list. An empty result
  is not an error: it says there are no matching siblings for that filter, or no sibling agents at
  all, and exits 0.
- **Pairing rule:** an agent appears only if BOTH services exist. A deployment with an `-mcp`
  service but no `-watch` service is invisible, even though its MCP door is up.
- **When:** first, whenever the exact name is not already known. The other two tools raise on an
  unknown or ambiguous name rather than guessing.

### 2.2 message-agent — the prompt path

- **Inputs:** `sibling` (bare name), `prompt`, and optional `mode` (`inbox` | `direct`), `new_chat`
  (bool), `json` (bool), `source` (tag). The CLI adds `--queue` (read the recipient's inbox instead
  of sending) and `--show-command` (print the reach it would use).
- **Output:** `inbox` returns a message id immediately, parsing and re-emitting a JSON body when the
  reply is JSON. `direct` returns the sibling's reply — plain text, or a parsed object when `json`
  was requested. `--queue` returns pending messages plus recent results, each with `id`, `source`,
  `status`, and `reply`.
- **Default is `inbox`.** The older contract document still says `direct`; the shipped code, the
  persona block, and the spec's as-built note all say `inbox`. Treat `inbox` as correct and that
  contract line as drift.
- **`direct` blocks with no client-side timeout** — emitted as a very large per-call timeout rather
  than an absent one, so a long job is not cut. It is for the case where the answer is already in
  the sibling's head: a recall or a read, never work. Against a Hermes engineer, `hermes_prompt`
  does not return until that engineer finishes its entire turn, so a `direct` call asking for work
  can hang for as long as the work takes.
- **`new_chat`** is for planners: a fresh conversation instead of resuming the persisted one. It is
  not sent at all to a Hermes engineer, which is stateless.
- **`source`** is a stable tag (typically the sender's own name) grouping messages in the
  recipient's queue. A null source is coerced to the empty string on the wire, because the prompt
  tools' schema types it as a non-nullable string.
- **Kind is learned, not configured.** The Hermes CLI reads the Deployment's `app` label
  (`sudo-agent` vs `sudo-letta`) and caches it; the Letta mod reads the sibling's `tools/list` at
  initialize for `hermes_prompt`. The caller never picks the tool: `letta_prompt` for planners,
  `hermes_prompt` for engineers.

### 2.3 check-agent — the trail

- **Inputs:** `sibling`, optional `n` (trailing depth), optional `mode` (`full` default, or
  `compressed`).
- **`n`, identical in both modes:** `k > 0` = the last k entries; `-1` = the entire file with no
  depth cap; omitted = 100. Any other non-positive value is a usage error (exit 2 on the CLI, an
  error result on the Letta tool).
- **`full` output:** the `-watch` sidecar's `/events?n=N` — `application/x-ndjson`, one JSON object
  per line, `{ts, conversation, event, ...}`, event kinds `user`, `thinking`, `assistant`,
  `tool_call`, `tool_result`, `session`, `process_state`.
- **`compressed` output:** the plain chat transcript, read as a file — `kubectl exec` into the
  `watch` container, then `tail -n N` (or `cat` for `-1`) — not over HTTP: only spoken prompts and
  replies, no thinking or tool noise. The path depends on the sibling's kind: the planner's Letta watch
  directory or the engineer's Hermes transcript, with the alternative as a fallback.
- **"What is it doing right now"** falls out of the freshest entries of the same trail: the newest
  events carry the current conversation id and the latest `process_state` (idle vs active).
  `/status`, `/ps`, and `/stream` were retired from the contract — the sidecar still serves them,
  the tool no longer surfaces them.
- **A dead sidecar is reported as dead.** A payload holding not one valid event (an HTML error page,
  a 503, a proxy 404) is reported as "appears down", not rendered as pseudo-events; a mixed stream
  keeps its real events and marks the stray line `raw`.
- **When:** before messaging a sibling whose context matters, and to answer "idle or mid-run". A
  small `n` is the cheap live check.

## 3. The addressing model

An agent is addressed by **bare name**. The name resolves to a roster entry carrying two addresses;
the address's host is then resolved to a live cluster IP.

**Resolution order:** exact → case-insensitive → unique substring → `ambiguous` error listing
candidates → `not found` error. One implementation tries exact and case-insensitive as separate
steps, the others fold them; all treat more than one substring hit as an error rather than picking
one.

**Why a name given in a prompt does not always resolve.** Four distinct causes, worth keeping
separate:

1. **The bare name is not the deployment name.** `up.sh --alice` sets the agent name to `alice` and
   prepends one `sudo-` for the deployment, so the objects are deployment `sudo-alice` and services
   `sudo-alice-mcp` and `sudo-alice-watch`. Discovery strips exactly one leading `sudo-` and one
   trailing `-mcp`/`-watch`, so the roster entry is `alice`. An agent told to message "sudo-alice"
   fails: the roster has `alice`, and `sudo-alice` is not a substring of it.
2. **The double-prefix reality.** Names that themselves begin with `sudo-` are legal, and the
   maintainer-style names use them. Requesting `--sudo-alice` therefore produces deployment
   `sudo-sudo-alice` and services `sudo-sudo-alice-mcp` / `sudo-sudo-alice-watch`, whose bare name
   is `sudo-alice`. The short name `alice` now matches nothing; only `sudo-alice` works. This is
   also why the strip must be suffix-anchored: bare name = service name minus trailing
   `-mcp`/`-watch`, minus exactly one leading `sudo-`. Prefix-stripping alone, or repeated
   prefix-stripping, corrupts these names.
3. **Substring collisions.** On a busy cluster a short name given from memory ("alice", "bob") hits
   many siblings. That is an ambiguity error by design — the tool will not choose for the caller.
4. **The service name does not resolve as DNS from inside a pod.** Agent pods run with host
   networking, so they get the node resolver, not cluster DNS: `sudo-alice-mcp` does not resolve
   inside an agent. Every implementation resolves the service's cluster IP through the host
   transport and calls the IP. The address book is a cache, never the truth: an empty answer is
   never cached, a cached address expires after a short TTL, a failed call drops the entry and
   re-resolves once, and a failed re-resolve keeps serving the known address rather than losing a
   working endpoint.

A fifth, subtler cause sits behind these: kind. Two prompt tools exist, and a wrong guess produces
"tool not found" from the sibling rather than a resolution error from the caller. Both
implementations learn the kind, so the caller should not hardcode it.

## 4. The gate: load the matching skill before the tool runs

The rule is one sentence: a comm tool refuses to run until its matching skill has been loaded in the
current conversation. It is a stateful prerequisite gate — the same shape as "block the transfer
until the compliance check passed this session". Two implementations, one contract, two different
refusal paths.

**Hermes.** Three Python CLIs at `/opt/comm-tools/` (`list_siblings.py`, `message_agent.py`,
`check_agent.py`). Each calls a gate function as the first statement of `main()`, before any
transport is built, so a blocked call does no host work at all: no bridge container, no kubectl, no
MCP handshake. The gate reads the session id from the environment, reads a ledger at
`<HERMES_HOME>/comm-gate/state.json` shaped `{session_id: {skill_name: epoch}}`, and if the skill is
absent prints `BLOCKED: load the <skill> skill first, then retry.` to stderr and exits **69**
(sysexits `EX_UNAVAILABLE` — a distinctive code that is trivial to grep for). The second half is a
plugin that records skill loads on the skill-lifecycle hook keyed by session id, and separately
vetoes a terminal command naming one of the three CLIs when that skill is unloaded, so the block can
fire before the process starts and the model can correct itself in the same turn. State writes are
atomic and every hook is wrapped so a gate failure can never hurt the agent. With no session id in
the environment the gate allows the call — a human or script running the CLI keeps working. A
missing or corrupt ledger reads as "nothing loaded", the fail-closed side.

**Letta.** Each comm mod installs an observer on the events bus for the `Skill` tool's start event.
When the tool name is `Skill` and its `skill` argument equals this mod's skill name, the observer
records it in an in-memory map keyed by conversation id. The tool's `run` consults that map and
returns the string `BLOCKED: load the <skill> skill first (Skill tool), then retry.` as an ordinary
tool result — no exception, no throw. The observer never cancels or rewrites the skill call. A new
conversation starts blocked again.

**The failure modes, honestly.** The gate is a forcing function for a procedure, not a security
control, and it has three real gaps:

1. **Per conversation, not per context.** The gate proves "the skill was loaded at least once in
   this conversation", not "the skill text is still in context". On a long conversation, compaction
   can drop the skill's text while the loaded record persists, leaving a tool callable from
   half-remembered syntax. This is a known, documented gap.
2. **On Hermes the block can be unreachable.** There is no native `list_siblings` tool in a Hermes
   agent; the only entry point is the skill teaching the CLI path. An agent that never loaded the
   skill does not see a blocked tool — it sees no tool at all, and a prompt asking it to call
   `list_siblings` yields "Tool does not exist", not `BLOCKED`. The BLOCKED path requires the CLI to
   actually be run, which the gate and the plugin both cover. Letta is symmetric the other way: its
   comm tools are native, so the same prompt cleanly hits the block.
3. **In-memory state is lost on restart.** The Letta map dies with the process, so a fresh headless
   process starts blocked; the observer also only sees the skill tool, so a skill loaded by any
   other route is not recorded.

What the gate buys: the agent is forced through the skill once, where the exact syntax, the mode
choice, and the never-use-direct-for-work warning live. Without it, under context pressure, the tool
gets called from memory.

## 5. The transport — and its single biggest coupling

Every call goes through **the host**. Agents hold no kubectl, no kubeconfig, and no baked-in
phonebook; they borrow the host's cluster access through the agent's own mounted docker socket:

```
docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest \
  sh -c "nsenter -t 1 -m -u -i -n -p -- \
    env KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get services -n default"
```

A throwaway container joins the host's PID, mount, and network namespaces, enters host PID 1, and
runs the host's kubectl against the host's k3s kubeconfig. Every host-side read has that shape:

- roster → `kubectl get services` (namespace fixed)
- kind → `kubectl get deploy <deployment> -o jsonpath={.metadata.labels.app}`
- cluster IP → `kubectl get service <service> -o jsonpath={.spec.clusterIP}`
- compressed transcript → `kubectl exec deploy/<deployment> -c watch -- tail -n N <path>`

Only the two HTTP conversations skip the bridge, and only after the IP is resolved through it: MCP
`initialize` → `notifications/initialized` → `tools/list` (Letta only) → `tools/call` on port 8000
of the cluster IP, and `GET /events?n=N` for the full trail.

The Hermes transport walks a ladder rather than a single command: the docker bridge first, then a
bare `nsenter` (for a process already in the host namespaces), then plain host execution. The whole
ladder is retried a few times with a short linear backoff, so one k3s blip or one cold docker daemon
does not sink a call; a final failure raises an error carrying every attempt. The Letta mods use the
bridge form only, with a hard timeout that kills the child.

**The consequences are structural:**

- **The container needs the docker socket, and the right group id.** The socket is bind-mounted into
  the agent container. `privileged` is not enough on the Hermes side: its entrypoint drops to a
  non-root user, and that drop rebuilds supplementary groups from `/etc/group`, so a pod-level group
  does not survive it — the entrypoint must arm the socket's real group id before the first drop.
  The Letta side has no such drop and runs as the image user, so its deploy reads the socket's group
  id at render time and grants it as a pod supplemental group. A group id baked into an image is
  wrong on any host whose docker group differs, and that breaks all three tools at once, silently,
  as "permission denied" from the bridge.
- **The discovery namespace is fixed.** `default` is hardcoded in every implementation, in both
  languages, with no flag and no fallback.
- **A host without a docker socket cannot serve this layer as written.** There is no in-cluster
  discovery path to fall back to. No socket, no roster, no messaging, no trail.
- **The bridge is host-root-equivalent.** Privileged plus host PID plus the host filesystem mounted
  means anything that can run docker there can run arbitrary host commands. That is the trust
  boundary the layer stands on, and why "the roster is cluster-wide" deserves the emphasis it gets.

## 6. The persona block

The third layer is a short awareness block — what the fleet is, what the three abilities are, and
that the matching skill must be loaded before the tool runs. It is one shared snippet file,
byte-identical on both sides, and it is **factory-managed**.

On every boot the entrypoint applies the snippet to the agent's persona file (`SOUL.md` for a Hermes
engineer, the system persona for a Letta planner) between two fixed markers,
`FLEET-COMM-AWARENESS-BEGIN` and `FLEET-COMM-AWARENESS-END`. If both markers are present the content
between them is replaced; if either is missing the whole block is appended. **Nothing outside the
markers is ever touched** — anything an agent writes after the END marker survives every boot and
every redeploy.

Because it is applied on every boot rather than once, two failures cannot happen: an agent cannot
permanently delete its fleet awareness, and an agent cannot keep running a stale version after the
image ships a new snippet. Rebuilding the image is enough to update every agent's awareness on its
next restart.

The skills are deliberately the opposite: seeded into the Hermes home on first boot only, guarded by
a marker file, because the agent may edit them and a re-seed every boot would clobber those edits.
The persona is the one layer safe to re-assert unconditionally, so it carries the guarantee.

## 7. Why a tool, a skill, and a persona — all three

Each layer fails alone, and each failure is different:

- **A tool alone is ignored.** The mechanism exists, the agent has no reason to reach for it, and
  the capability sits unused — the recorded lesson behind this design is that capability without
  persona awareness does not get used. The persona is what turns "the plumbing can do this" into
  "this is my job".
- **A skill alone is not reachable.** On the Hermes side a skill is documentation for a command-line
  path; nothing runs it. Without the tool there is nothing to run, and without the persona the skill
  is never opened. A skill is a procedure with no trigger.
- **A persona alone names capabilities that do not exist.** The agent confidently calls a tool it
  does not have, or reconstructs the syntax and gets it wrong.

So: the tool is the mechanism, the skill the exact procedure (syntax, mode choice, warnings), the
persona the awareness that makes the agent look for either. The **gate** welds them together,
converting the skill from advisory documentation into a prerequisite. The asymmetry between kinds
changes which layer carries the weight: on Letta the tools are native, so a loaded skill plus the
persona is enough for a well-formed call and an unloaded one hits a clean, model-readable block; on
Hermes the skill is the interface, which is why the gate matters more there and why its block is
only reachable once the CLI runs.

## 8. What team scoping would require

Nothing in this layer knows what a team is, and the reason is localized: discovery is a single
service-list call in one namespace, and a roster row is a bare name plus two addresses. Scoping it
would mean a scope predicate at discovery time that the deployer owns — a label, annotation, or
namespace boundary written at deploy, not inferred from the name — carried through the roster so
every tool inherits it rather than each re-deciding. It would also force two questions the design
has never had to answer: what a name means when two teams may independently pick the same one, and
whether an out-of-scope name should be hidden from the roster or shown and refused on contact. Until
such a predicate exists, a name is unique only because the cluster is one namespace.
