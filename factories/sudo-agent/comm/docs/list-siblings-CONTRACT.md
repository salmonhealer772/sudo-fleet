# list-siblings — tool contract

**The discovery tool for the mesh.** Before an agent can message or check on a sibling, it needs to know what siblings exist. `list-siblings` returns the live fleet roster — the agents and their `-mcp` / `-watch` services — by running `kubectl get services` on the HOST, reached through the agent's own mounted docker socket.

## Contract

- **Inputs:** none required. Optional `filter` (substring, e.g. `glm`) to narrow the roster.
- **Behavior:** reach the host through the already-mounted `/var/run/docker.sock` (the docker-socket + `nsenter` bridge every agent pod has), run `kubectl get services` host-side, and return the fleet's agent-facing services as a name → address map. Each entry gives the bare sibling name (deploy name minus leading `sudo-`), its `-mcp` host, and its `-watch` host, so an agent can go straight from "name" to "message it" or "check on it".
- **Output shape:** a table/map of `{sibling, mcp_host, watch_host}` — e.g. `fa-glm-l → sudo-fa-glm-l-mcp:8000 / sudo-fa-glm-l-watch:8000`.
- **Optional `filter`:** substring match against the bare name (same grep-style semantics as `message-agent`): unique match → show one entry; multiple → show all; none → say so clearly.

## How it reaches the host (the docker socket, NOT a directory service)

Every agent pod — Letta planner AND Hermes engineer — already mounts the host's docker socket at `/var/run/docker.sock`. So `list-siblings` does NOT need kubectl/kubeconfig inside the pod, and does NOT need any new fleet component. It reaches the host the same way psnvc always has:

```
docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest sh -c \
  "nsenter -t 1 -m -u -i -n -p -- env KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get services -n default"
```

- The `nsenter -t 1` jumps into the host PID 1 (real host, Ubuntu 26.04, `/etc/rancher/k3s/k3s.yaml` present).
- Hermes engineers run as uid 0 (privileged), so they can `nsenter` directly if simpler; Letta planners are uid 1000 non-root but `privileged:true`, so they use the `docker run --privileged ...` bridge above (the same one psnvc uses). The tool should ship the docker-socket bridge form so it works identically on both factory kinds.
- Filter the output to the `-mcp` / `-watch` / `-redis` services only; collapse each `sudo-<name>-mcp` / `sudo-<name>-watch` pair into one `{sibling, mcp_host, watch_host}` row.

## Naming note (why "sibling" = bare name)

The deployments are `sudo-<bare-name>`; a bare name is the deployment name minus ONE leading `sudo-`. Some bare names legitimately start with `sudo-` (the maintainer pair: bare `sudo-agent-maintainer-h` → deploy `sudo-sudo-agent-maintainer-h`), so do NOT blindly strip a leading `sudo-`; map service → bare name by the known `-mcp`/`-watch` suffix, not by prefix-stripping.

## Security note (flag, don't ignore)

The docker socket on a `privileged` + `hostNetwork` pod is host-root-equivalent — any code that can run docker there can run arbitrary host commands. That is already true for message-agent and every sidecar; `list-siblings` adds no new surface. It is read-only over `kubectl get services`, but the reach it uses is the same powerful bridge. No new key is needed for a read of the service list.

## Backend

Undecided (operator: "shit idk") — shell script vs. Letta mod tool. forge decides during build; this file pins the contract + the host-reach mechanism (docker socket bridge) explicitly.
