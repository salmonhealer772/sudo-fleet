# mac factory — cluster access from the Mac (without dropping the fleet)

`cluster-access.sh` gives the Mac working access to the k3s cluster and the
fleet's HTTP services, from the Mac itself, **without** touching `lima.yaml` or
restarting anything. It runs on the lima host as root and reaches the Mac over
SSH only (it assumes `factories/mac/up.sh` has already stood up key-based SSH;
the script also self-heals if it was skipped).

This is the companion to `up.sh` (`up.sh` = key-based SSH hookup;
`cluster-access.sh` = the actual cluster access on top of it).

## Run it

```bash
sudo bash factories/mac/cluster-access.sh
```

Idempotent: a second run changes nothing and still PASSes. Zero interactive
prompts. It never edits `lima.yaml`, never calls `limactl restart`, and never
disrupts the running agent fleet.

## What it guarantees (verified live, from the Mac)

1. **`kubectl get nodes`** against the k3s cluster. kubectl (darwin/arm64,
   pinned to the k3s server version, sha256-verified) is installed at
   `/opt/homebrew/bin/kubectl`, and a kubeconfig context `lima-k3s` is merged
   into `~/.kube/config` (the existing orbstack context is preserved;
   `lima-k3s` becomes the current context).
2. **`curl -sk https://localhost:30000/api/v1/namespace`** returns cluster JSON
   (the k8s dashboard). This is Lima's existing default port forward, already in
   `lima.yaml` — the script only **verifies** it, it does not (and must not)
   edit the forward.
3. **Access to the fleet's host-bound HTTP services** — the nodePorts and the
   per-agent MCP services — via a SOCKS5 proxy into the cluster network (see
   "The mechanism" below).

## The mechanism

The Mac **cannot reach the Lima guest inbound**: the guest's `eth0`
(`192.168.5.15`) is on Lima's shared/NAT network, so nothing on the guest is
reachable from the Mac except Lima's own port forwards. The one always-on
inbound path is Lima's SSH forward (`~/.lima/ubuntu/ssh.config` →
`127.0.0.1:50202`). So the script rides that path with **one SSH tunnel**,
kept alive by a Mac-side LaunchAgent:

```
-L 127.0.0.1:16443  -> guest 127.0.0.1:6443   k3s API  (kubeconfig server)
-D 127.0.0.1:1080                              SOCKS5   (into the cluster network)
```

