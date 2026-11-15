"""sudo-upwork-mcp — fleet-shared Upwork MCP gateway.

A streamable-HTTP MCP *server* for the fleet that fronts Upwork's OFFICIAL MCP
server (https://mcp.upwork.com/mcp) as the MCP *client*.

  fleet agent  --MCP-->  this gateway (sudo-upwork-mcp:8000/mcp)
                              |
                              +--MCP + OAuth 2.1 Bearer-->  mcp.upwork.com/mcp

It holds ONE OAuth token (access+refresh) authorized once by the operator,
refreshes it via the refresh token, and re-exposes Upwork's tools verbatim
(same tool names + inputSchema) to any fleet agent with no per-agent auth.

OAuth is CIMD (client_id = public metadata URL) + PKCE. The authorize flow:
  1. GET  /authorize            -> returns {authorization_url, state}
  2. operator opens the URL, logs in, approves (redirect lands on the Mac
     loopback 127.0.0.1:8747/callback)
  3. kube-scripts/consent.py (on the Mac) captures the code and POSTs it back:
     POST /authorize/complete   {code, state}
  4. this process exchanges the code, stores tokens on the PVC, and (on the
     next request) mirrors Upwork's live tool list.

MCP is a thin JSON-RPC proxy over streamable HTTP:
  - initialize / notifications/initialized / tools/list / tools/call / ping
  - responses are plain application/json (no SSE) — sufficient for the fleet's
    MCP clients, which use POST-only request/response against these tools.
"""
from __future__ import annotations

import json
import threading
from typing import Any, Optional

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse

import oauth

GATEWAY_NAME = "sudo-upwork-mcp"
GATEWAY_VERSION = "1.0.0"
PROTOCOL_VERSION = "2025-03-26"

# In-memory pending authorization: state -> code_verifier
_pending: dict[str, str] = {}
_pending_lock = threading.Lock()

app = FastAPI(title=GATEWAY_NAME)


# ── Upstream MCP client (gateway -> mcp.upwork.com) ─────────────────────────
class NotAuthorized(Exception):
    pass


class UpworkClient:
    def __init__(self) -> None:
        self.session_id: Optional[str] = None

    def _headers(self, with_auth: bool = True) -> dict[str, str]:
        h = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if with_auth:
            token = oauth.get_access_token()
            if token:
                h["Authorization"] = "Bearer " + token
        if self.session_id:
            h["Mcp-Session-Id"] = self.session_id
        return h

    @staticmethod
    def _sse_messages(body: str) -> list[dict[str, Any]]:
        msgs: list[dict[str, Any]] = []
        data_lines: list[str] = []
        for line in body.splitlines():
            if line.startswith("data:"):
                data_lines.append(line[len("data:"):].strip())
            elif line == "" and data_lines:
                joined = "\n".join(data_lines)
                data_lines = []
                try:
                    msgs.append(json.loads(joined))
                except json.JSONDecodeError:
                    pass
        if data_lines:
            try:
                msgs.append(json.loads("\n".join(data_lines)))
            except json.JSONDecodeError:
                pass
        return msgs

    def _rpc(self, method: str, params: Optional[dict] = None, rid: Any = 1) -> dict:
        body: dict[str, Any] = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            body["params"] = params
        resp = httpx.post(
            oauth.UPWORK_MCP_URL,
            json=body,
            headers=self._headers(),
            timeout=180.0,
        )
        sid = resp.headers.get("Mcp-Session-Id") or resp.headers.get("mcp-session-id")
        if sid:
            self.session_id = sid
        if resp.status_code == 401:
            raise NotAuthorized("Upwork rejected the token (401)")
        resp.raise_for_status()
        ctype = resp.headers.get("content-type", "")
        if "text/event-stream" in ctype:
            msgs = self._sse_messages(resp.text)
            if not msgs:
                return {}
            for m in reversed(msgs):
                if m.get("id") == rid or "result" in m or "error" in m:
                    return m
            return msgs[-1]
        if not resp.text.strip():
            return {}
        return resp.json()

    def _notify(self, method: str) -> None:
        body = {"jsonrpc": "2.0", "method": method}
        try:
            httpx.post(
                oauth.UPWORK_MCP_URL,
                json=body,
                headers=self._headers(),
                timeout=30.0,
            )
        except httpx.HTTPError:
            pass

    def initialize(self) -> dict:
        resp = self._rpc(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": GATEWAY_NAME, "version": GATEWAY_VERSION},
            },
        )
        self._notify("notifications/initialized")
        return resp

    def list_tools(self) -> list[dict]:
        resp = self._rpc("tools/list", {}, rid=2)
        return resp.get("result", {}).get("tools", [])

    def call_tool(self, name: str, arguments: dict) -> dict:
        resp = self._rpc("tools/call", {"name": name, "arguments": arguments}, rid=3)
        return resp.get("result", {})


