#!/usr/bin/env python3
"""
sudo-gws OAuth consent helper — run ONCE on the operator's Mac.

This is the classic installed-app (loopback) OAuth pattern, with one twist:
the token EXCHANGE happens in the pod (which holds the client secret + the PKCE
verifier), so no client secret ever lands on the Mac and no tunnel is needed.

What this script does:

  1. Asks the pod to start the OAuth flow (MCP `start_google_auth`) and reads
     the authorization URL + state back out of the reply.
  2. Opens that URL in the default browser (Brave) — that is the ONE link the
     operator clicks "Allow" on.
  3. Binds a loopback listener on http://127.0.0.1:8787 (the registered GCP
     redirect URI) and waits for Google's redirect.
  4. Forwards the `code` + `state` from the redirect to the pod's
     /oauth2callback route.
  5. The pod exchanges the code and stores the refresh token on its PVC.

Requirements on the Mac: python3 (standard library only). No pip, no tunnel,
no client secret, no log scraping.

Run:  python3 oauth-consent.py
"""
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

# ── Config ───────────────────────────────────────────────────────────────────
POD_HOST = "192.168.5.15"   # lima k3s host LAN IP (the pod is hostNetwork)
POD_PORT = 27462            # sudo-gws MCP port (8000 + cksum("gws") % 22000)
REDIRECT_HOST = "127.0.0.1"
REDIRECT_PORT = 8787        # loopback port on THIS Mac (must match the GCP URI)
MCP_PATH = "/mcp"

REDIRECT_URI = f"http://{REDIRECT_HOST}:{REDIRECT_PORT}/oauth2callback"

_captured = {}


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 (http.server API)
        _captured["query"] = urllib.parse.urlparse(self.path).query
        body = (
            b"<html><body style='font-family: -apple-system, sans-serif; "
            b"text-align:center; padding-top:60px;'>"
            b"<h3>Authorization received.</h3>"
            b"<p>You can close this tab and return to the terminal.</p>"
            b"</body></html>"
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):  # silence request logging
        pass


def _post(payload, session=None):
    req = urllib.request.Request(
        f"http://{POD_HOST}:{POD_PORT}{MCP_PATH}",
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
        method="POST",
    )
    if session:
        req.add_header("Mcp-Session-Id", session)
    with urllib.request.urlopen(req, timeout=30) as r:
        return dict(r.headers), r.read().decode()


def _sse_messages(body):
    data = ""
    for line in body.splitlines():
        if line.startswith("data: "):
            data += line[len("data: "):]
        elif line == "" and data:
            try:
                yield json.loads(data)
            except json.JSONDecodeError:
                pass
            data = ""


def _rpc(payload, session=None):
    headers, body = _post(payload, session)
    msgs = list(_sse_messages(body))
    if not msgs:
        raise RuntimeError(f"empty MCP response from pod: {body[:200]!r}")
    msg = msgs[-1]
    if "error" in msg:
        raise RuntimeError(f"MCP error from pod: {msg['error']}")
    return headers, msg


def _extract_text(msg):
    text = ""
    result = msg.get("result", {})
    for c in result.get("content", []):
        if isinstance(c, dict) and c.get("type") == "text":
            text += c.get("text", "")
    return text or json.dumps(result)


def main():
    print(f"sudo-gws OAuth consent helper")
    print(f"  pod:      http://{POD_HOST}:{POD_PORT}")
    print(f"  redirect: {REDIRECT_URI}")
    print()

    # 1. MCP handshake with the pod.
    print("Asking the pod to start the OAuth flow ...")
    headers, _ = _rpc({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "sudo-gws-consent", "version": "1"},
        },
    })
    sid = headers.get("Mcp-Session-Id") or headers.get("mcp-session-id")
    if not sid:
        print("ERROR: pod did not return an MCP session id.")
        return 1
    _post({"jsonrpc": "2.0", "method": "notifications/initialized"}, session=sid)

    # 2. Trigger the auth flow and read the authorization URL + state back.
    _, msg = _rpc({
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {
            "name": "start_google_auth",
            "arguments": {"service_name": "Google Workspace"},
        },
    }, session=sid)

    text = _extract_text(msg)
    m = re.search(r"Authorization URL:\s*(https?://\S+)", text)
    if not m:
        print("The pod did not return an authorization URL. Its reply was:")
        print(text)
        print()
        print("This usually means the OAuth client is not configured on the pod.")
        print("Create the GCP client (see factories/sudo-gws/oauth-clickpath.md),")
        print("hand the client ID + secret to the secrets store, re-run up.sh,")
        print("then run this helper again.")
        return 1

    auth_url = m.group(1)
    print(f"Opening the authorization link in your browser:\n  {auth_url}\n")

    # 3. Bind the loopback listener BEFORE opening the browser (the socket is
    #    listening immediately, so the redirect cannot race past us).
    try:
        server = HTTPServer((REDIRECT_HOST, REDIRECT_PORT), _Handler)
    except OSError as e:
        print(f"ERROR: could not bind {REDIRECT_URI}: {e}")
        print("Close anything else using that port and retry.")
        return 1

    # 4. Open the browser — this is the link the operator clicks "Allow" on.
    try:
        webbrowser.open(auth_url)
    except Exception as e:  # noqa: BLE001
        print(f"(could not auto-open the browser: {e})")
        print("Copy the link above into Brave and open it manually.")

    # 5. Wait for Google's loopback redirect.
    print(f"Waiting for Google to redirect to {REDIRECT_URI} ...")
    print("In the browser: pick aidanmcohen@gmail.com and click Allow.\n")
    server.handle_request()

    query = _captured.get("query", "")
    params = urllib.parse.parse_qs(query)
    code = (params.get("code") or [""])[0]
    state = (params.get("state") or [""])[0]
    error = (params.get("error") or [""])[0]

    if error:
        print(f"Google returned an error: {error}")
        return 1
    if not code:
        print("No authorization code in the redirect. Please re-run.")
        return 1

    # 6. Forward code + state to the pod's /oauth2callback. The pod holds the
    #    client secret + PKCE verifier and does the exchange itself.
    print("Forwarding the authorization code to the pod ...")
    qs = urllib.parse.urlencode({"code": code, "state": state})
    cb_url = f"http://{POD_HOST}:{POD_PORT}/oauth2callback?{qs}"
    try:
        with urllib.request.urlopen(cb_url, timeout=60) as r:
            cb_body = r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        cb_body = e.read().decode(errors="replace")
    except urllib.error.URLError as e:
        print(f"Could not reach the pod callback: {e}")
        return 1

    if "Authentication Successful" in cb_body:
        email = re.search(r"authenticated as <span[^>]*>([^<]+)</span>", cb_body)
        print("DONE — the refresh token is now stored on the pod.")
        if email:
            print(f"  authenticated as: {email.group(1)}")
        return 0

    print("The pod reported an error during the token exchange:")
    err = re.search(r"<p>(.*?)</p>", cb_body, re.S)
    print(err.group(1)[:500] if err else cb_body[:500])
    return 1


if __name__ == "__main__":
    sys.exit(main())
