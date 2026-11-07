# sudo-mail-mcp — IMAP/SMTP email MCP server (reuses ortie OAuth tokens)

Fleet-shared email MCP server for Mercury (and any agent wired to it). Reads and
sends mail over **IMAP/SMTP with XOAUTH2**, reusing the operator's **existing
ortie OAuth refresh tokens** — so **no new OAuth consent** is required. Never
himalaya, never Gmail REST / MS Graph (those need new scopes).

## Why this over Gmail-REST / MS-Graph
The prior `sudo-gmail-mcp` (Gmail REST) and `sudo-msgraph-mcp` (MS Graph) servers
need OAuth consent for REST/Graph scopes the operator has NOT granted. The ortie
tokens are scoped to IMAP (`https://mail.google.com/`, `IMAP.AccessAsUser.All`)
+ SMTP (`SMTP.Send`) — exactly what IMAP/SMTP needs. This server consumes those
tokens directly.

## Server
Vendored from `codefuturist/email-mcp` v0.6.0 (commit
`7d31cd5eac8788bd69237c18e3ee1e1fe2816ab7`) with ONE patch: `client_secret` made
optional (the Microsoft Thunderbird public client has no secret). 52 tools over
Streamable HTTP at path `/mcp`.

Accounts (name → address → provider):
- aidan           → aidanmcohen@gmail.com      → google
- aidan77223      → aidan77223@gmail.com       → google
- aidansteam77223 → aidansteam77223@gmail.com  → google
- sbaco           → aidan@sbadventureco.com    → google
- neu             → cohen.aid@northeastern.edu → microsoft

## Deploy
```bash
sudo bash kube-scripts/up.sh
```
The deploy pulls the ortie refresh tokens off the Mac over SSH, generates
`config.toml`, stores it in the k8s Secret `sudo-mail-mcp-config` (never in git),
and builds/imports the image. Override with `MAIL_MCP_CONFIG_FILE` /
`MAIL_MCP_TOKEN_DIR`.

- ClusterIP: `http://sudo-mail-mcp:8000/mcp`
- host LAN:  `http://192.168.5.15:29543/mcp`

Teardown: `sudo bash kube-scripts/down.sh` (keeps PVC + secret).

## Tool surface (prefix mcp__mail__*)
Read: list_accounts, list_mailboxes, list_emails, get_email, get_emails,
search_emails, get_thread, get_email_status, find_email_folder.
Write: send_email, reply_email, forward_email, save_draft, send_draft,
mark_email, move_email, delete_email.
Every tool takes `account` = the account name above.

## Security
The refresh tokens live only in the k8s Secret (not committed). The endpoint is
on the internal LAN (192.168.5.15) + Tailscale, matching the fleet's other MCP
services. Email is only ever sent between the operator's own 5 accounts.
