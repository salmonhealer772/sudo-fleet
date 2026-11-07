# sudo-gmail-mcp — fleet-shared Gmail MCP service (Gmail REST API)

One long-lived container in the lima k3s cluster, fronted by a kube Service
speaking MCP over HTTP. Same `workspace-mcp` image as `sudo-gws`, but registers
ONLY the Gmail surface (`--tools gmail`) — the Gmail REST API, which fixes the
IMAP pain (in-place draft edit, draft-send, no double-sends, stable message IDs,
reply-vs-new threading, scheduled send).

## What it is

- Server: `taylorwilsdon/google_workspace_mcp` (PyPI `workspace-mcp`), pinned
  to `2.1.0`, `--transport streamable-http` (FastMCP).
- Auth: legacy OAuth 2.0 + single-user, but **multi-account**: the credential
  dir (`/data`) holds one `<email>.json` per consented account, and each tool's
  `user_google_email` parameter selects the account.
- Surfaces in scope: Gmail only — search / read / get content / attachments /
  send / draft / threads / labels / filters / modify labels.

## Accounts

| address | status |
|---|---|
| aidanmcohen@gmail.com | default (`USER_GOOGLE_EMAIL`); needs gmail-scope consent |
| aidan77223@gmail.com | needs consent |
| aidansteam77223@gmail.com | needs consent |
| aidan@sbadventureco.com | needs consent |

## Deploy / consent / teardown

```sh
bash factories/sudo-gmail-mcp/kube-scripts/up.sh

# one-time consent PER ACCOUNT (run on the operator's Mac)
python3 factories/sudo-gmail-mcp/kube-scripts/consent.py --account aidanmcohen@gmail.com
python3 factories/sudo-gmail-mcp/kube-scripts/consent.py --account aidan77223@gmail.com
# ...

bash factories/sudo-gmail-mcp/kube-scripts/down.sh   # keeps PVC + shared secret
```

## Addresses (deterministic)

| What | Address |
|---|---|
| MCP (ClusterIP) | `http://sudo-gmail-mcp:8000/mcp` |
| MCP (host LAN) | `http://192.168.5.15:24659/mcp` |
| Health | `http://192.168.5.15:24659/health` |
| OAuth redirect URI | `http://127.0.0.1:8747/oauth2callback` |

Port `24659 = 8000 + cksum("gmail") % 22000`.
