# sudo-upwork-mcp — fleet-shared Upwork MCP gateway

One long-lived pod in the lima k3s cluster that fronts **Upwork's OFFICIAL MCP
server** (`https://mcp.upwork.com/mcp`) and re-exposes its tools to any fleet
agent as a streamable-HTTP MCP server — no per-agent auth, no per-agent tokens.

```
fleet agent ──MCP──▶ sudo-upwork-mcp:8000/mcp ──MCP + OAuth 2.1 Bearer──▶ mcp.upwork.com/mcp
```

The gateway holds **ONE OAuth token** (access + refresh), authorized **once** by
the operator, refreshes it automatically, and mirrors Upwork's real tools under
their exact Upwork tool names (`search_jobs`, `get_job_details`,
`submit_proposal`, `get_proposals`, `get_messages`, `send_message`, and any
other tools Upwork's MCP currently exposes). The token lives on the pod's PVC —
it is never written to git.

## Auth model

Upwork's MCP uses **OAuth 2.1 with Client ID Metadata Documents (CIMD)**:

- `client_id` = a public HTTPS URL serving this gateway's metadata document
  (`mcp/upwork/oauth/client-metadata.json`, served via jsDelivr). There is **no
  client secret** — `token_endpoint_auth_method = "none"`.
- Flow = `authorization_code` + **PKCE (S256)** + `refresh_token`.
- `redirect_uri` = `http://127.0.0.1:8747/callback` (loopback on the operator's
  Mac — a small helper captures the code and forwards it to the pod).

OAuth endpoints (from Upwork's AS metadata, stable):

| What | URL |
|---|---|
| authorization | `https://www.upwork.com/ab/account-security/oauth2/authorize` |
| token | `https://www.upwork.com/api/v3/oauth2/token` |
| revocation | `https://www.upwork.com/api/v3/oauth2/token/revoke` |

## Deploy

```sh
bash mcp/upwork/kube-scripts/up.sh
```

`up.sh` builds the image (`sudo-upwork-mcp:latest`), imports it into
k3s/containerd, applies the PVC/Service/Deployment, and waits for `/health`.

## One-time authorize (the operator does this ONCE, from his Mac)

1. Make sure the pod is up: `kubectl -n default rollout status deploy/sudo-upwork-mcp`
   and `curl http://192.168.5.15:9232/health`.

2. From his Mac, in the repo checkout, run the consent helper:

   ```sh
   python3 mcp/upwork/kube-scripts/consent.py
   ```

   The helper:
   - asks the pod for an authorization URL (`GET /authorize`),
   - opens it in the Mac's default browser,
   - listens on `http://127.0.0.1:8747/callback` for the redirect.

3. In the browser: **log in to Upwork** (Aidan's account), review the requested
   access, and click **Allow**.

4. Upwork redirects the browser to `http://127.0.0.1:8747/callback?code=…&state=…`.
   The helper captures the code, POSTs it to the pod (`POST /authorize/complete`),
   and the pod exchanges it for access + refresh tokens and stores them on the PVC.

5. The helper prints `DONE — the Upwork access + refresh tokens are now stored
   on the pod.` That's it — tokens now survive restarts and refresh automatically.

(Equivalent manual path if you don't want the helper: `curl http://192.168.5.15:9232/authorize`
to get the URL, open it, then capture the `code`+`state` from the redirect and
`curl -X POST http://192.168.5.15:9232/authorize/complete -H 'Content-Type: application/json' -d '{"code":"…","state":"…"}'`.)

## Verify

```sh
# 1. initialize
curl -sS -X POST http://sudo-upwork-mcp:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'

# 2. tools/list — returns Upwork's real tool list
curl -sS -X POST http://sudo-upwork-mcp:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# 3. search_jobs — returns real jobs (after authorize)
curl -sS -X POST http://sudo-upwork-mcp:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_jobs","arguments":{"query":"react"}}}'
```

The same endpoints are reachable from a pod as `http://sudo-upwork-mcp:8000/mcp`
(ClusterIP) or from the host LAN as `http://192.168.5.15:9232/mcp`.

## Addresses (deterministic)

| What | Address |
|---|---|
| MCP (ClusterIP) | `http://sudo-upwork-mcp:8000/mcp` |
| MCP (host LAN) | `http://192.168.5.15:9232/mcp` |
| Health | `http://192.168.5.15:9232/health` |
| Authorize | `http://192.168.5.15:9232/authorize` |
| OAuth redirect URI | `http://127.0.0.1:8747/callback` |

Port `9232 = 8000 + cksum("upwork") % 22000` (fleet convention).

## Fleet wiring

Add to any agent's MCP servers (see `toolbelt/mcp-config.json`):

```json
{"mcpServers":{"upwork":{"url":"http://sudo-upwork-mcp:8000/mcp","transport":"streamable-http"}}}
```

## Teardown

```sh
bash mcp/upwork/kube-scripts/down.sh          # keeps PVC (token)
bash mcp/upwork/kube-scripts/down.sh --purge  # also deletes PVC (re-authorize needed)
```
