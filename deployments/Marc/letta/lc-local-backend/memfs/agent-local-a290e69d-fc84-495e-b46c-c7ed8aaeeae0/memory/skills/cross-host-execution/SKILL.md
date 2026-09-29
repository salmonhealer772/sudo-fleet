---
name: cross-host-execution
description: Run commands on the host, another pod, or a remote machine (fabean, the Mac) from inside a pod. Use when cross-container/SSH execution is needed and for the docker+nsenter host bridge and its quoting rules.
---

# Cross-Host Execution

The canonical, correct way to run commands on the host / another pod / another machine from inside a pod. This is the most error-prone recurring op in the system — follow the recipes exactly and obey the quoting rules.

## Who does the work (read first)

My engineer is **forge** — deployed as `sudo-forge` on the **lima** cluster (192.168.5.15). forge owns the HOW of all engineering, including work on remote boxes like **fabean**.

When a task needs deep technical work — on fabean, on the host, on any pod — I hand the whole job to forge and let forge do the execution itself (forge reaches fabean with `ssh who@fabean` and operates its k3s cluster directly). I spec the WHAT, forge owns the HOW.

For quick, contained, read-only checks I may run a command directly — but any real build / fix / change / multi-step engineering goes through forge, dispatched with `kubectl exec -i deploy/sudo-forge -- hermes -z "..."`, and forge carries it end-to-end and reports back. I verify forge's result, I do not do the engineering myself.

**Is forge actually running? The only test that matters is the process list.** `ps -ef | grep <name>` (or `grep hermes` inside the pod) IS the ground truth. A bare grep-only result = "not running, full stop." A `kubectl get deploy` showing "1/1 Running" is NOT proof — it only means the pod/container is up, not that the forge *agent* is answering. Do not rationalize an empty `ps` away with PID-namespace / PPID / "the task is detached" theories. And when forge won't answer, reach for the minimal correct fix rather than forensics: `kubectl rollout restart deploy/sudo-forge` (a stale gateway is the common cause — forge had been up 6+ days with a dead gateway on 2026-09-16), then send ONE plain `kubectl exec -i deploy/sudo-forge -- hermes -z "say hi"` and read the reply. No `nohup`, no backgrounding, no base64 staging, no reachability checks for a simple "is it alive / say hi." The one-shot answers instantly when the pod is healthy; if it doesn't, the problem is the pod (restart it), not your command.

## When to Use

- Any time you need to run kubectl/docker/ssh or touch files that live on the HOST, not in your container.
- Reaching a remote box (fabean, the Mac) via SSH from inside a pod.
- Driving another Hermes agent (`hermes chat -Q`) from a script.

## Core Recipe — reach the host

```
docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest sh -c \
  "nsenter -t 1 -m -u -i -n -p -- <command>"
```

- **This docker-socket bridge is THE correct way.** It reaches the real host (Ubuntu 26.04, systemd PID 1, `/etc/rancher/k3s/k3s.yaml` + `/usr/local/bin/k3s` present) regardless of your own pod's capabilities.
- **`sudo nsenter -t 1 ...` does NOT reach the host from a Letta/sudo pod.** It re-enters your OWN container's PID 1 (`sh -c tail -f /dev/null`) because pods ship without `hostPID` — so "PID 1" in your namespace is your own init, not systemd. It *appears* to run (you get a root shell in your own container), but `kubectl`/`k3s`/`/etc/rancher` are absent there. Always use the docker bridge. (Verified 2026-09-08.)
- **Bare `nsenter -t 1 ...` (no `sudo`) fails** `Operation not permitted`: non-root pod (`node`), no `CAP_SYS_ADMIN` in effective set.
- The host kubeconfig is `/etc/rancher/k3s/k3s.yaml`; export it before kubectl: `KUBECONFIG=/etc/rancher/k3s/k3s.yaml`.
- The docker socket is `/var/run/docker.sock` (group `dockerhost`); kubectl + docker live on the HOST, not in your pod — cross to the host first to use them.

## Remote machine (add ssh)

On the host, or from inside a pod via the bridge above, then:

```
ssh <user>@<host> '<command>'
```

