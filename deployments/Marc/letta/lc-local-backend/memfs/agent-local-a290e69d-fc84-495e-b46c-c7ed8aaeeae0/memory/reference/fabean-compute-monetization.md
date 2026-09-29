---
description: Economic facts and the speculative "monetize fabean's compute" direction the person explored 2026-09-27. Sourced rates (A6000 rental, SCE electricity), per-hour $/hr ceilings by lane (rental/inference/image/video), the passive-vs-sell-it verdict (Vast.ai raw rental is the only positive-passive path, ~$100-330/mo), the strategic conclusion (sell finished work, not raw GPU-hours), and the Vast hosting blocker (static-IP/open-ports requirement, 16384-32768 TCP+UDP range, NeedPorts + DIY-VPS workarounds; 2026-09-28 upgraded to HARD structural blocker — Vast's own docs say "CGNAT and shared ISP IPs are not supported", plus the PRIMARY gate is "dedicated machine only" which fabean's multi-tenant k3s box fails, plus a 500 Mbps symmetric public-IPv4 verification bar; competitor landscape: Salad is Windows-only, RunPod/Clore accept pro cards but re-hit the same structural blockers) are durable reference; the lane choice is NOT settled.
---

# fabean compute monetization (explored 2026-09-27, NOT a settled decision)

The person asked, in a chain of escalating "research the best use / an *ends* / computer-as-a-farm-for-money" prompts, how to point fabean at a profitable end state. psnvc researched and distilled it. Nothing was specced or built — this is the research conclusion only.

## The sourced numbers (research, 2026-09-27)

- **RTX A6000 (48GB) open-market rental:** ~**$0.33–0.53/hr** (RunPod ≈ $0.53/hr, Vast.ai ≈ $0.47/hr). fabean has a single A6000 → full 24/7 utilization at $0.50/hr ≈ **$360/mo gross** ceiling for raw silicon.
- **Santa Barbara / Southern California Edison residential electricity:** ~**34.5¢/kWh** average (Jan 2026 SCE advisory, down from 35.3¢; time-of-use spread **23¢ off-peak → 74¢ on-peak summer**).
- **A6000 draw:** ~300W under load (~17W idle).

## The conclusion (the durable principle)

At 34.5¢/kWh, renting fabean's raw GPU is a **money-losing trade** — electricity plus platform/hidden costs (30–65%) eats the margin before any buyer is verified. The only way a single-A6000 box clears SCE power at a profit is to **sell finished work, not raw FLOP-hours**: token-priced inference or agent retainers that are worth **10–50×** the $0.33–0.53/hr raw hour.

fabean isn't just a GPU — it's already a loaded inference/agent-serving stack (k3s + Docker + ollama + LiteLLM + a 13-agent Hermes fleet with OpenAI-compatible HTTP endpoints). The "stack is already there" is what makes the served-outcomes lane feasible without new capex.

## Three candidate business models (presented, not chosen)

1. **Sell the agents' output** to buyers who already pay humans (the tourism/adventure space the person has a foot in — SBACO). Lowest sales friction, highest ceiling-per-buyer.
2. **Own margin engine** — point the fleet at internal operations to cut labor cost.
3. **SaaS platform** — package the factory as "deploy a souled agent in minutes." Highest ceiling, most capital, slowest.

Monetization levers (all sources agree): outcome-based (per-result) > value-based retainer (20–40% of replaced labor) > hybrid (small base + usage tail) > FTE-replacement priced as a fraction.

## "Computer as a farm for money" — the honest split

- **The grift:** "set up a bot farm, money prints itself" / passive-income crypto-trading-bot / "$20K in 7 days." No such set-and-forget wealth machine; honest 30-day testers say plainly it doesn't exist.
- **The real meta:** "one agent, N clients" — build one profitable workflow per vertical, then stamp it out per-tenant with compute running all the time so marginal cost ≈ zero (the $42k-MRR/2-person agency pattern). Already have the factory; missing the buyer half.

## Status

Research + strategic framing complete (2026-09-27). **No lane committed, no spec written.** The direction psnvc *recommended* (not decided) was "served inference + agent-hosting on fabean's existing stack" as Lane 1, but the person did not confirm. Treat any future "spec fabean as a kubernetes-for-rent" prompt as resuming this thread, not starting fresh — the rates and the sell-outcomes-not-GPU-hours conclusion already stand.

## Per-hour $/hr ceiling by lane (researched 2026-09-27, on fabean's single A6000)

The person's exact question escalated to "how to get as much as possible PER HOUR out of it," and later "which is most profitable" and "is this passive or do I go sell it." Clean answer, by lane:

