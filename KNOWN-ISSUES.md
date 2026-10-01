# Known issues

## Comm layer

### 1. The load-skill-first gate is per-conversation — compaction can leave a tool unlocked

The gate records "skill was loaded" keyed by conversation/session, and the tool
stays unlocked for the rest of that conversation. If a long conversation is
compacted, the skill's text can drop out of context while the gate's "loaded"
record persists — so the tool remains callable, but the agent no longer has the
skill's syntax/guidance in view. The gate guarantees "the skill was loaded at
least once this conversation", NOT "the skill text is still in context". On very
long conversations a compacted agent may call a comm tool from a half-remembered
invocation. (Hermes: `comm-gate/state.json` keyed by `HERMES_SESSION_ID`; Letta:
in-memory map keyed by conversation id.)

### 2. Hermes comm tools are CLI-only — the gate's BLOCKED path isn't reachable by prompt

The three Hermes comm tools are plain CLIs (`/opt/comm-tools/*.py`), not
registered native tools; the skill is the ONLY entry point that teaches the
agent to run them. So a prompt like "call list_siblings without loading any
skill" yields `Tool 'list_siblings' does not exist` — not the gate's BLOCKED —
because there is no native `list_siblings` tool to call, and without the skill
the agent doesn't know the CLI path. The gate's BLOCKED only fires when the CLI
is actually run with its skill unloaded (e.g. a scripted call). The Letta side
is symmetric — its comm tools ARE native mod tools, so the same prompt cleanly
hits the gate's BLOCKED. (Phase 7.)

### 3. Hermes pods run `hermes` without the docker group active — the comm bridge fails

`hermes` (uid 10000) is listed in gid 109 (`hostdocker`) in `/etc/group`, but the
running process's supplementary groups are only `[10000]` — gid 109 is not
active — so `/var/run/docker.sock` (root:109, mode 660) is denied and the
docker+nsenter host bridge all three comm tools depend on fails. The Letta pod's
`node` process DOES carry 109 (`dockerhost`) active, which is why the identical
bridge works there. Fix: enumerate the hermes user's supplementary groups at
process start (`initgroups` / add gid 109) so gid 109 is active, matching the
Letta pod. (Phase 7; reported to `sudo-agent-maintainer-h` via message_agent
inbox, id `msg-5d591bde955b`.)
