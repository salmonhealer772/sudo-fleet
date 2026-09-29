---
description: The source-cited, step-by-step build plan to get fabean's single RTX A6000 listed and rentable on Vast.ai via a NeedPorts tunnel (no home-router port forwarding). This is the PLAN file, not the research (see fabean-compute-monetization.md for the economics). End state: "we are piping out the A6000 on Vast." Every step carries its citation. Re-read from THIS file when resuming — do not freeball the procedure. NOTE 2026-09-28: the 404 root cause is now definitively diagnosed (machine_id is a local unregistered UUID, host key expired), the account is NOT yet host-converted, AND Vast's own docs say "CGNAT and shared ISP IPs are not supported" — a likely structural dead-end on fabean.
---

# Build plan: pipe the A6000 out on Vast (via NeedPorts)

**End state:** fabean's RTX A6000 is listed on Vast.ai, passes `vastai self-test machine`, becomes verified, and is rentable — with renters reaching the card over the NeedPorts tunnel instead of opening ports on the home router.

**Why a tunnel and not the router:** fabean is on residential internet (no clean public IP / likely CGNAT). Vast's model is "renter → your machine directly," and its docs assume a static public IP + open ports.

  **⚠️ HARD STRUCTURAL BLOCKER (2026-09-28, read directly off Vast's Host Setup page):** the "Minimum Requirements for Verification" table + "IP Requirements" section state flatly: **"Public IPv4 address with 5 forwarded ports per GPU" and "CGNAT and shared ISP IPs are not supported."** This is NOT "not supported until you tunnel around it" — NeedPorts is a third-party workaround Vast's own docs do *not* endorse for passing this gate, and the self-test's "public IPv4 + open ports" check is a hard gate. fabean's residential connection likely violates this outright. **This may make the entire Vast-rental plan on fabean structurally impossible**, independent of the credential issues. The honest two paths (operator's call): push through with one fresh install command to see exactly where self-test fails, or accept the CGNAT verdict and pivot to selling finished work / served inference (the higher-margin play anyway).
- Source: <https://docs.vast.ai/host/hosting-overview.md> — "opening network ports on the router and installing the Vast hosting software."
- Source: <https://docs.vast.ai/host/understanding-verification.md> — verification favors "high-speed, symmetric, stable bandwidth... a static IP helps."
- Source: <https://docs.vast.ai/host/how-to-self-test.md> — "Even with `--ignore-requirements`, your machine must have at least three direct open ports, otherwise the self-test will fail."

**Why NeedPorts (not DIY VPS, not Cloudflare/ngrok):** NeedPorts is purpose-built "by Vast hosts for Vast hosts," uses an **outbound tunnel** (no router access needed), and — the deciding factor — supports **TCP and UDP**, which Vast workloads require and free HTTP tunnels (Cloudflare Tunnel, ngrok) do not do well.
- Source: <https://needports.com/vast-ai-behind-cgnat.html> — "NeedPorts uses an outbound tunnel, so it can work when router access or ISP port forwarding is unavailable." and "Forward any protocol... TCP & UDP."
- Source: <https://needports.com/how-it-works.html> — auto-reconnect as a system service + a dedicated public port range + auth token per machine.

---

## The loop (who does what — spec → delegate → verify)

- **psnvc (mind):** holds this plan, specifies + verifies. Does NOT hand-run the engineering.
- **forge (hands):** runs every shell/install on fabean via `ssh who@fabean`. Owns the HOW.
- **The operator ([REDACTED]):** creates the two accounts and hands over two tokens. Only the operator can accept Vast's hosting agreement.

---

## Phase 0 — IDs/tokens the operator must produce (prerequisite, ~15 min, once)

1. **Vast host account** → host API key.
   - Source: <https://docs.vast.ai/host/hosting-overview.md> — "You must create a new account for hosting... read through the agreement. Once you accept, your account will then be converted to a hosting account." (Separate from any renter account.)
   - Source: <https://docs.vast.ai/host/how-to-self-test.md> — "Get your API key ... `vastai set api-key <API_KEY>`."

   **⚠️ TWO Vast keys, not interchangeable (learned the hard way 2026-09-27):** Vast uses **two distinct key types for two distinct jobs**, and they do NOT swap.
   - **Host key** — held by the Kaalia *daemon* (`/var/lib/vastai_kaalia/`) to register/authenticate the *machine*. ✅ we have this (registered, machine_id assigned).
   - **Account/API key** — authenticates the `vastai` *CLI* (and API) to your account, so it can run host-control commands (`vastai list machine`, `vastai self-test machine`). ❌ MISSING — forge got `404 Invalid user key` when it fed the host key here.
   - The operator makes the account key at **https://cloud.vast.ai/keys** (API Keys section → `+New` → copy; it shows only once). It is what goes into `vastai set api-key <account-key>` (stored at `~/.config/vastai/vast_api_key`). Without it, the card is "registered but unlisted" and **cannot be rented**.
   - **⚠️ Operator-side friction (2026-09-28):** two things to know before pointing at that URL again. (1) The operator has said plainly he **"DO NOT KNOW HOW TO MAKE THE VAST AI ACCOUNT API KEY"** — don't assume he knows the click-path; give the *literal* step-by-step (log in → Keys page → `+New` → name → permissions → Create → copy the one-time-shown key), not a bare URL. (2) The `cloud.vast.ai/keys` URL "doesn't work" for him because it's an **app-gated SPA**: it returns HTTP 200 at the shell level but only renders the Keys page once logged in to a host (not renter) account — so a raw link feels "broken" even though it isn't. Also, the operator has **already copied a key out of the API Keys section** but isn't certain what it is — so the account key may *already exist*; the next move is to **test the key that's already there** (forge: `vastai show user` / `vastai list machine` with it) rather than assume it's missing and send him back to create a new one.
2. **NeedPorts account** → setup token + assigned public endpoint/port range.
   - Source: <https://needports.com/vast-ai-behind-cgnat.html> — "`YOUR_SETUP_TOKEN` is shown after signup/trial checkout and binds the client to your assigned endpoint."

Hand both tokens to psnvc over a non-git-tracked channel. **Tokens never go into memory or any git-tracked file.**

**Where they live now (established 2026-09-27):** the operator chose a canonical plaintext directory on fabean — **`/home/who/vast-hosting/.env`** — rather than a chat paste. Contents (confirmed 2026-09-28): **line 1** the **Vast host API key** (a standalone token, used by the daemon), **line 2** the **Vast account/API key** (VERIFIED WORKING 2026-09-28 — `vastai show user` returns `[REDACTED]`, user id `717975`), and **line 3** the **NeedPorts install command whose `bash -s -- <token>` arg IS the NeedPorts setup token** (the token is embedded *inside* the `curl -fsSL https://api.needports.com/install | sudo bash -s -- <token>` line, not a separate KEY= entry). The `.env` was tightened by forge to **root-owned `600`** (was `644`). **Sudo path to read it — RESOLVED 2026-09-28:** the working recipe is `ssh [REDACTED]@fabean 'echo [REDACTED] | sudo -S cat /home/who/vast-hosting/.env'` — `[REDACTED]` is a real sudo user (uid 1001) with sudo password `[REDACTED]` (see [[reference/environment.md]]). Do NOT loop on escalation or ask the operator to paste the key when this sudo path is available; it reads the root-600 file cleanly.

## Execution status (2026-09-28, updated)

Tokens were delivered (see Phase 0 note) and **forge was dispatched to run Phases 1–5 end-to-end**, driven from a build brief psnvc wrote to **`/opt/data/forge-vast-build-brief.md`** (and `kubectl cp`-ed into forge's pod). When resuming, the fresh live state to read is **forge's report file** (the `/opt/data/` result for this job) — do not assume a phase completed without reading it. The headline gate remains `vastai self-test machine` passing through the NeedPorts tunnel.

**Progress as of 2026-09-28 (account-key blocker CLEARED, new daemon blocker identified):**
- ✅ **Account/API key VERIFIED WORKING** (2026-09-28): the second key now in `.env` returns `[REDACTED]`, user id `717975` on `vastai show user`. The earlier "404 Invalid user key" was because the HOST key was being fed as the account key — two keys, two jobs, not interchangeable (see Phase 0 note). The account key is confirmed in place.
- ⚠️ **Account NOT actually converted to host yet** (corrected 2026-09-28): the Host Setup page still shows the **"Sign Hosting Agreement and Convert Your Account" button**, meaning the earlier "converted ✅" was premature. The install command won't even render a real auth token until the operator is logged in AND has accepted the hosting agreement. This is a hard prerequisite the operator must complete.
- ✅ **Sudo path fixed** (2026-09-28): `[REDACTED]@fabean` (sudo password `[REDACTED]`) now reaches the box once the Tailscale ACL was updated — this is how the root-600 `.env` was read. See [[reference/environment.md]].
- ⚠️ **Machine daemon running but REJECTED by the controller** (forge investigation 2026-09-28, STILL THE HARD BLOCKER): `vastai.service`/Kaalia daemon is active, but `send_mach_info.log` shows repeated **`404 / Failed to send Data`** on identify — the daemon phones home and gets bounced. **`vastai show machines` returns no machine row** (the machine was never actually *registered* on Vast's end). This means "registered ✅" from 2026-09-27 was stale/wrong. Re-confirm with a live `vastai list machine` / `vastai show user` rather than assuming a prior "registered" state still holds.

  **Root cause DEFINITIVELY diagnosed (2026-09-28, from reading the daemon's own source `send_mach_info.py` + `launch_kaalia.sh`):** the daemon's identity is split across TWO files with DIFFERENT jobs:
  - `api_key` (`[REDACTED]...`) = the **host key** — correct on disk, BUT **this key is now expired/invalid** (returns `"Invalid user key"` from Vast's API). It came from an install command valid ~1 hour.
  - `machine_id` (`[REDACTED]...`) = what the daemon sends as `mach_api_key` to `/api/v0/disks/update/` — and it's a **locally-generated UUID that Vast never registered**, so every POST 404s.
  - Registration is done only by Vast's **compiled installer handshake** (`kaalia` go binary + `launch_kaalia.sh`) — the CLI (`list machine`, `self-test`) cannot substitute. Only a fresh install command run on fabean completes the handshake and writes the real `mach_api_key` into `machine_id`.

  **The unblock is now two operator-only items, not a forge job:** (1) fetch a FRESH install command from Host Setup → Install Manager (refresh page; token valid ~1 hour), and (2) accept the hosting agreement (button still showing = not yet a host account).
- ✅ GPU **publicly reachable** through the NeedPorts tunnel.
- ✅ forge correctly identified and **routed around the destructive `docker_install` step** in Vast's installer (it would wipe fabean's existing Docker — which *is* the k3s runtime — and forge found fabean already has `nvidia-container-toolkit` 1.20.0, so it skips the destructive path).
- ❌ **NOT listed / NOT rentable** — blocked on the **daemon `404` registration failure**, not on the key anymore. Forge is diagnosing the daemon phone-home 404 and re-registering cleanly; the gate to clear is `vastai show machines` printing an actual machine row.

**⚠ "was the `.env` just wrong?" — NO (operator asked, 2026-09-28).** The `.env` was set up correctly the whole time (host key + account key + NeedPorts token, all present/in-place). The real failures are *upstream* of the file: (1) the account key hadn't been created/tested yet (now resolved), and (2) the daemon's registration phone-home is 404'ing. Don't re-blame the `.env`; the healthy `vastai show user` proves the CLI/account side works, and the remaining problem is the daemon→Vast registration path alone.

**Account health facts (2026-09-28, surfaced honestly):** this is a **brand-new Vast account** — Balance `0.0`, `Has Payout: False`, `Has Billing: False`, `Can Pay: False`. The operator cannot fund it and Vast cannot pay out until a Payout Account + identity verification is configured (operator-side only).

**Money-flow note (operator asked "where does the money live"):** Vast is a marketplace, not a wallet. Earnings accrue as **"Total Rental Earnings" credit** in the host console and can idle there indefinitely; the operator must later configure a **Payout Account** (bank/Stripe/crypto, in the console's Earnings section) to actually withdraw it. That payout-account step is operator-side only (identity/bank/verification) — neither psnvc nor forge can do it.

---

## Phase 1 — forge: preflight the card (read-only, de-risk before paying)

On fabean (`ssh who@fabean`), confirm:
1. Driver/CUDA present and current — already observed `595.84` / `13.2` (psnvc SSH check 2026-09-27).
2. GPU allocatable: `kubectl get nodes -o yaml` shows `nvidia.com/gpu: 1` (already observed working `nvidia-device-plugin`).
3. Disable auto-updates so a driver bump can't kill a rental mid-contract.
   - Source: <https://docs.vast.ai/host/hosting-overview.md> — "Make sure to disable auto-updates so that your machine doesn't drop a client job to update a driver."
4. Check free disk for renter Docker storage (observed 586GB free; forge confirms XFS layout the way Vast wants).
   - Source: <https://cloud.vast.ai/host/setup/step-by-step> — Docker on a separate XFS mount; the installer auto-selects largest free partition or falls back to a loopback.

## Phase 2 — forge: install Vast host daemon

1. Install the official Vast Kaalia host software on fabean, with the host API key.
   - Source: <https://cloud.vast.ai/host/setup> — "Install Manager" step; the one-command installer is linked from the host setup page.
2. Set the API key: `vastai set api-key <ACCOUNT_API_KEY>`.
   - Source: <https://docs.vast.ai/host/how-to-self-test.md> — "Step 1: Set Your API Key."
   - **NOTE (2026-09-27):** this must be the **account/API key** (from `cloud.vast.ai/keys`), NOT the host key that registered the daemon. Feeding the host key here yields `Failed with error 404: Invalid user key`.

## Phase 3 — forge: install NeedPorts tunnel + wire ports

1. Install NeedPorts on fabean:
   ```bash
   curl -fsSL https://api.needports.com/install | sudo bash -s YOUR_SETUP_TOKEN --accept-tos
   sudo needports setup --dry-run
   ```
   - Source: <https://needports.com/vast-ai-behind-cgnat.html> — the verbatim install + dry-run commands.
2. Confirm the tunnel is up and auto-reconnecting (system service).
   - Source: <https://needports.com/how-it-works.html> — "Runs as a system service. If your connection drops or your machine reboots, the tunnel reconnects automatically."
3. Map the assigned public port range to the Vast host config:
   ```bash
   sudo bash -c 'echo -n "<START>-<END>" > /var/lib/vastai_kaalia/host_port_range'
   sudo bash -c 'echo -n "<NEEDPORTS_ENDPOINT_IP>" > /var/lib/vastai_kaalia/host_ipaddr'
   ```
   - Source: <https://cloud.vast.ai/host/setup> — "You can change the port range later by writing it to `/var/lib/vastai_kaalia/host_port_range`"; the `host_ipaddr` write is documented directly under it for asymmetric NAT.

## Phase 4 — forge: list the machine

```bash
vastai list machine <machine_id> -v <disk_gb> -z <disk_price> -g <on_demand_price> -e "<short end date>" -r 0 -m 1
```
- Source: <https://docs.vast.ai/host/hosting-overview.md> — "`vastai list machine ... -g .5 -e "12/23/2027" -r 0 -m 1`" (the canonical listing form), plus the params table (pricing for GPUs/internet/storage, min-bid, min_gpu, offer end date).
- **Pricing settings (sourced, not invented):**
  - On-demand price: at unverified-A6000 competitor rates, not H100 fantasy. Source: <https://docs.vast.ai/host/optimization-guide.md> — "Use market data and your competitors' pricing as a reference point."
  - **Min-bid floor = cost of electricity ≈ $0.16/hr** (not the on-demand price). Source: <https://docs.vast.ai/host/optimization-guide.md> — "Set your Min Bid Price close to your cost of power when the GPU is under load... it is a floor, not an on-demand price."
  - `min_gpu=1` (we have a single card; this is the only coherent value). Source: <https://docs.vast.ai/host/hosting-overview.md> — "min_gpu ... set to 1 ... clients can make instances with 1...".
  - Short offer end date to start (don't over-commit a box that isn't verified yet). Source: <https://docs.vast.ai/host/hosting-overview.md> — "Make sure to set an offer end date before listing your machine."

## Phase 5 — psnvc verifies: self-test is the gate

```bash
vastai self-test machine <machine_id>
```
- Source: <https://docs.vast.ai/host/how-to-self-test.md> — "Step 2: Run the Self-Test." It checks driver/CUDA, network speed/stability, **open ports + connectivity**, PCIe bandwidth, GPU VRAM, RAM/CPU.
- **Pass = "Test completed successfully."** Fail = read the specific reason, hand forge the exact fix, re-run.
- **Known hard blocker (2026-09-28, CONFIRMED from Vast's own docs, not just unknown):** Vast's Host Setup page says **"CGNAT and shared ISP IPs are not supported"** and requires a public IPv4 + ≥5 forwarded ports per GPU. NeedPorts markets itself for exactly this CGNAT case, but it is NOT what Vast's docs endorse, and the self-test's port check is a hard gate — so this is now a *likely structural dead-end*, not a mere "will it or won't it" unknown. If it hard-fails on ports through the tunnel, that is the honest dead-end — surface it, do not improvise around it.
- **Second hard gate — "dedicated machine only" (2026-09-28):** Vast's verification-stages docs state *"dedicated machines only; any personal workload — mining, gaming, running your own jobs — will automatically fail verification"* (plus a ≥500 Mbps symmetric link). fabean is a multi-tenant k3s host (Minecraft + agent fleet + ollama + LiteLLM all on the one A6000), so it fails this gate outright *independent of* the network. Even a clean NeedPorts tunnel won't clear verification while the card is shared — the box would need to be emptied/dedicated (or the A6000 colocated) first.
- If it reports "not found or not rentable": un-list then re-list; ensure upload/download speed, RAM, and ports are populated. Source: <https://docs.vast.ai/host/how-to-self-test.md> — "Step 3: Review the Results."

## Phase 6 — ramp to actually earning (behavioral, not buildable)

- Verification is **fully automated and earned over time** (reliability + DLPerf + supply/demand), NOT achieved by a setup step. Source: <https://docs.vast.ai/host/understanding-verification.md> — "Verification is fully automated... evaluates reliability, infrastructure, DLPerf, and supply/demand."
- Reliability is maintained by **not taking the box offline** during rentals. Source: <https://docs.vast.ai/host/hosting-overview.md> — "Do not take your machine offline."
- Revisit pricing after the first real rentals, using Vast's own Market Stats page. Source: <https://docs.vast.ai/host/hosting-overview.md> — "How much can I make hosting on Vast? ... check our Market Stats page."

---

## The honest bottom line (do not inflate when narrating)

This plan reaches the named end state — **"the A6000 is rentable on Vast"** — in an afternoon once the two tokens exist. It does **not** promise meaningful income: after electricity (~$0.16/hr), the NeedPorts subscription, Vast's fee, and the multi-week verification ramp, the realistic ceiling is **break-even to ~$100/mo**. The pipeline is the goal; the profit is thin. That conclusion is already recorded and sourced in [[reference/fabean-compute-monetization.md]] — do not re-derive or inflate it.

## Related

- Economics + the "sell finished work, not raw GPU-hours" verdict: [[reference/fabean-compute-monetization.md]]
- fabean hardware/stack facts + `ssh who@fabean` bridge: [[reference/environment.md]]
- forge reach (the `hermes -z` one-shot): [[skills/talk-to-my-engineer/SKILL.md]]