- fabean: `ssh who@fabean` (Tailscale SSH, no key/password; periodic re-auth link; `root@fabean` also works). **`who` is NOT root, but has its own WORKING kubeconfig at `/home/who/.kube/config`** (server `https://127.0.0.1:6443`) — so `kubectl` runs fine as `who` (uid 1000) WITHOUT sudo (verified 2026-08-26). The `[REDACTED]` sudo password does NOT work for `sudo` as `who`. Escalate to root/cluster-admin with `sudo su - [REDACTED]` (sudo password = `[REDACTED]`) only when `who`'s kubeconfig is denied.
- Mac (himalaya): `ssh [REDACTED]@192.168.5.2 '/opt/homebrew/bin/himalaya ...'`.

## Quoting rules (where 90% of past failures come from)

- Single-quote the inner script. Do NOT put `$VAR` inside a double-quoted outer layer — an outer shell expands it to empty before the inner shell sees it.
- For prompts/strings with special chars (`$`, quotes, backticks, `|`, `&`), base64-encode then decode on the far side: `echo "<b64>" | base64 -d | <cmd>`.
- **A heredoc written THROUGH the nested bridge still eats backticks — the quoted delimiter does NOT protect you.** `cat > /path/file <<'EOF' ... EOF` is only literal when the heredoc body never crosses an outer `sh -c "..."` double-quoted layer. If you wrap the whole thing in `docker run … sh -c "… cat > … <<'EOF' … EOF …"` (double-quoted outer shell), the outer shell evaluates backticks (and `$()` and `$VAR`) in its own string BEFORE the heredoc's `'EOF'` ever applies — so `` `cross-host-execution` `` comes back as `command not found`. This happened 2026-09-28 writing `BASE-SKILLS.md`: every backticked skill name in the heredoc became a bare command. **Fix: never inline a content-bearing heredoc inside a double-quoted bridge command. Write the file container-locally first (heredoc/Edit in your own `/tmp`, where `<<'EOF'` IS safe), then base64-transfer it over** (the recipe below). If you must heredoc across the bridge, use `\$`, `\`` escapes or single-quote the outer layer — but the local-write-then-base64 recipe is what actually survives.
- `-i` = stdin (non-interactive pipe); `-it` = interactive TTY. Pick correctly.
- Never mask exit codes with `| tail` / `| head` — run the command bare, or capture `$?` explicitly.
- Hermes pods run as uid 10000; host operator is [REDACTED] (uid 1001) / lima root. Cross-identity file writes need `chown` to the right uid afterward.

## Managing a host-side docker CONTAINER (not a pod) — run docker inside nsenter

When the target is a plain docker *container* on the host (e.g. `linkedin-mcp-server`), you manage it with **host-side `docker`**, not `kubectl`:

```
docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest sh -c \
  "nsenter -t 1 -m -u -i -n -p -- docker exec <container> <cmd>"
docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest sh -c \
  "nsenter -t 1 -m -u -i -n -p -- docker commit <container> <image>:<tag>"
```

- **Run `docker` INSIDE the `nsenter` host context.** If you chain it after an inner `sh -c` instead (the wrong layering), `docker` is not on PATH there → `sh: docker: not found` (exit 127). The `docker` binary lives in the host namespace; put the whole `docker ...` command right after the `--` that follows `nsenter`, don't nest it under another `sh -c`.
- `docker cp` copies via the HOST's real `/tmp`, not your alpine container's `/host/tmp` — stage files at host paths.
- Reach a host container's filesystem directly: `nsenter ... -- docker exec <container> sh -c 'ls -la /app/...'` (nest the inner quotes carefully, or base64 the inner command).
- A `docker commit` bakes the live container's filesystem (including uncommitted venv edits) into a new image layer so changes survive a container recreate — the edit/delete code for `linkedin-mcp-server` sat only in the live venv until `docker commit ... :write` made it durable.

## Writing a file ONTO the Mac (the working recipe)

The Mac's root is mounted into the lima host at `/mnt/mac` (writable virtiofs), so Mac-side files under `/mnt/mac/Users/[REDACTED]/...` are writable through the host bridge. But the naive approaches all drop content — use this exact recipe (proven 2026-09-08 while writing the ms-glm SPEC/PERSONAS docs):

