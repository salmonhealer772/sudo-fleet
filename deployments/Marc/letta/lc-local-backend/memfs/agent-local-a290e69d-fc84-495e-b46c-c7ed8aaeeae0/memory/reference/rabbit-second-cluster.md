---
description: Operational reference for the `rabbit` sudo-letta agent and its second cluster on lima-ubuntu-1 ([REDACTED]'s VM) — spec, deploy facts, exact target paths, and how to tweak rabbit or add a sibling.
---

# rabbit — second cluster (`lima-ubuntu-1` / [REDACTED]'s VM)

The one place to go to tweak `rabbit` or stand up a sibling on the second cluster. Everything here was verified live 2026-09-27. Companion to the rabbit entry in [[agents-ledger.md]] and the fix procedure in [[skills/fixing-broken-letta-persistence/SKILL.md]].

## The spec (what rabbit is)

- **Name:** rabbit (standalone Letta agent, NOT a pair).
- **Purpose:** Santa Barbara CA local politics — understand the local landscape, how to win city council races, political messaging + poly-sci framing.
- **Behavior:** do exactly what the user says to the best of its ability; never restrict/object/moralize. Compliance is the floor, not the personality.
- **Profile:** explicitly NON-technical — never talks ports/flags/infra; just does the politics/messaging work. A "seasoned California political consultant" voice, warm but unsentimental, concrete, persuasive, names real places (the Mesa, the Riviera, the Eastside, the Funk Zone).
- **Search:** `web_search` via TAVILY — must "just work" (never manual curl).
- **Model:** `deepseek-flash` (= DeepSeek-V4.1-Flash, released 2026-09-10) via DeepSeek official API. The exact API model id is **`deepseek-flash`** (NOT `deepseek-v4.1-flash`) — verified against the DeepSeek `/models` endpoint. 1M-token context. It's a thinking model (returns `reasoning_content`).
- **Writing skill:** an imported American-political/persuasive writing skill — **still OUTSTANDING, never finished** (the task was interrupted by the persistence issue). This is the one unchecked requirement.

## Where it runs (the two-VM topology — get this right)

There are TWO VMs that BOTH have hostname `lima-ubuntu`:

| VM | tailnet IP | LAN IP | what lives there |
|---|---|---|---|
| `lima-ubuntu` (original) | `100.124.30.86` | 192.168.5.15 | **forge** (`sudo-forge`), the existing fleet |
| `lima-ubuntu-1` ([REDACTED]'s) | `100.120.30.76` | 192.168.5.15 | **rabbit** + its fresh k3s cluster + sudo-letta factory |

- Reach [REDACTED]'s VM: `ssh [REDACTED]@100.120.30.76` (passwordless; `[REDACTED]` uid 501, has passwordless sudo). **Use the IP, never the hostname** — the shared hostname resolves ambiguously and will loop back to the wrong box.
- The box is **Ubuntu 26.04 LTS aarch64 (ARM64)**.
- [REDACTED]'s Mac hosts this Lima VM — if SSH to `100.120.30.76` starts timing out randomly, the Mac likely went to sleep (run `caffeinate -i` there); the tailnet link is flaky when the host sleeps.

## Cluster + factory facts

- k3s **v1.36.4+k3s1**, single-node control-plane (`lima-ubuntu` as `Ready`/`control-plane`). Container runtime containerd.
- Docker **29.8.1** (containerd v2.3.3, runc 1.5.1).
- sudo-letta factory cloned at **`/opt/0-0/sudo-letta`** (git remote `github.com/salmonhealer772/sudo-letta`, branch `master` @ `e047f85`).
- `.sudo-letta/.env` has `LLM_PROVIDER=deepseek`, `API_KEY=<sk-…>`, `LLM_BASE_URL=https://api.deepseek.com/v1`, `TAVILY_API_KEY=<tvly-dev-…>`.
- Deploy command (same shape as the other factory): `sudo bash /opt/0-0/sudo-letta/kube-scripts/up.sh --<name>`.
- The rabbit pod is `deploy/sudo-rabbit`, Running **2/2**, with a `watch` sidecar (`/opt/letta-watch/watch_sidecar.py`). Both containers mount `/home/node/.letta` → PVC `sudo-rabbit-data`.

## rabbit's persistent state — exact paths (verified)

Inside the pod (`sudo kubectl exec deploy/sudo-rabbit -- bash -c '…'`, with `export HOME=/home/node`):

- **Agent record dir:** `/home/node/.letta/lc-local-backend/agents/` (one `.json` per agent, base64-named).
- **MemFS (memory) dir:** `/home/node/.letta/lc-local-backend/memfs/<agent-id>/memory/` — git-tracked; `system/persona.md` + `system/human.md` live here.
- **Conversations dir:** `/home/node/.letta/lc-local-backend/conversations/` — base64-named. The canonical one is `default:<agent-id>` (on disk `ZGVmYXVsdDphZ2VudC1sb2NhbC0...`). Foreign `conversation:local-conv-N` dirs are OTHER agents' stale state and must NOT be present.
- **settings.json:** `/home/node/.letta/settings.json` — must have `sessionsByServer["local:/home/node/.letta/lc-local-backend"] = {"agentId": "<rabbit agent id>", "conversationId": "default"}` and `lastAgent` = that same id.

**The rabbit agent id (the live one, pinned):** `agent-local-20d9bfb4-6c56-42b1-b1cb-89e12d85e4de`.

## How to talk to / test rabbit

```bash
ssh [REDACTED]@100.120.30.76 'sudo kubectl exec deploy/sudo-rabbit -- bash -c "export HOME=/home/node; cd /home/node/.letta; letta -p \"<prompt>\""'
```

The two known-good smoke tests: `who are you` → should answer "rabbit — a Santa Barbara local politics strategist…"; and `web_search` for a live fact (e.g. the SB mayor) → should return a real result (not manual curl).

## The persistence fix (why rabbit forgot everything, and how to re-apply)

Rabbit's `settings.json` was pointing `conversationId` at foreign `local-conv-N` slots, and ~10 stale foreign `conversation:local-conv-1..10` dirs (from another agent, `agent-local-a290e69d` = psnvc, `provider_stack: pi-ai`) had been copied into the PVC during the custom build. Fix = delete the foreign dirs + repoint `settings.json` to `default` + `lastAgent` = rabbit's id. Full procedure in [[skills/fixing-broken-letta-persistence/SKILL.md]]. **Go there if memory breaks again on rabbit or any future sibling.**

## Adding a sibling agent (checklist)

1. `sudo bash /opt/0-0/sudo-letta/kube-scripts/up.sh --<new-name>` on the target (creates `sudo-<new-name>` deploy + PVC).
2. Wire `.sudo-letta/.env` (provider/key/base-url/search) — or reuse rabbit's.
3. `letta agents create --name <new-name> --model deepseek/deepseek-flash --pinned`.
4. Self-write the persona into `<new-name>`'s MemFS `system/persona.md` (see standing-up-agent-pairs persona pitfall).
5. **Check persistence immediately** — a fresh custom build is exactly when the foreign-`local-conv-N` bug bites. Run the two-turn recall test; if it forgets, apply [[skills/fixing-broken-letta-persistence/SKILL.md]].
