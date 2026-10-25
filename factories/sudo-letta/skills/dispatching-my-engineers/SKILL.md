---
name: dispatching-my-engineers
description: How sudo-fleet-glm-l hands tasks to its five engineers and reads their results. Load before any dispatch.
version: 0.1.0
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [sudo-fleet, dispatch, engineers, bridge]
---

# Dispatching my engineers

The canonical bridge to hand a task to an engineer (verbatim — do not re-derive it):

```
docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest sh -c \
  "nsenter -t 1 -m -u -i -n -p -- env HERMES_STREAM_READ_TIMEOUT=inf HERMES_STREAM_STALE_TIMEOUT=inf HERMES_API_CALL_STALE_TIMEOUT=inf KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl exec -i deploy/sudo-sudo-fleet-glm-h1 -- hermes -z '<single-line prompt>'"
```

Rules, verbatim:

- `inf` disables the timeout. **Never `0`** — `0` is instant timeout.
- All three `HERMES_*` vars always, together.
- Swap only the `hermes -z '...'` prompt and the `h<N>`. Do not re-derive the bridge.
- Bare `nsenter -t 1` from inside the pod re-enters the agent's OWN pod, not the host. Use the bridge.
- The docker socket shows the lima docker daemon, not k3s — other `sudo-*` things there are not siblings.
- One job in flight per engineer. Stacking OOM-kills the pod (exit 137).
- A live `hermes` PID means started; the result file means done. Prefer `message-agent` in `inbox` mode + reading the reply later over a blocking `direct` call.

## My five engineers

`sudo-sudo-fleet-glm-h1` through `sudo-sudo-fleet-glm-h5` (doubled `sudo-` is the real deployment name, not a typo). Five k3s Deployments on lima. Nothing else on the docker socket is my team.

## The one-job-in-flight rule

One job in flight per engineer, always. Stacked dispatches OOM-kill the pod (exit 137) and return nothing.

## The result-file-beats-process-list rule

A live `hermes` PID only means a job STARTED. The result file is what means DONE. When an engineer is told to write its report to a file, read that file — never declare done from a process list.

## The inbox-vs-direct rule for message-agent

Prefer `message-agent` in `inbox` mode (fire-and-forget) and read the reply later via the queue status. `direct` blocks for the whole of the other agent's turn — use it only for instant recall/read answers, never for work. Always load the `message-agent` skill before calling the tool.

## Verifying results

Verify each returned task against the repo/cluster, never against the engineer's self-report. A self-reported "done" is a claim; the committed push and a re-read of the file is the proof.
