---
description: The settled conclusion on monetizing fabean's A6000 (2026-09-28) and the open fork left for the operator. Vast unverified + platform research done; the decision now is inference vs colo vs stop.
---

# A6000 monetization — settled conclusion + open fork (2026-09-28)

**The whole "make the A6000 earn" thread now has a settled conclusion.** Record this so no one re-derives it.

## What's DONE and leaves a clean state

- **Vast host:** machine **152421** registered + listed at $0.20/hr (min-bid $0.10), `unverified`. Trickle-only (~$0.01 earned to date). Fully operational.
- **vast-glm pair** built + quality-tested: `vast-glm-l` (Letta planner, deepseek-v4.1-flash) + `vast-glm-h` (Hermes engineer). Personas = base-agent (skills-first, not domain-dumps). 4 info-manual skills authored into both. Relay proven. `vast-glm-l` can SSH + sudo (`echo [REDACTED] | sudo -S` → root) on fabean via the docker+nsenter host bridge (NOT bare ssh — that was the access bug fixed during testing).

## The settled conclusion (all markets researched)

**The blocker is NOT platform-specific: it's residential CGNAT = no inbound reachability + not a dedicated machine.** Every GPU marketplace needs renters to reach IN; fabean can't accept inbound. So:

- **Vast** → hard-requires "dedicated machines only" + 500 Mbps symmetric + public IPv4 "CGNAT not supported." fabean fails all three structurally. Won't verify.
- **Clore** (researched by vast-glm-l) → "same wall, different paint." Accepts A6000 mechanically, but same CGNAT wall, its own "unverified" flag, crypto-only payouts with +15% fee, thin A6000 demand (~2 cards on whole platform). Not a fix.
- **Salad** → Windows + consumer GeForce cards only. Useless for Linux A6000. (Would fit a Windows gaming PC if the operator ever idle-farms that.)
- **RunPod Community** → accepts A6000, but vetted-provider flow, still gated by inbound reachability.

**The only things that would actually work:**

1. **Real inbound path** (public IP / business fiber / colo) → then *any* marketplace verifies. Physical/logistics cost, not config.
2. **Sell finished work off the card** (served inference / image gen / agent output) → no verification, no inbound-renter requirement, ~4–11× raw $/hr. This is the lane that actually earns on fabean as-is.

## The OPEN FORK (operator to decide, maybe later)

Operator: "might, might not, come back to this later." Three options on the table, choose one word when returning:
- **`inference`** → scope the served-inference / finished-work build (what runs on card, how exposed, who buys first).
- **`colo`** → investigate public-IP / colocation route to make renting actually verify.
- **`stop`** → leave as-is (listed-Vast trickle + vast-glm pair managing it).

## Related
- Vast build + live state: [[reference/vast-a6000-end-state-prompt.md]]
- Economics (sell-work-not-GPU-hours): [[reference/fabean-compute-monetization.md]]
- Pair build + QA: [[reference/agents-ledger.md]], [[reference/vast-glm-quality-test-plan.md]], [[reference/vast-glm-pair-spec.md]]
