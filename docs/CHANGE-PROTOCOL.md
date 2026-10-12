# Change protocol — mandatory post-change verification

Run this after any **complex** change. A complex change is one that touches more
than one moving part: a service plus its datastore, a solver plus its adapter, an
agent plus its harness — anything with a live runtime + a repo + a config that
can silently diverge. A single-line change to a stateless, single-owner service
does not need the full protocol.

The protocol proves four things, in order: the thing is actually serving
(RUNTIME), the live config matches the repo (CONFIG), something is actually
guarding it (AUTH), and the set of paths into it is known and accounted for
(EXPOSURE). "Pod Running + 1/1" is evidence for none of them.

## Why this exists

2026-10-11: the Paperclip deployment had accumulated three separate drifts that
no readiness probe could see:

- a live container whose startup `sed`-patches a built `dist/config.js` to lower
  the heartbeat floor (10s -> 1s) — lost on any redeploy that does not re-run the
  patch;
- a bootstrap invite already consumed, so the unattended bootstrap path could no
  longer mint the instance admin;
- an nginx basic-auth `htpasswd` file that is empty, so the advertised auth layer
  was effectively off while the deployment still claimed "private".

Each of these is a *difference between the live system and its intended state*,
not a crash. They accumulate because nothing re-checks the intended state after
deploy. This protocol is that re-check.

## Operating rules

1. **Read-only.** The protocol observes and records; it never restarts, redeploys,
   patches, or mutates the target. Remediation is a separate, explicit follow-up
   (an issue or a KNOWN-ISSUES entry), never a side effect of verification.
2. **One verifiable number per check.** Capture each value in the foreground and
   write it to a file. No "12 hits / the other scan said 0". If two readings
   disagree, re-run once, fresh, and record the single confirmed value.
3. **Findings land in the register.** Append to `docs/KNOWN-ISSUES.md` as a dated
   section, using the existing shape (severity / finding / evidence / unresolved).
   Do not invent a parallel format.
4. **Tool-neutral.** The four checks are stated for any deployment; the concrete
   commands below are the worked example for this repo's stack (k3s on the host,
   kubectl against `/etc/rancher/k3s/k3s.yaml`, pods reached via `kubectl exec`).

## The four checks

### 1. RUNTIME — is it serving, not just Running?

What to establish:

- the process is actually alive inside the container, not just the container
  being scheduled;
- the readiness/liveness gates are really passing (read their last result, do not
  assume);
- a health endpoint returns 2xx from the pod's own loopback;
- the **running artifact's version/commit** is fetched from the live process —
  never inferred from the image tag;
- restart count is 0 (a restarted pod may be crash-looping through a probe).

Failure mode to name in the report: *"pod Running + 1/1" is NOT evidence of a
serving service.*

Our stack (k3s, target `<ns>/<name>`):

```bash
# desired vs ready replicas
kubectl -n <ns> get deploy <name> -o jsonpath='{.spec.replicas}/{.status.readyReplicas}'
# restart count of the live pod
kubectl -n <ns> get pod -l app=<name> -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}'
# health from the pod's own loopback (bypasses the network path)
kubectl -n <ns> exec deploy/<name> -- curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:<port>/api/health
# running commit — read it from the live process, not the image tag
kubectl -n <ns> exec deploy/<name> -- curl -sS http://127.0.0.1:<port>/api/health   # -> "commit":"..."
```

### 2. CONFIG — does the LIVE config match the REPO?

What to establish:

- the deployed manifest equals its committed source (under `deployments/`, or
  wherever the manifest is authored — note when it is authored as a heredoc
  inside a script rather than a file);
- no in-container mutation at startup (`sed -i`, `cp`, `echo >`, entrypoint patch)
  — any such mutation is **DRIFT**: it is lost on the next redeploy and must be
  re-applied or moved into the image;
- no secret/credential whose live value disagrees with intent.

Flag any in-container mutation explicitly as a DRIFT item. The question is not
"does it work now" but "does the next redeploy reproduce it".

Our stack:

```bash
# deployed spec vs committed manifest
kubectl -n <ns> get deploy <name> -o yaml > /tmp/deployed.yaml
git show origin/main:<manifest-path> > /tmp/committed.yaml
diff -u /tmp/committed.yaml /tmp/deployed.yaml     # empty = clean
# in-container mutation: diff a built artifact against what the image ships
kubectl -n <ns> exec deploy/<name> -- grep -n "Math.max" /app/server/dist/config.js
# credential-shaped files that are empty
kubectl -n <ns> exec deploy/<name> -- sh -c 'find / -name htpasswd -exec wc -c {} \;'
```

### 3. AUTH — what guards it RIGHT NOW?

For each auth layer the service claims (its own auth mode, plus any proxy in
front), prove it with an **expected-FAIL**: an unauthenticated request must return
401/403, not 200. An empty htpasswd, a consumed bootstrap invite, or a "private"
exposure claim with no challenge is a **FAIL**, not a pass.

