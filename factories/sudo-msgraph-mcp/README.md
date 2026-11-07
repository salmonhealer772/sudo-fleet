# sudo-msgraph-mcp — fleet-shared Microsoft Graph MCP service (Outlook Mail)

One long-lived container in the lima k3s cluster, fronted by a kube Service
speaking MCP over HTTP. Wraps `elyxlz/microsoft-mcp` (a FastMCP Microsoft Graph
server) behind streamable-http, matching the fleet's `mcp_servers.<name>.url`
wiring.

## Why not the official Microsoft MCP Server for Enterprise

The official one is tenant-provisioned and requires `Application Administrator`
consent in Entra ID (`Grant-EntraBetaMCPServerPermission`). The operator is a
student in the Northeastern tenant, not an admin, so that path is not
deployable here. A delegated-OAuth community server using the device-code flow
is the cleanly-deployable path for one user's own mailbox.

## What it is

- Server: `elyxlz/microsoft-mcp` (FastMCP), vendored via `pip install git+…`.
- Transport: streamable-http, custom `server_http.py` entrypoint (upstream runs
  stdio only).
- Auth: device-code flow (`msal.PublicClientApplication`). No redirect URI to
  register, no client secret on the pod. Token cache persists via `HOME=/data`.
- Mail tools: `list_emails`, `get_email`, `search_emails`, `create_email_draft`,
  `reply_to_email`, `reply_all_email`, `send_email`, `update_email`,
  `move_email`, `delete_email`, `get_attachment`, plus calendar/contacts/files.

## Account

| address | tenant | status |
|---|---|---|
| cohen.aid@northeastern.edu | a8eec281-aaa3-4dae-ac9b-9a398b9215e7 | needs device-code consent |

## OAuth client (operator-gated, required)

The device-code client MUST be an Entra ID app registration with:

- Delegated API permissions: `Mail.ReadWrite`, `Mail.Send`, `User.Read`
- Authentication → **Allow public client flows** = Yes
- Supported account types: the Northeastern tenant (single-tenant is fine)

The Thunderbird IMAP client (`9e5f94bc-e8a4-4e73-b8be-63364c29d753`) only grants
`IMAP.AccessAsUser.All` / `SMTP.Send` / `EWS.AccessAsUser.All` — it does NOT
grant Graph `Mail.*` scopes and cannot be reused.

## Deploy / consent / teardown

```sh
# deploy (set the real app id once it exists)
MSGRAPH_CLIENT_ID=<entra-app-id> bash factories/sudo-msgraph-mcp/kube-scripts/up.sh

# consent (device code) — via the agent, or by calling the authenticate_account tool:
#   1. authenticate_account  -> returns a verification URL + code
#   2. operator visits microsoft.com/devicelogin, enters the code, signs in as
#      cohen.aid@northeastern.edu, approves
#   3. complete_authentication -> finishes the token exchange

bash factories/sudo-msgraph-mcp/kube-scripts/down.sh   # keeps PVC + secret
```

## Addresses (deterministic)

| What | Address |
|---|---|
| MCP (ClusterIP) | `http://sudo-msgraph-mcp:8000/mcp` |
| MCP (host LAN) | `http://192.168.5.15:12420/mcp` |
| Port | `12420 = 8000 + cksum("msgraph") % 22000` |