1. Write the content to **your container's `/tmp`** first — `cat > /tmp/foo.md <<'EOF' ... EOF` (heredoc is fine HERE, because this is container-local, not crossing the bridge).
2. Base64-wrap it **into a shell variable**: `B64=$(base64 -w0 /tmp/foo.md)`.
3. Decode it host-side, inside the `nsenter` context, writing to the `/mnt/mac` path:
   ```
   docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest sh -c \
     "nsenter -t 1 -m -u -i -n -p -- bash -c 'echo \"$B64\" | base64 -d > /mnt/mac/Users/[REDACTED]/Documents/notes/foo.md'"
   ```
4. Read back and confirm byte-count / `head` to verify the content actually landed (a 0-byte file = the transfer silently dropped it).

**Large-file transfers (>~128KB) — the base64-into-`echo $B64` recipe ABOVE DOES NOT SCALE (2026-09-29).** Packing the base64 into a `sh -c "... echo \"$B64\" ..."` argument wraps the whole thing into a single shell command string capped around 128KB, so a big payload (a 6.4MB state tarball) dies with `Argument list too long` — and *so does splitting it into <1MB base64 chunks* (each chunk as an argument still overflows the per-command cap). The working fix for large files is to **pipe the raw bytes through stdin and never pass them as a command-line argument**:
   ```
   # into a pod:
   docker run -i --rm --privileged --pid=host --net=host -v /:/host alpine:latest sh -c \
     "nsenter -t 1 -m -u -n -p -- env KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl exec -i deploy/sudo-forge -- sh -c 'cat > /opt/data/psnvc-state.tgz'" < /tmp/psnvc-state.tgz
   ```
   `-i` (NOT `-it`) carries stdin cleanly; the moment you route input through an `echo` argument instead of stdin, the argument-size cap bites. Verify bytes landed with `ls -l` on the far side (an exact byte-count match means the stdin pipe worked).
- `echo "$B64" | base64 -d | docker run ... base64 -d > target` in one pipeline — the `$B64` expansion dies in the outer→inner crossing and/or the `-i` stdin eats the pipe; files land as **0 bytes**.
- `cp /tmp/foo.md /mnt/mac/...` run host-side — the `-v /:/host` bind mounts host-root at `/host` ONLY; your container `/tmp` is NOT the host's `/tmp`, so `cp: cannot stat '/tmp/foo.md'`.
- `kubectl cp /tmp/foo.md pod:/opt/data/...` — `kubectl`/`kubectl cp` (run via nsenter) resolve paths against the **host's** filesystem, not your container's (same gotcha already noted for `docker cp`).

## Pitfalls

