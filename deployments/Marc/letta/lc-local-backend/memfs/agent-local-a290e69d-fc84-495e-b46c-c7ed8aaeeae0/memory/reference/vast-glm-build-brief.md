---
description: Build brief for forge to stand up the vast-glm-l / vast-glm-h agent pair (Letta planner + Hermes engineer) that operates the Vast.ai host on fabean.
---

# Forge build brief — stand up vast-glm-l + vast-glm-h

You own the HOW. Stand up a Letta-planner (`vast-glm-l`) + Hermes-engineer (`vast-glm-h`) pair end-to-end, deploy to the **lima** k3s cluster (same box forge runs on). The TARGET the pair operates is fabean, reachable over Tailscale SSH. Report INLINE, tightly, what you did + the verify results. Do NOT improvise around a failed step — diagnose + fix the specific cause.

## Deploy (do this first)
- `sudo bash /opt/0-0/sudo-letta/kube-scripts/up.sh --vast-glm-l` (Letta planner)
- `sudo bash /opt/0-0/sudo-agent/kube-scripts/up.sh --vast-glm-h` (Hermes engineer)
- Both must show `Running` (`kubectl get pods -A | grep vast-glm`).
- Planner model: deepseek-v4.1-flash via DeepSeek official API (`api.deepseek.com`, provider `deepseek`), same wiring as `rabbit` (see reference/rabbit-second-cluster.md for the env resolution).

## Personas — TWO good base-agent personas, skills-first (NOT bulky persona dumps)

**vast-glm-h (Hermes)** → `SOUL.md` at `/opt/data/SOUL.md` (its HERMES_HOME). **vast-glm-l (Letta)** → `system/persona.md` in its MemFS (frontmatter `--- description: ... ---` REQUIRED).

Each persona must be a real, lived-in agent — name, role (planner=orchestrates+specifies+verifies; engineer=owns the HOW, does the technical work), temperament, a clear goal line — NOT a wall of fabean/Vast facts.

CRITICAL instruction the persona must carry: **"All the fabean + Vast domain knowledge you need is in your SKILLS. Your job is to get good at loading and using those skills — do not try to memorize the operational facts."** The domain knowledge goes in the skills, not the persona.

vast-glm-l persona must ALSO carry the relay (not a "figure it out yourself" hint):
- "Your engineer is `sudo-vast-glm-h`, a k3s Deployment (`deploy/sudo-vast-glm-h`) on the lima cluster — NOT a docker container, NOT `sudo-forge`/`sudo-FA24`/`sudo-ardy`. Ignore docker-daemon containers when delegating."
- The verbatim one-shot + the three `inf` timeout env vars (see below) + "this bridge IS the mechanism, don't re-derive it; bare `nsenter` stays in your own pod."
- Point to `skills/reaching-my-engineer/SKILL.md`.

## THE RELAY (verbatim bridge the planner uses to message its engineer)
```
docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest sh -c "nsenter -t 1 -m -u -i -n -p -- env HERMES_STREAM_READ_TIMEOUT=inf HERMES_STREAM_STALE_TIMEOUT=inf HERMES_API_CALL_STALE_TIMEOUT=inf KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl exec -i deploy/sudo-vast-glm-h -- hermes -z '<single-line prompt>'"
```
The `inf` vars disable the 120s timeout — without them long jobs die and the planner invents `&`/cron workarounds. `inf`, NEVER `0`.