- **Raw GPU rental (Vast.ai / RunPod / Salad) — ~$0.33–0.53/hr gross, net NEGATIVE-ish here.** At 34.5¢/kWh and ~450W (card+system), electricity alone is ~$0.16/hr (~$117/mo) to run flat-out; rental grosses $0.53/hr *max* and an unverified residential host pulls the low end (~$0.20–0.30/hr). This is the ONLY truly "passive" (set-and-list) lane, and it's thin.
- **Served LLM inference (vLLM) — ~$2–6/hr if fully saturated.** `$/1M tokens = (GPU $/hr) ÷ (tok/s × 3600)`. A6000 ≈ 250–300 tok/s on a ~30B model ≈ ~1.08M output tokens/hr of capacity; open 30B self-serve competes at ~$2–6/M output vs GPT-4-class ~$0.40/M input. ~4–11× raw rental, but *only while demand is filling it* — idle = $0/hr.
- **Image gen (SDXL/Flux via ComfyUI) — ~$9/hr+ when saturated** (4–5s/image → ~900 img/hr × even $0.01, up to $0.05–0.15/img at quality tiers).
- **Video gen (Flux/LTX/Wan via ComfyUI) — $3–11 per 10-sec clip, highest $/hr (~$30–300/hr equivalent)** but the most bursty/demand-thin.

**The multiplier in every lane is utilization + demand, not compute.** An idle 46GB A6000 earns $0/hr in every lane. "Max $/hr" is a *sales* problem disguised as a *compute* problem — there is no steady high-$/hr number on a single idle A6000.

### The "passive vs go-sell-it" verdict (2026-09-27, the person asked point-blank)

- **Not passive.** Selling finished work (tokens/clips/agents) has *no* passive listing — it stops being passive the moment it needs a customer you find. The profitable lanes are "a tiny service business," not a money printer.
- **The one positive-passive path is Vast.ai raw rental** — install the host agent, list the A6000, it fills itself. Net ≈ **$4–11/day → ~$120–330/month** (after ~$0.16/hr electricity and ~15% Vast.ai fee), *if* it stays rented, which a low-reputation single-GPU host often won't early on. The person confirmed this understanding ("so vast ai rental still does make it go positive tho and it is passive").
- **Structural truth (worth internalizing):** passive income = renting a *scarce, undifferentiated* asset to a *liquid* market. One A6000 is neither scarce nor differentiated, and SCE power (~34.5¢/kWh) is among the priciest in the country. Real passive GPU money lives in multi-GPU farms in ~8¢/kWh states. On this single card, the passive dream caps at coffee money ($100–350/mo); real money requires selling finished work (10–50×/hr) plus actual sales effort.

### The Vast.ai hosting blocker (researched 2026-09-27 — why "just list it" isn't a one-click passive play)

