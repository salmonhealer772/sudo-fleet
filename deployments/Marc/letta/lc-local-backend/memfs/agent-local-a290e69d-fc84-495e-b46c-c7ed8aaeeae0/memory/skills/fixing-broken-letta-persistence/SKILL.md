---
name: fixing-broken-letta-persistence
description: Fix a Letta agent that "has no memory" — recall fails, every prompt is a clean slate. Use whenever an agent forgets what you just told it, says "we haven't talked about anything", a recall subagent fails, or memfs_search returns "No matches". This is the classic broken-persistent-state bug from the rabbit build (2026-09-27).
---

# Fixing Broken Letta Persistent State

The classic failure: a Letta agent **saves** state but **never reads it back**, so every turn starts empty — it says "we haven't talked about anything", a recall subagent fails, and `memfs_search` returns "No matches".

The operator's one-line framing is the whole diagnosis: **"the spot Letta saves its persistent state to is mismatched, so it is saving but never grabs from where it is saving."** That's a path mismatch, not a deep bug. Fix the paths, done. Don't reach for MCP servers, watch sidecars, or persona theory first — check the conversation pointer.

## The symptom signature

If you see ANY of these, go straight to the fix below:

- Agent forgets a fact you just told it (recall across two turns fails).
- "What have we been talking about?" → empty / "we haven't talked about anything yet".
- A "Recall past conversations" subagent spins up and FAILS.
- `memfs_search` → "No matches".
- `letta -p "who are you"` fell back to the default "Letta Code" identity.

## The root cause (two things to check)

The Letta local backend keeps state at `~/.letta/lc-local-backend/`, and persistence breaks when **`settings.json` points at the wrong conversation slot**, or **foreign stale conversation dirs got copied in** during a custom build.

1. **`settings.json` → `sessionsByServer["local:/home/node/.letta/lc-local-backend"].conversationId`** should be `"default"` (the agent's own canonical conversation), but ends up churning to `local-conv-N` — so every prompt mints a fresh empty conversation and state never accumulates.

2. **Stale foreign conversation dirs.** During a custom sudo-letta build, the PVC can get cloned from another agent and pick up that agent's conversation dirs. They are base64-named (`conversation:local-conv-N` → `Y29udmVyc2F0aW9uOmxvY2FsLWNvbnYtNQ==` on disk) and, critically, their `conversation.json` carries a **foreign `agent_id`** (e.g. another agent's `agent-local-*`, `provider_stack: pi-ai`, old dates). These keep re-minting slots, so setting `conversationId` alone won't hold — you must also delete them.

The agent's OWN canonical conversation lives at directory `default:<agent-id>` (on disk: base64 `ZGVmYXVsdDphZ2VudC1sb2NhbC0...`), with `conversation.json` → `"id": "default"` and the correct `agent_id`.

**Distinguish from the older 2026-09-06 bug** (`talk.sh` → `LocalBackendNotFoundError`): that one was fixed by just setting `conversationId` → `"default"`. This rabbit variant is deeper — the stale FOREIGN `local-conv-*` dirs also have to be removed, or the churn comes right back.

## The fix (simple, normal config — no "crazy thing")

Run these inside the agent's pod (via `sudo kubectl exec deploy/sudo-<name> -- sh -c ...`, `export HOME=/home/node`):

```bash
cd /home/node/.letta
# 1. delete the foreign conversation dirs (base64-named local-conv-N)
cd lc-local-backend/conversations
for d in Y29udmVyc2F0aW9uOmxvY2FsLWNvbnYt*; do rm -rf "$d"; done
# (keep the one dir that decodes to default:<agent-id>)
ls -1   # confirm only the default:* dir remains
```

Then repoint `settings.json` (Python, so JSON quoting is clean):

```python
import json
p = "/home/node/.letta/settings.json"
d = json.load(open(p))
aid = "<the single pinned rabbit agent id>"   # e.g. agent-local-20d9bfb4-...
d["lastAgent"] = aid
ssb = d.setdefault("sessionsByServer", {})
ssb["local:/home/node/.letta/lc-local-backend"] = {"agentId": aid, "conversationId": "default"}
json.dump(d, open(p, "w"), indent=2)
```

## Verify (the only metric that counts)

Two SEPARATE `letta -p` turns — write a fact, then recall it in a fresh invocation:

```bash
letta -p "remember this for later: my favorite coffee is a flat white. reply with just: noted."
letta -p "a moment ago I told you my favorite coffee. what is it?"
```

Persistence is fixed when the SECOND turn names the fact ("flat white"). A single `who are you` is NOT enough proof — the agent can answer correctly once and still forget on the next turn.

## Traps (from the rabbit build — don't re-hit these)

- **Hand-editing the backend's files under its feet is doer drift.** During rabbit, psnvc hand-deleted agent records and made it worse. Prefer driving the fix through the actual `settings.json` + deleting the clearly-foreign dirs (as above), and verify with two turns. Don't go deleting `.json` agent records unless you're certain.
- **The agent id can churn** (`3facbb4c` → `20d9bfb4` → …) while the conversation pointer is broken — that's a SYMPTOM of the foreign-slot bug, not a separate problem. Fix the conversation pointer first, the id settles.
- **Don't theorize from the MCP server / watch sidecar.** The sudo-letta factory runs an MCP server + a watch sidecar that both touch `/home/node/.letta`, which LOOKS like the culprit but wasn't the fix for rabbit. The fix was the plain conversation-pointer/path mismatch. Check the pointer before reverse-engineering the sidecars.
- **Setting `conversationId: "default"` once and declaring victory is not enough** if the foreign `local-conv-*` dirs are still present — they re-mint the churn on the next turn. Delete them too.
