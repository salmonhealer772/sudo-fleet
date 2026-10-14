# sudo-gws — fleet-shared Google Workspace MCP service

One long-lived container in the lima k3s cluster, fronted by a kube Service
speaking MCP over HTTP. OAuth ONCE as `operator@example.com`; the refresh
token is persisted to a PVC. Every agent in the fleet (Letta + Hermes) then
reads/writes the operator's Google Drive, Docs, and Sheets through that one
Service URL — without ever doing its own auth.

## What it is

- Server: `taylorwilsdon/google_workspace_mcp` (PyPI `workspace-mcp`), pinned
  to `2.1.0`. Runs the **streamable-http** transport (FastMCP), serving:
  - `/mcp` — the MCP endpoint (initialize / tools/list / tools/call)
  - `/health` — liveness/readiness probe
  - `/oauth2callback` — the OAuth consent callback
- Auth: **legacy OAuth 2.0 + single-user** (`--single-user`). One browser
  consent, one refresh token in `/data`, shared by every agent.
- Surfaces in scope: `--tools drive docs sheets` ONLY. Gmail / Calendar /
  Slides / Chat / Forms / Tasks / Contacts / Search / Apps Script are never
  registered.

## Deploy / teardown

```sh
# deploy (build image -> import -> secret -> PVC/Service/Deployment -> /health)
bash factories/sudo-gws/kube-scripts/up.sh

# one-time OAuth consent tunnel (Mac browser -> pod)
bash factories/sudo-gws/kube-scripts/oauth-tunnel.sh

# teardown (keeps the PVC + secret so the refresh token survives a redeploy)
bash factories/sudo-gws/kube-scripts/down.sh
```

## Addresses (deterministic)

| What | Address |
|---|---|
| MCP (ClusterIP, fleet `-mcp` convention) | `http://sudo-gws-mcp:8000/mcp` |
| MCP (host LAN, baked fleet address) | `http://192.0.2.15:27462/mcp` |
| Health | `http://192.0.2.15:27462/health` |
| OAuth redirect URI (register in Google) | `http://localhost:8000/oauth2callback` |

Port `27462 = 8000 + cksum("gws") % 22000` — the same per-agent `MCP_PORT`
derivation the fleet uses, so it cannot collide with any agent port and is
stable across redeploys.

## The operator's gated boundary

The GCP project + OAuth client are the operator's to create; no agent can mint
them. The exact click-path (project -> APIs -> consent screen -> OAuth client
-> redirect URI) is in [oauth-clickpath.md](oauth-clickpath.md). The operator
hands the client ID + secret back via the secrets store (`GWS_CLIENT_ID` /
`GWS_CLIENT_SECRET` env for `up.sh`); they are never committed to git and never
pasted in chat.

Until that client exists, everything else works: the pod runs, `/health` and
`/mcp` answer, and `tools/list` returns exactly the Drive/Docs/Sheets tools.
The first `tools/call` then returns the `ACTION REQUIRED: authorization URL`
message — that is the wired flow waiting for the operator's one consent.
