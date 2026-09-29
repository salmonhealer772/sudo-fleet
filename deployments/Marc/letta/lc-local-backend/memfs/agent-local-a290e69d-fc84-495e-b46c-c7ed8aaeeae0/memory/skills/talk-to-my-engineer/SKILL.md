---
name: talk-to-my-engineer
description: Reach my engineer, forge, and message it — say hi, ask a question, dispatch a job, or check on it. Use when the person says "say hi to forge", "talk to your engineer", or any time I need to message forge. This is THE skill for reaching forge; load this (not cross-host-execution) for any forge interaction.
---

# Talk To My Engineer

My engineer is **forge**. This skill is the single entry point for reaching it. Load this whenever I need to message forge — say hi, ask a question, hand it a job, or check on it. Don't reach for `cross-host-execution` for a forge interaction; that skill is the broad "any box, any bridge" cookbook. This one is just forge.

## Who forge is

- **forge** = my engineer, the "hands" half of our pair. I spec the WHAT; forge owns the HOW.
- It lives as a k3s Deployment named **`sudo-forge`** (`deploy/sudo-forge`) on the **lima cluster** (lima VM, 192.168.5.15).
- It is NOT a docker container, NOT a fabean pod, NOT any other agent. It's `deploy/sudo-forge` in k3s.
- Its identity/soul lives at `HERMES_HOME/SOUL.md` (= `/opt/data/SOUL.md` inside the pod); rewrite that to change who forge is.

## The one command (say hi / ask / dispatch / check)

Run this through the docker-socket host bridge, exactly:

```
docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest sh -c \
  "nsenter -t 1 -m -u -i -n -p -- env KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl exec -i deploy/sudo-forge -- hermes -z '<single-line prompt>'"
```

- `hermes -z '<prompt>'` is the one-shot: fresh session, answers inline, returns the reply.
- Single-line prompt only. For a big brief, write it to a file in the pod first, then `hermes -z "Read /opt/data/<name>-brief.md and do the task. Report back."`.
- Swap only the `hermes -z '...'` prompt. Do not re-derive the bridge.

## For long jobs — disable the 120s timeout (TWO caps, fix both)

There are **two independent 120s caps**, and only fixing one still leaves the job dying:

1. **The Hermes stream timeout** — fixed by the `inf` env vars (below).
2. **The Bash tool's own default 120s timeout** — this severs the `kubectl exec` pipe mid-job *even when the Hermes stream timeouts are `inf`*. Fix it by passing the Bash tool's `timeout` parameter > 120s (e.g. `timeout: 600000` = 10 min, the max).

For any job that might run longer than 120s, set BOTH: the `inf` env vars, and a Bash `timeout` of 600000. Putting `inf` in the bridge and leaving the Bash timeout at default still kills the dispatch at 120s — this was the exact repeated failure in the `sudo-fleet` pytest build (2026-09-28): three dead dispatches, each repainted as progress, until the 10-min connection was passed.

The `inf` env vars go in the bridge:

```
docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest sh -c \
  "nsenter -t 1 -m -u -i -n -p -- env HERMES_STREAM_READ_TIMEOUT=inf HERMES_STREAM_STALE_TIMEOUT=inf HERMES_API_CALL_STALE_TIMEOUT=inf KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl exec -i deploy/sudo-forge -- hermes -z '<prompt>'"
```

- `inf` = infinite (disables the timeout). **Never `0`** — `0` is instant timeout.
- Always set all three: `HERMES_STREAM_READ_TIMEOUT`, `HERMES_STREAM_STALE_TIMEOUT`, `HERMES_API_CALL_STALE_TIMEOUT`.
- Timer is seconds: `600` = 10 min for a bounded/quick ask; `inf` for a real build/install.

## Is forge running? Trust the process list, then try one message

- The ONLY ground truth is the process list: check it with `kubectl exec <pod> -- ps aux | grep hermes` (or `ps -ef | grep forge` host-side). A bare grep-only result = "not running, full stop."
- `kubectl get deploy` showing "1/1 Running" is NOT proof an agent is answering — just that the container is up.
- **"DONE" = the result file, not the process.** A live `hermes -z` PID in `ps` only proves the job *started*, never that it *finished*. Check the output/result file (exists *and has content*) before declaring any state. Before firing a new dispatch, check `ps aux | grep hermes | grep -v gateway | grep -v mcp_server | grep -v watch`; if a `hermes -z` PID is already alive and its CPU is climbing, DO NOT dispatch another — the job is already running (2026-09-28: three stacked PIDs 622/1045/1530 did the same job racing, dropping a junk `.venv`).
- If forge won't answer a `say hi`, the minimal correct fix is `kubectl rollout restart deploy/sudo-forge` (a stale gateway after being up for days is the common cause), then send ONE plain `hermes -z "say hi"`. No `nohup`, no backgrounding, no base64 staging, no reachability forensics for a simple hi.

## Traps (do not hit these)

- **Docker socket is not forge.** `/var/run/docker.sock` in my pod is the lima-VM docker daemon — it shows other docker containers, never the k3s `sudo-forge`. Bridge to k3s, don't stop at docker.
- **Bare `nsenter -t 1` stays in my own pod** (pods ship without `hostPID` — it re-enters my own `sh -c tail -f /dev/null`, no kubectl/kubeconfig there). Only the docker-socket bridge reaches the real host (Ubuntu 26.04, `/etc/rancher/k3s/k3s.yaml`).
- **Backgrounding `&` gets swallowed** by the outer shells — forge never starts, no process, no log, looks like it worked. If a job must be detached, background INSIDE the pod: `kubectl exec <pod> -- sh -c 'nohup hermes -z "<prompt>" > /opt/data/<name>-dispatch.log 2>&1 &'`, then confirm with `ps aux | grep hermes`.
- **To learn a detached job's result, read the file when asked.** Do NOT arm a Monitor/watcher and wait for an event — that does not work reliably. Read `ps` + the log/result file directly.
- **The host's `/opt/data` is NOT the pod's `/opt/data`.** To hand forge a file, get it INTO the pod first (`kubectl cp` to the real pod name, not the Deployment), or forge reports "File not found."
- **`kubectl cp deploy/sudo-forge:…` fails** — `kubectl cp` needs the pod name (`sudo-forge-<hash>`). Get it with `kubectl get pods | grep sudo-forge`.
- Stateless one-shots: every `hermes -z` is a fresh session with no memory of the last. For multi-step work, give forge a brief file to read, not a giant inline prompt.

## Verification

- Bridge works: command returns real output, exit 0.
- forge answered: got an actual inline reply from `deploy/sudo-forge` (e.g. "Alive. Go ahead."), not a docker-container mis-fire.
- A long job actually started: `ps aux | grep hermes` inside the pod shows a live `hermes -z` PID.