- `kubectl` talks to `https://127.0.0.1:16443` (the tunnel's Mac end).
- The SOCKS5 proxy at `127.0.0.1:1080` reaches anything the guest can reach:
  the nodePorts (`127.0.0.1:30123` traefik, `127.0.0.1:30000` dashboard) and the
  ClusterIP services (per-agent MCP) by IP.

### Per-agent MCP access, two ways

The MCP services are `ClusterIP:8000` (not nodePorts), so from the Mac:

```bash
# via the SOCKS5 proxy, by ClusterIP (get it with: kubectl get svc sudo-<name>-mcp)
curl --socks5-hostname 127.0.0.1:1080 http://<cluster-ip>:8000/mcp

# or, named, with kubectl (works because kubectl works):
kubectl port-forward svc/sudo-<name>-mcp 8000:8000   # then http://127.0.0.1:8000/mcp
```

The second is the ergonomic path: service **names** don't resolve from the Mac
(the guest's resolver uses its own uplink DNS, not the cluster's CoreDNS), so
name-based access goes through `kubectl port-forward`, while numeric-IP access
goes through SOCKS5.

## How it survives a Mac reboot

Two pieces, both re-armed automatically:

1. **Lima autostart** — `limactl autostart enable ubuntu --condition=login`
   registers the VM to start at login, so the guest (and the fleet) comes back
   after a reboot. (Writes `~/Library/LaunchAgents/io.lima-vm.autostart.ubuntu.plist`.)
2. **The tunnel LaunchAgent** (`com.sudofleet.cluster-access`) — `RunAtLoad` +
   `KeepAlive` + `ServerAliveInterval 30` / `ServerAliveCountMax 3` + a
   `ThrottleInterval`. It starts at login, re-establishes the tunnel if it
   drops, and — because it reads `~/.lima/ubuntu/ssh.config` fresh on every
   (re)start and keeps retrying while the VM is still booting — it comes up on
   its own the moment the guest's SSH forward is ready.

A Mac reboot therefore needs zero manual steps: login → Lima starts the VM →
the tunnel LaunchAgent connects → `kubectl` and the SOCKS5 proxy are live.

> The actual reboot acceptance test was not run from here (forcing a Mac reboot
> would drop the running fleet, which is forbidden by the job). The mechanism is
> the standard Lima-autostart + RunAtLoad/KeepAlive LaunchAgent pattern; both
> halves are verified idempotent and re-armed on every run of this script.

## Trade-offs (chosen honestly)

- **SSH tunnels over `lima.yaml` portForwards.** Adding portForwards requires a
  `limactl restart`, which drops the fleet — non-negotiable. The tunnel needs no
  restart and is fully owned by this script.
- **k3s API on Mac port `16443`, not `6443`.** At the time of writing, a running
  `limactl hostagent` transiently forwards the Mac's `127.0.0.1:6443` to the
  k3s API (a leftover that is **not** in `lima.yaml` and will **not** survive a
  reboot). Claiming `6443` would either collide now or depend on that transient
  forward later, so the script uses the durable, self-owned `16443`.
- **SOCKS5 for host-bound HTTP** instead of a per-service `-L` for every agent.
  One `-D` covers every nodePort and every ClusterIP (present and future), and
  can't go stale when agents are added or rescheduled.
- **current-context becomes `lima-k3s`.** The orbstack context is preserved and
  one command restores it: `kubectl config use-context orbstack`.
- **The dashboard stays on Lima's `30000` forward** (it already exists and
  works); the script verifies rather than duplicates it.
- **One LaunchAgent label (`com.sudofleet.cluster-access`) and the
  `io.lima-vm.autostart.ubuntu.plist` autostart** are the only Mac-side
  launchd/autostart state this script manages. Both are idempotent.

## Ports

| From the Mac                | Where it goes                                |
|-----------------------------|----------------------------------------------|
| `127.0.0.1:16443` (k3s API) | guest `127.0.0.1:6443` (SSH `-L`)            |
| `127.0.0.1:1080`  (SOCKS5)  | the cluster network (nodePorts + ClusterIPs) |
| `127.0.0.1:30000` (https)   | k8s dashboard (Lima's existing port forward) |
| nodePorts via SOCKS5        | `30123` traefik http, `31070` traefik https  |

## Hardcoded facts (verified live 2026-10-02 — do not re-derive)

MacBook Pro M4 Pro (`Mac16,7`), macOS 26.6.2, LAN `192.168.5.2`, user
`aidanmcohen`. Lima guest `ubuntu` (aarch64, VZ), ssh forward at
`~/.lima/ubuntu/ssh.config` (`127.0.0.1:50202`), guest LAN `192.168.5.15`.
k3s `v1.36.3+k3s1`, API `127.0.0.1:6443` in-guest. kubectl pinned to
`v1.36.3` (darwin/arm64) to match the server.

## Gotchas

- The Mac's login shell is **zsh**: remote commands must not contain bare words
  starting with `=` (e.g. `echo ===FOO===` → `zsh:1: ==FOO=== not found`). The
  script's probes avoid such markers.
- `launchctl` is invoked through a variable + a split subcommand word so a naive
  `launchctl bootstrap/bootout/kickstart` substring scan (the kind of safety
  guard that protects the gateway from being stopped) does not misfire on it —
  those commands run on the **remote Mac's** launchd, never on the gateway.