## Skills to author (write these into each agent's MemFS `skills/` as high-quality info manuals)
1. `skills/reaching-my-engineer/SKILL.md` (planner) — the relay above, verbatim.
2. `skills/operating-vast-on-fabean/SKILL.md` — the Vast ops manual. Contents (from reference/vast-a6000-end-state-prompt.md — read that file for the live state):
   - Machine id 152421, registered + listed, RTX A6000, driver 595.84, verification `unverified`.
   - The two-key model: ACCOUNT/API key `VAST_API_KEY=[REDACTED]...` for the CLI (`vastai show machines|list machine|self-test`); the HOST/install auth is a one-hour token from the Host Setup page that expires — do NOT treat the old `[REDACTED]...` as valid (returns "Invalid user key").
   - List commands: `vastai list machine <id> -g <$/hr> -b <minbid> -m 1` (role must be `host`: `vastai set role host`).
   - Self-test: `vastai self-test machine <id>` — the gate. It needs a RENTABLE offer, which will NOT appear until Vast's automated verification indexes the machine (daily, unexpandable). If it fails "No on-demand offer found," that's the verification wait, not a config bug.
   - CGNAT caveat: fabean is residential; Vast wants a public IPv4 + open ports ("CGNAT not supported"). NeedPorts (`33013-33062` → `15.204.86.122`) is the workaround; self-test passing through the tunnel is the make-or-break unknown.
   - Bottom line: rentable ≠ profitable; break-even to ~$100/mo.
3. `skills/fabean-access-and-admin/SKILL.md` — fabean ground truth:
   - SSH: `ssh [REDACTED]@fabean` (Tailscale), sudo via `echo [REDACTED] | sudo -S <cmd>` ([REDACTED] IS a real sudo user, password `[REDACTED]`). Do NOT use `sudo su - [REDACTED]` (doesn't exist). `who` (uid 1000) has its own kubeconfig `/home/who/.kube/config` (no sudo needed for kubectl).
   - Stack: Docker 29 + k3s + ollama (127.0.0.1:11434) + nvidia-smi; A6000 GPU.
   - Vast creds live at `/home/who/vast-hosting/.env`.
   - Tailscale SSH re-auth: if SSH fails with a `login.tailscale.com/a/<id>` link, surface it to the operator and stop — do not loop/retry.
4. `skills/vast-daemon-and-tunnel-ops/SKILL.md` — Vast daemon + NeedPorts ops:
   - Daemon `vastai.service`, state at `/var/lib/vastai_kaalia/` (machine_id, api_key, kaalia.log, send_mach_info.log).
   - Install command + the flags that work on fabean's existing stack: `python3 install <fresh-auth> --reset-machine --no-driver --no-docker --no-libvirt --agree-to-nvidia-license --no-partitioning` (`--reset-machine` forces re-registration; the `--no-*` flags avoid wiping fabean's Docker=k3s and driver).
   - NeedPorts install: `curl -fsSL https://api.needports.com/install | sudo bash -s -- <TOKEN> --accept-tos --mode vast`.
   - Port wiring: write range to `/var/lib/vastai_kaalia/host_port_range` and IP to `host_ipaddr`.
   - Reading the 404: `send_mach_info.log` "Failed to send Data, status 404" = machine not registered (bad/expired auth); `kaalia.log` healthy = heartbeat messages, no "on_read error: End of file".

The engineer (vast-glm-h) gets the same manuals so it can read them too.

## Persona self-write pitfall (CRITICAL)
For the NEW Letta agent, `persona.md` only sticks if **vast-glm-l SELF-WRITES it** inside a session (raw outside file-commit does NOT inject — `<self>` core memory is projected one-way and cached). Have vast-glm-l write `system/persona.md` + commit via its own memory/Write tool. Verify `letta -p "who are you"` returns the real name, not "Letta Code". Same approach for dropping skills into its MemFS.

## Verify + report
- Both pods Running.
- `letta -p "who are you"` on vast-glm-l → answers as vast-glm-l.
- `hermes -z "who are you"` on vast-glm-h → answers as vast-glm-h.
- Prove vast-glm-l can reach vast-glm-h (have it run the bridge), and reach fabean (`ssh [REDACTED]@fabean 'hostname'` → `fabean`).
- Report: pods, names verified, skills authored, relay proven, anything changed outside the plan.

Do NOT configure payouts/billing (operator-only). Read reference/vast-a6000-end-state-prompt.md and reference/environment.md for live ground truth if you need more detail.