When the person said "have forge set it up on vast ai," psnvc researched the *canonical* host-onboarding (after the person's "STOP FREEBALLING, go find the tutorial" correction) and found a fundamental structural blocker:

- **Vast hosting requires a separate host account** (distinct from a renter account) — same person, different onboarding path. Only the operator can create it (must accept the hosting agreement).
- **Vast's model is renter → your machine directly.** The docs assume a **static public IP + open ports** pointed at the host. fabean sits on residential internet (likely CGNAT / 5G / cable — no clean public IP), so the router/port/static-IP requirement is *fundamental, not a formality*. The host self-test needs ≥3 **direct** open ports and hard-fails without them.
- **⚠️ Vast's own docs now CONFIRM the blocker is structural, not "routable" (2026-09-28):** the Host Setup page's "Minimum Requirements for Verification" + "IP Requirements" states flatly **"CGNAT and shared ISP IPs are not supported"** and requires a "public IPv4 address with 5 forwarded ports per GPU." This is NOT "not supported until you tunnel" — NeedPorts / DIY-VPS are third-party workarounds Vast does not endorse for clearing this gate. **Conclusion upgraded: the raw-rental lane on fabean may be structurally impossible**, not merely "marginal." The pivot to selling finished work stands even more strongly as the only clean path.
- **The specific port requirement:** a continuous open **TCP+UDP range `16384-32768`**.
- **Vast's verification graders** reward "static IP" and "stable symmetric bandwidth" — a residential box routed through a tunnel ranks *below* datacenter hosts from day one, even if reachability is fixed.

**Two ways to route around the router (researched, NOT chosen — and now flagged as likely NOT Vast-supported per 2026-09-28 CGNAT docs note above):**
1. **NeedPorts** — a purpose-built **paid** service for hosting Vast behind CGNAT. Gives a dedicated public TCP+UDP port range + auth token per machine, wired into the host via `/var/lib/vastai_kaalia/host_port_range` and `/var/lib/vastai_kaalia/host_ipaddr`. Cleanest, but paid + single point of failure + latency hop.
2. **DIY VPS relay** — cheap Hetzner CX22 / DO droplet + WireGuard + iptables DNAT/TCP+UDP forward. ~$4/mo off the top of an already-thin margin. forge can build this end-to-end; it's not Vast's documented path.

**Net verdict (sourced, stable):** on a single residential A6000 behind 34.5¢/kWh, Vast hosting is marginal (~break-even to ~$100/mo, reputation-gated, thin). The passive dream doesn't clear the specific constraints (one card, pricy power, residential ISP) — for Vast or anything else. Treat the upstream conclusion ("sell finished work, not raw GPU-hours") as the durable take; raw rental is gated by a router/port hurdle that isn't cleanly routable. If the operator ever returns to "try Vast anyway," step one is confirming ≥3 direct open ports + a static IP — nothing else matters until that's true.

### Vast verification gates, scored vs fabean — live state + the full blocker list (2026-09-28)

When the person asked "have we gotten any sales on vast?" and then "research what it would take to get vast to work," psnvc checked the live machine *and* researched Vast's verification requirements. Two durable facts landed on top of the existing CGNAT note:

- **Live state (2026-09-28):** fabean's A6000 is **`unverified`**, `occup = x_` (not rented at that moment), and has earned **`$0.0116`** TIL (~1.2¢). The interesting part: a **real renter actually ran a job** on it even while unverified — proof the NeedPorts tunnel + listing *function*, but the machine is **hidden from default search** because `unverified`, so occupancy is sporadic pennies, not a stream.
- **The PRIMARY verification gate is "dedicated machine," not just network.** Vast's verification-stages docs: *"dedicated machines only; any personal workload — mining, gaming, running your own jobs — will automatically fail verification."* fabean is the opposite of dedicated (k3s + 2 Minecraft + a ~13-agent fleet + ollama + LiteLLM all sharing the one A6000), so it **FAILS this gate outright** — this is the core blocker, above and beyond CGNAT. Even fixing the network wouldn't clear it without moving everything else off the card.
- **Explicit network bar for verification:** ≥**500 Mbps symmetric up/down** (10 Mbps minimum only to *list*), a **public IPv4** with ≥100 continuous open ports/GPU, and an explicit **"CGNAT / shared ISP IPs are not supported."** fabean is residential + CGNAT → fails. NeedPorts/DIY-VPS cannot substitute for a symmetric public-IP connection on the verification gate.
- **Also required:** VM/IOMMU enabled in BIOS (passes Vast's virtualization check), plus "several days" of clean uptime for reliability to climb before `verified`.

**Conclusion restated (2026-09-28):** getting Vast to verify fabean is **relocating/repurposing the box, not a tweak** — you'd either colocate the A6000 (dedicated + business fiber) or empty fabean and still likely fail on residential CGNAT. This is now diagnosed, not speculative.

### Competitor landscape for "sell my single GPU" (researched 2026-09-28)

The person asked "does vast have any competitors" then "find the one that's easiest to get to 'renting my GPU and making money NOW'." Researched answer:

- **Salad** — the "download-and-earn NOW" option for *consumer* cards, BUT **Windows-only** (no Linux download), and the A6000 48GB is not in its supported list. Disqualified for fabean's Linux pro card as-is; would need a Windows box + consumer card.
- **RunPod Community Cloud** — accepts pro cards incl. A6000, Linux/Docker, per-second billing; but onboarding is a "vetted third-party host" program (a few days of vetting), no uptime guarantee. Slower-to-first-dollar than Salad.
- **Clore.ai** — crypto payouts, casual, but genuinely lower demand/liquidity → fills slower.
- **Vast** — most buyer liquidity + lowest fees (best *fit* for the A6000 hardware), but the "dedicated machine" + CGNAT gates block fabean specifically.

**Durable takeaway:** the "earn NOW with zero friction" path (Salad) doesn't accept fabean's Linux A6000; every platform that *does* accept it (Vast/RunPod/Clore) re-runs into the same structural blockers (dedicated use + non-residential network + vetting friction). This strengthens — rather than replaces — the already-standing conclusion: **sell finished work, not raw GPU hours.**

### Relevant OSS stack (researched but NOT yet specced/built)

- **Served LLM:** vLLM (30B @ FP8 fits a 48GB card with headroom; 70B-class possible at INT4). fabean already has a (now-dead) vLLM pod to resurrect + a live LiteLLM gateway + a working `nvidia-device-plugin`.
- **Image/video:** ComfyUI (node-based; LTX-2.3 = synchronized audio+video in one pass; Wan 2.2 cost-effective; Flux 3 video). ComfyUI *is* the production API/credit surface for image+video.

## Related

- fabean hardware/stack facts: [[reference/environment.md]] (Second server: `fabean` section)
- agent roster: [[reference/agents-ledger.md]]
