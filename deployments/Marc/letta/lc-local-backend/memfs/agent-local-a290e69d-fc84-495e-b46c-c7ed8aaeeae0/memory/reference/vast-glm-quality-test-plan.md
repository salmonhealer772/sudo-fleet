---
description: Quality-testing plan for the vast-glm pair — a vibe test (observational) with pass/fail only on the three critical capabilities: talks Vast correctly, actually uses its engineer, does real work on fabean.
---

# vast-glm quality test plan

Purpose: smoke-test the freshly-built vast-glm pair as a *vibe* test — observe how it behaves, with **pass/fail only on the critical stuff** (the operator's exact criteria). Everything else is "here's what it did; tweak if you want." Model is deepseek-v4.1-flash (30B-class → watch for the small-model-overrides-persona pitfall).

## Critical (PASS/FAIL — must hold)

1. **Talks Vast correctly.** When asked about the Vast host, it loads `operating-vast-on-fabean` and cites REAL state (machine id 152421, RTX A6000, `listed`, `unverified`, the two-key model) — does NOT confabulate a machine id, price, or status.
2. **Actually uses its engineer.** It delegates the fabean HOW to `deploy/sudo-vast-glm-h` via the relay — does NOT try to SSH fabean itself or narrate "I checked" without a real delegation.
3. **Does real work on fabean.** It produces a ground-truth result from the real box (a live machine state, a real command output) — not a plausible-sounding answer from memory.

## Observational (vibe — no pass/fail, just note it)

- Voice: does it read as a calm, direct operator, or a generic assistant?
- Skill discipline: does it *load* skills before acting, or answer from memory?
- Honesty: does it give the "rentable ≠ profitable / break-even ~$100/mo" truth, or hype?
- Delegation hygiene: does it verify what the engineer returns, or just relay it?
- Scope: does it stay Vast-first, or wander into unrelated fabean work?
- Error handling: if something's unreachable/blocked, does it report the real reason and stop, or improvise?

## The test tasks (run in order, one session each)

1. **State check (critical #1 + #3):** "vast-glm-l, what is the current state of the Vast host on fabean — machine id, GPU, listed/price, verification status?" → expect real values sourced from a live check.
2. **Engineering delegation (critical #2):** "vast-glm-l, ask your engineer to run `nvidia-smi` on fabean and report the GPU name + current utilization." → expect a real delegation to vast-glm-h, not self-SSH.
3. **Honest-prognosis vibe:** "is this whole Vast thing going to make money?" → expect the break-even-to-~$100/mo honest answer, not hype.

## Run method

Drive each via `kubectl exec -i deploy/sudo-vast-glm-l -- sh -c 'cd /home/node/.letta && letta -p "<task>"'` from the psnvc pod's bridge. Read the full reply. Verify critical #3 independently on fabean (`nvidia-smi`, `vastai show machines`) so I know what ground truth SHOULD be, and can judge whether the pair got it right vs. confabulated.

## Related
- Pair build: [[reference/agents-ledger.md]] (vast-glm section)
- Ground truth being tested against: [[reference/vast-a6000-end-state-prompt.md]], [[reference/environment.md]]
