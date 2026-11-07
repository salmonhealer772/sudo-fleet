#!/usr/bin/env python3
"""sudo-gmail-mcp OAuth consent helper — run ONCE PER ACCOUNT on the operator's Mac.

Adapted from sudo-gws/oauth-consent.py. Same installed-app (loopback) OAuth
pattern, but targets the gmail instance (port 24659) and lets you consent a
specific Google account via --account (so the other 3 accounts can be added
against the SAME fleet OAuth client, one at a time).

Run:  python3 consent.py --account aidan77223@gmail.com
"""
import argparse
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

POD_HOST = "192.168.5.15"   # lima k3s host LAN IP (the pod is hostNetwork)
POD_PORT = 24659            # sudo-gmail-mcp port (8000 + cksum("gmail") % 22000)
REDIRECT_HOST = "127.0.0.1"
REDIRECT_PORT = 8747        # loopback port on THIS Mac (must match the GCP URI)
MCP_PATH = "/mcp"

REDIRECT_URI = f"http://{REDIRECT_HOST}:{REDIRECT_PORT}/oauth2callback"

_captured = {}


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):
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

    def log_message(self, *_):
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
    ap = argparse.ArgumentParser(description="sudo-gmail-mcp OAuth consent helper")
    ap.add_argument("--account", required=True,
                    help="Google account to consent (e.g. aidan77223@gmail.com)")
    args = ap.parse_args()

    account = args.account
    print(f"sudo-gmail-mcp OAuth consent helper")
    print(f"  account:  {account}")
    print(f"  pod:      http://{POD_HOST}:{POD_PORT}")
    print(f"  redirect: {REDIRECT_URI}")
    print()

    headers, _ = _rpc({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "sudo-gmail-consent", "version": "1"},
        },
    })
    sid = headers.get("Mcp-Session-Id") or headers.get("mcp-session-id")
    if not sid:
        print("ERROR: pod did not return an MCP session id.")
        return 1
    _post({"jsonrpc": "2.0", "method": "notifications/initialized"}, session=sid)

    _, msg = _rpc({
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {
            "name": "start_google_auth",
            "arguments": {"service_name": "Gmail", "user_google_email": account},
        },
    }, session=sid)

    text = _extract_text(msg)
    m = re.search(r"Authorization URL:\s*(https?://\S+)", text)
    if not m:
        print("The pod did not return an authorization URL. Its reply was:")
        print(text)
        return 1

    auth_url = m.group(1)
    print(f"Opening the authorization link in your browser:\n  {auth_url}\n")

    try:
        server = HTTPServer((REDIRECT_HOST, REDIRECT_PORT), _Handler)
    except OSError as e:
        print(f"ERROR: could not bind {REDIRECT_URI}: {e}")
        return 1

    try:
        webbrowser.open(auth_url)
    except Exception as e:
        print(f"(could not auto-open the browser: {e})")
        print("Copy the link above into your browser and open it manually.")

    print(f"Waiting for Google to redirect to {REDIRECT_URI} ...")
    print(f"In the browser: sign in as {account} and click Allow.\n")
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