Our stack (NodePort at `<node>:<nodePort>`):

```bash
# the open surface (health is allowed to be open; the API is not)
curl -sS -o /dev/null -w '%{http_code}' http://<node>:<nodePort>/api/health          # expect 200
curl -sS -o /dev/null -w '%{http_code}' http://<node>:<nodePort>/api/companies      # expect 401/403
curl -sS -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer bogus' \
  http://<node>:<nodePort>/api/companies                                            # expect 401
# the auth file behind any proxy is non-empty
kubectl -n <ns> exec deploy/<name> -- wc -c /etc/nginx/.htpasswd                    # 0 bytes = FAIL
```

### 4. EXPOSURE — every path from the internet in

Enumerate every route from the public internet to the service and mark each link
authenticated or open. Anything you cannot prove is closed is reported **OPEN**.
State the exact upstream host/port chain.

Our stack:

```bash
# service types + port mappings
kubectl -n <ns> get svc -o wide
# what is actually listening on the node for the NodePort
ss -tlnp | grep :<nodePort>
# tunnels / reverse proxies that could carry the service
pgrep -af frpc; pgrep -af frps
# the chain, top to bottom:
#   internet -> <edge/tunnel> -> node:<nodePort> -> svc:<port> -> pod:3100
```

## Worked example — Paperclip (run 2026-10-11)

Target: `ghcr.io/paperclipai/paperclip:latest` in ns `paperclip`. Two candidate
locations: the tailnet box `fabean` (`who@100.117.138.128`) and the local k3s.
fabean was **unreachable** this run (finding PC-1), so the run below is against
the local k3s deployment; the fabean side is recorded as unverified/open.

**RUNTIME** — PASS (with one warning).

```
/api/health -> 200 {"status":"ok","deploymentMode":"authenticated",
  "deploymentExposure":"private","commit":"467125fafb47a8520856504fecc48d6e32055db1",
  "bootstrapStatus":"ready","bootstrapInviteActive":false,
  "databaseBackup":{"enabled":true,"status":"warning",...}}
deploy ready 1/1; pod restartCount 0; imageID sha256:de762433...
```

Running commit fetched from the live process: `467125fafb...` (not the image tag
`...:latest`). Warning: `database_backup_missing`.

**CONFIG** — DRIFT NOTED.

- The manifest is authored as a heredoc inside `bin/paperclip-up.sh` (there is no
  `deployments/paperclip*.yaml`), so "live vs repo" is a diff against
  `git show origin/main:bin/paperclip-up.sh`; the deployed `last-applied` matches
  the script.
- Heartbeat floor: `/app/server/dist/config.js:244` reads
  `Math.max(10000, ...)` — the 1s-heartbeat `sed` patch is **not** present on the
  local pod. If a 1s floor is required, it is currently unrepresented in the
  image and the repo; a redeploy resets it to 10s. (The 1s patch is a fabean-side
  drift — unverifiable this run.)

**AUTH** — PASS on the local pod, UNVERIFIED on fabean.

```
curl /api/health                                  -> 200  (open, expected)
curl /api/companies (no auth)                     -> 403  (armed)
curl /api/companies (Authorization: Bearer bogus) -> 401  (armed)
```

`bootstrapStatus` is `ready` and `bootstrapInviteActive` is `false` — the invite
is already consumed; a re-`claim` would fail (the repo's `paperclip-up.sh`
already branches on this and signs in instead). No nginx/htpasswd exists anywhere
in the local image; the empty-`htpasswd` drift is on the fabean side and could
not be verified (fabean unreachable).

**EXPOSURE** — one OPEN NodePort; fabean chain UNVERIFIED.

```
svc/paperclip       ClusterIP 10.43.151.244:3100   (cluster-internal)
svc/paperclip-node  NodePort  3100:31310           (OPEN — no edge auth gate)
svc/paperclip-pg    ClusterIP 10.43.195.38:5432    (cluster-internal)
```

Chain: `internet -> (unknown) -> 192.0.2.15:31310 -> paperclip:3100`. The
NodePort has no TLS and no reverse-proxy auth in front of it; `/api/health` is
open, the API endpoints are guarded only by the app's own auth. No `frpc`/`frps`
tunnel was found on the local host. The fabean-side path
(`who@100.117.138.128`) could not be enumerated (connection timed out) and is
reported OPEN.

Findings PC-1..PC-6 are recorded in `docs/KNOWN-ISSUES.md` (2026-10-11 section).

## Automation

`bin/verify-change.sh` is the machine-runnable half of this protocol: the same
four checks, read-only, printing PASS/FAIL per check plus a final verdict and
exiting non-zero on any failure. This document is the normative spec; the script
must not drift from it.
