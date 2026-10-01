# 2026-10-01 — session close-out (work since 2026-09-29)

Recorded by psnvc. Spec: `SPEC.md`. Known gaps: `KNOWN-ISSUES.md`. Backlog: `IMPROVEMENTS.md`.

## One repo
- `57ac3e6` folded `sudo-agent` + `sudo-letta` into `factories/` — one repo, one entity. Working root for all factory work is now `factories/`.
- `37e4c64`, `9d8cb33`, `11860cc`: brought the docs, tests and features that only existed in `comm-skills-tools` into `factories/` and pointed the canonical-source comments at `main`.

## Comm layer (the mesh)
- Tools that shipped: `list-siblings`, `message-agent`, `check-agent`, plus `queue_status`. `check-agent` replaced the two planned tools `check-what-agent-is-doing` and `check-agent-logs`.
- `1638213`, `101713d`: `message_agent` defaults to `inbox`. `direct` is an explicit opt-in, for quick recall questions only.
- `fe8b19f` (Hermes) and `3476116` (Letta): **Change A**. A comm tool refuses to run until its skill has been loaded in the current conversation. `queue_status` is registered.
- `b0a2ab6`: **Change B**. Fleet-comm awareness is a factory-managed block between `FLEET-COMM-AWARENESS` markers in `SOUL.md` / `persona.md`, re-applied on every boot.
- `bf4ba95`: fixes from the Change B integration test (gap in the Hermes first-boot block; git-commit failure when seeding Letta skills).
- `6bb141e` `[skills-fix]`: comm skill wording (load-before-calling in the frontmatter, `queue_status` naming, removed stale "vendored" text).
- `d7d28f5`: documented the gate and the managed block; added `KNOWN-ISSUES.md`.
- `8295eb5`: retired the old messaging. `talk-to-my-engineer` and `make-agents-talk` moved to `skills/_archived/`; the nsenter / `kubectl exec` / `hermes -z` bridge was removed from the Caesar SOUL and the Marc persona.

## Docker socket and privilege
- `a4df988`, `67337d1`: Hermes now gets the docker-socket group before the first privilege drop. The bug is marked RESOLVED in KNOWN-ISSUES with its root cause.
- `9ac8e1e`, `eb44240`: Letta grants the docker-socket gid through `supplementalGroups` (the earlier `setpriv` + `runAsUser 0` approach was dropped). Letta images rebuild when their source changes, and every prompt passes `--agent`, fixing the engineer→Marc `--conv default requires --agent` error. Found and fixed on Blake's laptop by forge-3.

## up.sh and deploys
- `4f2ea72`: an image-sha annotation makes up.sh roll the pod when only the image changed.
- `2287c8e`: agent Deployments use the `Recreate` strategy. With hostNetwork pods, a RollingUpdate starts the new pod beside the old one, where its fixed ports and `gateway.lock` are already taken, so it crash-loops.

## Durability and ops
- `a50ac4f`: the cluster comes back on its own after a reboot — WSL2 systemd boot, a boot auto-up unit, image re-import, readiness/liveness probes.
- `836946d`, `c1fbd3b`: backup/save scripts for one agent or the whole fleet; a full fleet backup was taken 2026-10-01.
- `fe88ead`: `stream.sh` defaults to the full-detail ("rich") output; fixed D1–D8; the in-pod `rich_tap` ships.
- `d839ac3`, `5177d04`: the auto-save patch now finds its insertion point on both older and newer Hermes base images.
- `169bae5`: the shell entrypoints document themselves.

## Fleet state
- Engineers forge, forge-2, forge-3, forge-4 and forge-5 are running on lima k3s. forge-4 and forge-5 were cloned from forge's live `/opt/data` without `state.db`, deployed with `up.sh --from-glimor /opt/glimors/<name>` (the same method as forge-2 and forge-3).
- The operator stopped forge-5's `testdrive-prep` job (rebuild + roll + verify both directions) at about 03:47 UTC because that work had already been done. Its `verify-comm.py` was deleted, and no `testdrive-prep-result.md` was written.

## Loose ends
- Untracked in the lima checkout: `durable-boot-proof/`, `durable-boot-proof-expected-token.txt` and `durable-deploy.log`. They were left out of this commit.
- From SPEC "Open / not settled": still open are the off-box target for disaster-recovery saves, how often to snapshot the whole fleet, and what an outside agent must pass to join the fleet.
