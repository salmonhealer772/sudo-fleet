#!/usr/bin/env python3
"""mcp-call.py — call a tool on a sudo-agent's in-pod MCP server (streamable HTTP).

Stdlib only. Proves the MCP door answers WITHOUT needing an agent identity or a
cluster-side client library, and without touching the pod's filesystem.

The sudo-agent MCP server is FastMCP over streamable-http at `POST /mcp`:
  1. `initialize`            -> the reply carries the `mcp-session-id` header
  2. `notifications/initialized`
  3. `tools/call`

Usage:
  python3 mcp-call.py --url http://<clusterIP>:8000/mcp --list
  python3 mcp-call.py --url ... --tool hermes_prompt --args '{"prompt":"...","mode":"inbox"}'

Prints the decoded JSON-RPC result. Exits non-zero when the door does not answer,
so it is usable as a check in a shell `&&` chain.
"""
import argparse
import json
import sys
import urllib.error
import urllib.request

PROTO = "2025-06-18"


def _post(url, payload, session=None, timeout=60):
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    if session:
        headers["mcp-session-id"] = session
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, dict(r.headers), r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers or {}), e.read().decode()


def _decode(body):
    """A streamable-http reply is either bare JSON or an SSE stream of `data:` lines."""
    if not body:
        return None
    s = body.lstrip()
    if s.startswith("{") or s.startswith("["):
        return json.loads(s)
    chunks = []
    for line in body.splitlines():
        if line.startswith("data:"):
            chunks.append(line[5:].strip())
    if not chunks:
        return None
    return json.loads("\n".join(chunks))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True, help="e.g. http://10.43.x.y:8000/mcp")
    ap.add_argument("--list", action="store_true", help="tools/list instead of a call")
    ap.add_argument("--tool")
    ap.add_argument("--args", default="{}", help="JSON object of tool arguments")
    ap.add_argument("--timeout", type=float, default=120.0)
    a = ap.parse_args()

    st, hdr, body = _post(a.url, {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": PROTO, "capabilities": {},
                   "clientInfo": {"name": "sudo-fleet-probe", "version": "1"}},
    })
    session = hdr.get("mcp-session-id") or hdr.get("Mcp-Session-Id")
    print("initialize: HTTP %s  session=%s" % (st, session))
    dec = _decode(body)
    if dec:
        print("  server:", json.dumps((dec.get("result") or {}).get("serverInfo", dec))[:300])
    if not session:
        print("FAIL: no mcp-session-id header — the MCP door did not complete a handshake")
        return 2

    _post(a.url, {"jsonrpc": "2.0", "method": "notifications/initialized"}, session=session)

    if a.list:
        st, _, body = _post(a.url, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                            session=session)
        dec = _decode(body)
        names = [t["name"] for t in (dec.get("result") or {}).get("tools", [])]
        print("tools/list: HTTP %s  %d tools" % (st, len(names)))
        print("  " + ", ".join(names))
        return 0 if names else 1

    if not a.tool:
        print("FAIL: pass --list or --tool")
        return 2

    st, _, body = _post(a.url, {
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": a.tool, "arguments": json.loads(a.args)},
    }, session=session, timeout=a.timeout)
    dec = _decode(body) or {}
    if "error" in dec:
        print("tools/call: HTTP %s  JSONRPC ERROR %s" % (st, json.dumps(dec["error"])[:400]))
        return 1
    res = dec.get("result") or {}
    print("tools/call %s: HTTP %s" % (a.tool, st))
    for c in res.get("content") or []:
        if c.get("type") == "text":
            print("---- tool reply ----")
            print(c.get("text"))
            print("--------------------")
    if res.get("isError"):
        print("FAIL: tool reported isError")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