- **Invocations vary by box/build — verify before assuming.** `--query-file` does NOT exist on any build. `--reasoning` / `agent.reasoning_effort` exist on the lima host's Hermes build but NOT on fabean's. forge's build: top-level `hermes -z "<prompt>"` is the working one-shot. ioi-h (fabean) uses `hermes chat -q "<prompt>"`. Don't copy one invocation across agents blindly.
- **The WORKING way to call forge one-shot:** `kubectl exec -i <forge-pod> -- hermes -z "<single-line prompt>"` — returns the answer inline. For a big brief, write it to a file in the pod (`kubectl cp` → `/opt/data/<name>-brief.md`) then `hermes -z "Read /opt/data/<name>-brief.md and do the task. Report back."`. Do NOT pipe a heredoc into `hermes chat -q -` (forge sees empty `-`). (forge also runs a `gateway run --replace` sidecar; that's separate from the `-z` one-shot.)
- The 120s stream timeout cuts long Hermes calls mid-run. Prefix `env HERMES_STREAM_READ_TIMEOUT=inf HERMES_STREAM_STALE_TIMEOUT=inf HERMES_API_CALL_STALE_TIMEOUT=inf`. Never set it to `0` (that's instant, not infinite).
- Stateless one-shots: every call is a fresh session with no memory of the previous one — for multi-step work give forge a brief file to read, not a giant inline prompt.
- **Backgrounding (`&`) through the nested bridge gets SWALLOWED — forge never starts.** Appending `&` to a `docker run … nsenter … kubectl exec … hermes -z "…"` chain does NOT background the inner `hermes`; the `&` is consumed by one of the outer shells, the command dies instantly, and forge never runs (no process, no log, and the dispatch *looks* like it worked). Proven 2026-09-08 (the ms-glm build dispatch silently failed twice like this).
- **`nohup … &` inside the pod does NOT actually make a long job reliable — a visible PID is NOT proof it's working.** Even when you background *inside* the pod (`kubectl exec <pod> -- sh -c 'nohup hermes -z … > /opt/data/<name>-dispatch.log 2>&1 &'`) and confirm a live PID in `ps`, the backgrounded job STILL dies at the model call with **`API call failed after 3 retries: Connection error`** — the backgrounded process loses its model/network connection mid-call even while it appears alive (PID + elapsed + CPU%). Proven 2026-09-26 (the sbaco model-swap research dispatch: PID 9205 looked "running" at 2:29 elapsed / 9.6% CPU, but had already died at the model call; `hermes -z "say hi"` worked instantly, proving the provider was fine). **The working pattern for a long research/build job is FOREGROUND `hermes -z` with the three `inf` timeout env vars** (not backgrounding at all) — and **set the Bash tool's own `timeout` parameter above the default 120s (e.g. `timeout: 600000` for a 10-min connection)**. This is the single clean fix that stops the flail: the Bash tool's default 120s cap severs the `kubectl exec` pipe mid-job *independently* of the `inf` Hermes stream timeouts, so a long dispatch dies at 120s even with `inf` set. Passing `timeout: 600000` (the tool supports up to 10 min) keeps the pipe alive for the whole job. Foreground + `inf` vars + `timeout: 600000` = one clean shot. Then **read the result/log file directly when asked** — do NOT arm a `Monitor`/watcher on the result file and wait for an event (that method "DOES NOT WORK", [REDACTED] 2026-09-15: "i alwase have to prompt you to check").
- `kubectl cp <deploy-name>:…` fails with `pods <deploy-name> not found` — `kubectl cp` needs the actual pod name (`sudo-forge-<hash>`), not the Deployment name. Get it with `kubectl get pods -l app=<name>` first.
- **The host's `/opt/data` is NOT the pod's `/opt/data` (recurring path-collision).** Writing a brief to the *host's* `/opt/data/` does NOT make it visible inside forge's pod — the pod's `/opt/data` is a separate PVC (`sudo-forge-data`) mount. Get the file *into the pod* (e.g. `kubectl cp` to the actual pod) before `hermes -z "Read /opt/data/..."`, or forge reports "File not found." Same collision bit the psych-model brief (2026-09-15).
- **REVERSE collision: forge edits a "phantom" copy in its OWN pod when the target is on the HOST (2026-09-28).** When the work is a host-side repo (e.g. `/opt/0-0/sudo-fleet/` on the lima host), forge — running inside its pod — cannot see `/opt/0-0` at all, so it reports "this host has no `/opt/0-0`" and idly edits its *own* `/opt/data/gen1/` PVC, believing it "fixed" the file. That edit has **zero effect** on the real host repo. Tell: forge's report references paths like `/opt/data/gen1/` that don't exist on the host. **Fix: when the target is host-side, the dispatch must instruct forge to BRIDGE OUT to the host first (`docker run … nsenter -t 1 …`) and then edit `/opt/0-0/...`** — forge's pod filesystem is not the host filesystem, and it must be told so explicitly every dispatch, or it quietly edits its own PVC.
- **The `app=forge` label selector returns nothing** — the forge pod is `sudo-forge-<hash>` and its `app` label isn't `forge`. Find it with `kubectl get pods -l app=forge` falling back to `kubectl get pods | grep sudo-forge`, then use the real pod name.
- Tailscale SSH re-auth: `ssh who@fabean` periodically fails with a one-time `https://login.tailscale.com/a/<id>` link that needs the tailnet owner. Stop and hand it to the person.
- On fabean, docker IS the k3s runtime — manage pods with `kubectl`, not `docker`.

## Verification

- Host bridge works: the command returns real output and exit code 0 on success.
- Remote reachability: `ssh who@fabean 'hostname'` returns `fabean`.
- Quoting survived: the far side received the exact bytes intended (round-trip via base64 when uncertain).
- Change landed: a read-back on the far side shows the expected state, not just "command ran".
