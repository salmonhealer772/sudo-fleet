#!/usr/bin/env python3
"""sudo-upwork-mcp OAuth consent helper — run ONCE on the operator's Mac.

Adapted from the fleet's sudo-gmail-mcp consent.py. Same loopback-redirect
pattern, but for Upwork's OAuth 2.1 (CIMD + PKCE):

  1. ask the pod for an authorization URL (GET /authorize)
  2. open it in the browser
  3. listen on 127.0.0.1:8747 for the redirect (matches the registered
     redirect_uri in mcp/upwork/oauth/client-metadata.json)
  4. capture the authorization code + state
  5. POST them back to the pod (POST /authorize/complete), which exchanges the
     code and stores the access + refresh tokens on its PVC

Run:  python3 consent.py
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

POD_HOST = "192.168.5.15"   # lima k3s host LAN IP (the pod is hostNetwork)
POD_PORT = 9232             # sudo-upwork-mcp port (8000 + cksum("upwork") % 22000)
REDIRECT_HOST = "127.0.0.1"
REDIRECT_PORT = 8747        # loopback port on THIS Mac (must match the metadata doc)
REDIRECT_URI = f"http://{REDIRECT_HOST}:{REDIRECT_PORT}/callback"

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


def _get_json(path):
    with urllib.request.urlopen(f"http://{POD_HOST}:{POD_PORT}{path}", timeout=30) as r:
        return json.loads(r.read().decode())


def _post_json(path, payload):
    req = urllib.request.Request(
        f"http://{POD_HOST}:{POD_PORT}{path}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, json.loads(r.read().decode() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode() or b"{}")


def main():
    print("sudo-upwork-mcp OAuth consent helper")
    print(f"  pod:      http://{POD_HOST}:{POD_PORT}")
    print(f"  redirect: {REDIRECT_URI}")
    print()

    try:
        auth = _get_json("/authorize")
    except urllib.error.URLError as e:
        print(f"Could not reach the pod: {e}")
        return 1

    if auth.get("authorized"):
        print("The pod is already authorized. Nothing to do.")
        return 0

    url = auth.get("authorization_url")
    state = auth.get("state")
    if not url:
        print("The pod did not return an authorization URL.")
        return 1

    print("Opening the Upwork authorization link in your browser:\n")
    print(f"  {url}\n")
    try:
        webbrowser.open(url)
    except Exception:
        print("(could not auto-open the browser — copy the link above manually)")

    print("In the browser: log in to Upwork and click Allow.")
    print(f"Waiting for Upwork to redirect to {REDIRECT_URI} ...\n")

    try:
        server = HTTPServer((REDIRECT_HOST, REDIRECT_PORT), _Handler)
    except OSError as e:
        print(f"ERROR: could not bind {REDIRECT_URI}: {e}")
        return 1

    server.handle_request()

    params = urllib.parse.parse_qs(_captured.get("query", ""))
    code = (params.get("code") or [""])[0]
    got_state = (params.get("state") or [""])[0]
    error = (params.get("error") or [""])[0]

    if error:
        print(f"Upwork returned an error: {error}")
        return 1
    if not code:
        print("No authorization code in the redirect. Please re-run.")
        return 1
    if got_state and got_state != state:
        print("State mismatch (possible CSRF). Aborting.")
        return 1

    print("Forwarding the authorization code to the pod ...")
    status, result = _post_json("/authorize/complete", {"code": code, "state": state})
    if status == 200 and result.get("authorized"):
        print("DONE — the Upwork access + refresh tokens are now stored on the pod.")
        return 0

    print(f"The pod reported an error during the token exchange (HTTP {status}):")
    print(result.get("error") or result)
    return 1


if __name__ == "__main__":
    sys.exit(main())
