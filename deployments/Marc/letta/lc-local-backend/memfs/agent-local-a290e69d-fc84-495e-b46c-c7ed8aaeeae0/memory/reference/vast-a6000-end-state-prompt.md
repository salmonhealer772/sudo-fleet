---
description: The single "MAKE THIS HAPPEN" prompt for finishing the Vast.ai A6000 listing. This is the operator's trigger phrase — when they say it, psnvc reads THIS file and executes end-to-end. Do not re-derive credentials or procedure; they are all captured here. NOTE 2026-09-28: host key is EXPIRED/invalid, account NOT yet host-converted, and Vast's docs say "CGNAT/shared ISP IPs are not supported" AND "dedicated machines only" (fabean's shared multi-tenant k3s box fails this too) — a structural dead-end on fabean; the unblock is operator-side (fresh install command + accept hosting agreement), not a forge job.
---

# "MAKE THIS HAPPEN" — Vast A6000 end-state prompt

The operator's one trigger phrase: **"psnvc MAKE THIS HAPPEN"** (or any variant asking to finish the Vast A6000 listing). When I hear it, I execute the below end-to-end. This file is the canonical job record; read it, don't re-derive.

## The end state

fabean's RTX A6000 is **registered, listed, and self-test-passed** on Vast.ai for account `[REDACTED]` (user id 717975), so renters can reach it through the NeedPorts tunnel.

## Verified credentials (all on fabean, in `/home/who/vast-hosting/.env`)

- **Account/API key** = `[REDACTED]` — WORKS for `vastai` CLI (`show user` → [REDACTED] / 717975). Set via `VAST_API_KEY=<this>` env, never `vastai set api-key` with the host key.
- **Host key** = `[REDACTED]` — the DAEMON uses this to register the machine. ❌ **PROVEN INVALID/EXPIRED (2026-09-28)** — returns `"Invalid user key"` from Vast's API. It came from an install command valid for ~1 hour that Vast stops recognizing. The ONLY fix is the operator fetching a FRESH install command from the Host Setup page (log in → Setup → Host Setup → Install Manager → refresh → copy command → paste to psnvc). No forge work can fix an expired key. This is now the primary blocker (alongside the CGNAT/IP issue below).
- **NeedPorts token** = `Rdk0jq0tDtSACQBhioeDA-sQaHD9JijUKy9YvDo95Ro` — install line: `curl -fsSL https://api.needports.com/install | sudo bash -s -- Rdk0jq0tDtSACQBhioeDA-sQaHD9JijUKy9YvDo95Ro --accept-tos --mode vast` (this install previously ERRORED — must be diagnosed and fixed).

## Access (how psnvc reaches fabean and forge — VERIFIED 2026-09-28)

- **fabean SSH:** `ssh [REDACTED]@fabean` (Tailscale ACL now allows [REDACTED]). sudo = `echo [REDACTED] | sudo -S <cmd>`. There is NO `who` sudo password, and `sudo su - [REDACTED]` is a HALLUCINATION ([REDACTED] is a user, not a su path). `[REDACTED]` uid 1001, in sudo group.
- **forge (my engineer):** the docker-socket host bridge → `kubectl exec -i deploy/sudo-forge -- hermes -z '<single-line prompt>'`, wrapped with `env HERMES_STREAM_READ_TIMEOUT=inf HERMES_STREAM_STALE_TIMEOUT=inf HERMES_API_CALL_STALE_TIMEOUT=inf KUBECONFIG=/etc/rancher/k3s/k3s.yaml`. See [[skills/talk-to-my-engineer/SKILL.md]].

## The ONE remaining blocker (as of 2026-09-28)

The machine was NEVER registered. Evidence:
- `vastai show machines` returns EMPTY (zero machines on account 717975).
- Daemon `send_mach_info.log` ends `Failed to send Data, status code: 404`; `kaalia.log` shows `on_read error: End of file 0` after every Identify.
- Machine uuid on disk: `[REDACTED]` — never accepted by controller.

Root cause (PROVEN, 2026-09-28, not guessed): the machine was NEVER registered. The daemon's identity split is now fully understood:
- `api_key` file (`[REDACTED]...`) = the **host key** — correct on disk, BUT the key itself is now expired/invalid (returns "Invalid user key").
- `machine_id` file (`[REDACTED]...`) = a **locally-generated UUID that was never registered** — the daemon sends this value as `mach_api_key` to `/api/v0/disks/update/`, Vast doesn't recognize it, and returns 404.
- Registration is done by Vast's **compiled installer handshake** (`kaalia` binary + `launch_kaalia.sh`) — the binary reads `machine_id` as its identity, and only Vast's controller writes back the REAL `mach_api_key` during a completed install. The `vastai` CLI (`list machine`, `self-test`) cannot substitute for this handshake.

So the full unblock is **two operator-side prerequisites** (neither forge nor psnvc can do these):
1. **Fetch a FRESH install command** (the standalone host key alone is expired; the Host Setup → Install Manager page regenerates a new command with a fresh auth token, valid ~1 hour).
2. **Accept Vast's hosting agreement** — the `[REDACTED]` account shows the "Sign Hosting Agreement and Convert Your Account" button STILL present (2026-09-28), meaning it is **NOT yet a host account** despite an earlier "converted" claim. The install command won't even render until logged in + converted.

**⚠️ HARD STRUCTURAL BLOCKER (2026-09-28, from Vast's own Host Setup page):** the "Minimum Requirements for Verification" table and "IP Requirements" section state flatly: **"Public IPv4 address with 5 forwarded ports per GPU" and "CGNAT and shared ISP IPs are not supported."** fabean is on residential internet (likely CGNAT / 5G / cable — no clean public IPv4). This is NOT "not supported until you tunnel around it" — NeedPorts is a third-party workaround that Vast's own docs do **not** endorse for this, and the self-test's "public IPv4 + open ports" check is a hard gate. **The entire Vast-rental plan on fabean may be structurally impossible**, not just blocked on credentials. Before spending more effort, surface this to the operator: path 1 = push through with a fresh install command to see exactly where self-test fails (costs one command); path 2 = accept the CGNAT verdict and pivot (sell finished work / served inference, the higher-margin play regardless).

## The procedure (execute in order, verify each)

0. **PREREQUISITE (operator-only, both required — nothing proceeds without these):** (a) confirm the `[REDACTED]` account has the "Sign Hosting Agreement" button GONE (i.e. converted to a host account); (b) get a FRESH install command from Host Setup → Install Manager (refresh the page, copy the `wget ... | python3 ...` command with its fresh auth token valid ~1 hour) and paste it to psnvc.
1. **forge: run the FRESH install command** on fabean — this is what actually completes Vast's compiled registration handshake and writes a real `mach_api_key` into `machine_id` (replacing the local stub UUID).
2. **GATE: `vastai show machines` shows the machine with an integer machine ID.** Do not proceed past here until this is true.
3. **forge: install NeedPorts** — diagnose why it errored, fix, confirm tunnel up (system service `active`), capture assigned port range + endpoint.
4. **forge: wire ports** — write NeedPorts range to `/var/lib/vastai_kaalia/host_port_range` and endpoint IP to `/var/lib/vastai_kaalia/host_ipaddr`.
5. **forge: `vastai list machine <id> ...`** — on-demand ~$0.35/hr, min-bid floor ~$0.16/hr, `min_gpu=1`, short end date (~7 days).
6. **GATE: `vastai self-test machine <id>`** — must return "Test completed successfully." ⚠️ **This is where the CGNAT blocker bites** and where the "dedicated machine only" verification rule bites (fabean's shared k3s card fails it regardless of the tunnel). Vast's docs say "CGNAT and shared ISP IPs are not supported"; the self-test needs a public IPv4 + ≥5 forwarded ports per GPU; and verification itself requires a dedicated machine + ≥500 Mbps symmetric. If it fails on ports/routing or on the dedicated-use rule, that is the honest structural dead-end — surface it cleanly, do NOT improvise a workaround Vast doesn't support.
7. **psnvc verifies + records** final state in the ledger; report ONCE at the end.

## Honest bottom line (say this when reporting)

Rentable ≠ profitable, and **it may not even be rentable at all from fabean.** As of 2026-09-28 two things stand in the way: (1) the host key is expired and the account isn't actually host-converted yet (operator-only fixes), and (2) — the bigger one — Vast's own docs say **"CGNAT and shared ISP IPs are not supported,"** which fabean's residential connection likely violates, so the self-test's public-IPv4 + open-ports gate may hard-fail regardless of NeedPorts. Be honest about that *before* spending more effort. Separately, even if it clears, single residential A6000 at ~34.5¢/kWh nets **break-even to ~$100/mo**, and **money won't reach the operator until they configure a Vast Payout Account** (account shows `Has Payout: False`, `Has Billing: False`).

## Related

- Full sourced plan: [[reference/vast-a6000-build-plan.md]]
- Economics / sell-work-not-GPU-hours: [[reference/fabean-compute-monetization.md]]
- fabean + forge access: [[reference/environment.md]], [[skills/talk-to-my-engineer/SKILL.md]]

---

## RESOLVED STATE (2026-09-28 ~01:15 UTC) — machine is REGISTERED, LISTED, blocked on verification

The "MAKE THIS HAPPEN" chain was run end-to-end and cleared the registration wall. Proven root cause of the original 404: the host key `[REDACTED]...` was a STALE/expired install-auth token (returns `Invalid user key` from `console.vast.ai/api/v0/machines/`), NOT a fixable key. The fix = a FRESH one-hour install command from https://cloud.vast.ai/host/setup (operator pasted: `wget https://console.vast.ai/install -O install; sudo python3 install [REDACTED] --interactive ...`).

**Actual install command that worked (non-interactive, on fabean as [REDACTED]):**
```
cd /tmp && python3 install [REDACTED] --no-driver --no-docker --no-libvirt --reset-machine --agree-to-nvidia-license --no-partitioning
```
Run via `echo [REDACTED] | sudo -S bash -c "<cmd>"` (nested-quote-safe: base64 the inner command when it has $VARs). `--reset-machine` forces a fresh machine_id; `--no-driver/--no-docker/--no-libvirt` skip destructive reinstalls (fabean already has driver 595.84 + Docker=k3s). Result: install log ends "Daemon Running / Done! / found 1 nv gpus".

**RESULT — machine is LIVE:**
- Machine ID: **152421** (was stale `[REDACTED]...`, now `[REDACTED]...`)
- GPU: RTX_A6000 ×1 detected; 16 cores (Ryzen 9700X), 62GB RAM, 555GB disk, driver 595.84, Ubuntu 24.04
- NeedPorts: range `33013-33062`, public IP `15.204.86.122`, `direct_port_count: 50`
- Listed: `listed: true`, `listed_gpu_cost: 0.35`, `min_bid_price: 0.16`, `listed_min_gpu_count: 1`
- `verification: unverified` (fresh host)

**REMAINING GATE (the honest hard-stop):** `vastai self-test machine 152421` cannot pass until Vast surfaces a RENTABLE offer, which it will NOT do for an `unverified` brand-new residential host. `vastai search offers 'machine_id=152421 rentable=any rented=any'` returns EMPTY despite `listed: true`. This is Vast's automated verification, runs at least once daily, no fixed timeline — NOT fixable from fabean. When the offer goes rentable (check within ~24h), run `vastai self-test machine 152421` and expect "Test completed successfully." The make-or-break-if-it-passes: NeedPorts tunnel clearing Vast's "direct open ports" requirement. If it hard-fails on ports/reachability, that is the real CGNAT dead-end — report it, don't improvise.

**Operator-side (not done, not ours):** configure Vast Payout Account (Has Payout: False, Has Billing: False).