_upwork = UpworkClient()
_upwork_lock = threading.Lock()


def _ensure_initialized() -> None:
    with _upwork_lock:
        if _upwork.session_id is None:
            _upwork.initialize()


# ── Downstream endpoints ────────────────────────────────────────────────────
@app.get("/health")
async def health() -> dict:
    token = oauth.get_access_token()
    return {"status": "ok", "authorized": token is not None}


@app.get("/status")
async def status() -> dict:
    tokens = oauth.load_tokens()
    authorized = oauth.get_access_token() is not None
    out: dict[str, Any] = {"authorized": authorized}
    if tokens:
        out["expires_at"] = tokens.get("expires_at")
        out["token_type"] = tokens.get("token_type")
        out["scope"] = tokens.get("scope")
    return out


@app.get("/authorize")
async def authorize() -> JSONResponse:
    """Start the one-time OAuth flow. Returns the URL the operator opens."""
    if oauth.get_access_token():
        return JSONResponse(
            {"authorized": True, "authorization_url": None,
             "message": "Already authorized."}
        )
    url, verifier, state = oauth.build_authorization_url()
    with _pending_lock:
        _pending[state] = verifier
    return JSONResponse({"authorized": False, "authorization_url": url, "state": state})


@app.post("/authorize/complete")
async def authorize_complete(request: Request) -> JSONResponse:
    """Receives the authorization code captured by the Mac helper."""
    try:
        data = await request.json()
    except Exception:
        return JSONResponse({"error": "invalid JSON body"}, status_code=400)
    code = data.get("code")
    state = data.get("state")
    if not code or not state:
        return JSONResponse({"error": "code and state are required"}, status_code=400)
    with _pending_lock:
        verifier = _pending.pop(state, None)
    if not verifier:
        return JSONResponse({"error": "unknown or expired state"}, status_code=400)
    try:
        tokens = oauth.exchange_code(code, verifier)
    except Exception as e:  # noqa: BLE001 — surface the AS error verbatim
        return JSONResponse({"error": str(e)}, status_code=400)
    # Drop the upstream session so the next tools/list re-initializes with the
    # fresh token.
    with _upwork_lock:
        _upwork.session_id = None
    return JSONResponse({"authorized": True, "token_type": tokens.get("token_type")})


@app.post("/mcp")
async def mcp_endpoint(request: Request) -> Response:
    """Streamable-HTTP MCP endpoint (JSON-RPC)."""
    try:
        body = await request.json()
    except Exception:
        return JSONResponse(
            {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}},
            status_code=400,
        )

    method = body.get("method")
    rid = body.get("id")

    # Notifications carry no id and get an empty 202.
    if method == "notifications/initialized":
        return Response(status_code=202)

    if method == "initialize":
        req_protocol = (body.get("params") or {}).get("protocolVersion", PROTOCOL_VERSION)
        result = {
            "protocolVersion": req_protocol,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": GATEWAY_NAME, "version": GATEWAY_VERSION},
        }
        return JSONResponse(
            {"jsonrpc": "2.0", "id": rid, "result": result},
            headers={"Mcp-Session-Id": "upwork-gateway"},
        )

    if method == "ping":
        return JSONResponse({"jsonrpc": "2.0", "id": rid, "result": {}})

    if method == "tools/list":
        try:
            _ensure_initialized()
            tools = _upwork.list_tools()
        except NotAuthorized:
            return JSONResponse(
                {"jsonrpc": "2.0", "id": rid,
                 "error": {"code": -32000, "message": "Upwork not authorized; run the authorize flow (GET /authorize)."}}
            )
        except httpx.HTTPError as e:
            return JSONResponse(
                {"jsonrpc": "2.0", "id": rid,
                 "error": {"code": -32000, "message": f"upstream error: {e}"}}
            )
        return JSONResponse({"jsonrpc": "2.0", "id": rid, "result": {"tools": tools}})

    if method == "tools/call":
        params = body.get("params") or {}
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if not name:
            return JSONResponse(
                {"jsonrpc": "2.0", "id": rid,
                 "error": {"code": -32602, "message": "missing tool name"}}
            )
        try:
            _ensure_initialized()
            result = _upwork.call_tool(name, arguments)
        except NotAuthorized:
            return JSONResponse(
                {"jsonrpc": "2.0", "id": rid,
                 "error": {"code": -32000, "message": "Upwork not authorized; run the authorize flow (GET /authorize)."}}
            )
        except httpx.HTTPError as e:
            return JSONResponse(
                {"jsonrpc": "2.0", "id": rid,
                 "error": {"code": -32000, "message": f"upstream error: {e}"}}
            )
        return JSONResponse({"jsonrpc": "2.0", "id": rid, "result": result})

    return JSONResponse(
        {"jsonrpc": "2.0", "id": rid,
         "error": {"code": -32601, "message": f"Method not found: {method}"}}
    )
