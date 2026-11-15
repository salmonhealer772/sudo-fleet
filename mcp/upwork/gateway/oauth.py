"""Upwork OAuth 2.1 (CIMD + PKCE) helpers for the sudo-upwork-mcp gateway.

The gateway is the OAuth *client* to Upwork's official MCP authorization server
(https://mcp.upwork.com). Upwork advertises `client_id_metadata_document_supported`
in its authorization-server metadata, i.e. it uses Client ID Metadata Documents
(CIMD): the client_id is a public HTTPS URL serving this gateway's metadata JSON
(see ../oauth/client-metadata.json), there is no client_secret
(token_endpoint_auth_method = "none"), and the flow is authorization_code + PKCE
(S256) + refresh_token.

Tokens (access + refresh) live on the PVC at UPWORK_TOKEN_FILE so they survive
pod restarts. Only the access token is ever sent to the MCP server; the refresh
token is exchanged at the token endpoint when the access token expires.

No secrets are committed: the token file is written at runtime onto the pod PVC.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import time
import urllib.parse
from typing import Any, Optional

import httpx

# ── Fixed endpoints (from Upwork's AS metadata, fetched 2026-11-15) ─────────
UPWORK_MCP_URL = "https://mcp.upwork.com/mcp"
AUTHORIZATION_ENDPOINT = "https://www.upwork.com/ab/account-security/oauth2/authorize"
TOKEN_ENDPOINT = "https://www.upwork.com/api/v3/oauth2/token"
REVOCATION_ENDPOINT = "https://www.upwork.com/api/v3/oauth2/token/revoke"
RESOURCE = "https://mcp.upwork.com/mcp"

# CIMD client_id = the public HTTPS URL of our metadata document (no secret).
CLIENT_ID = os.getenv(
    "UPWORK_CLIENT_ID",
    "https://cdn.jsdelivr.net/gh/salmonhealer772/sudo-fleet@main/mcp/upwork/oauth/client-metadata.json",
)
# Loopback redirect on the operator's Mac; a small helper (kube-scripts/consent.py)
# listens here and forwards the code to the pod. Must match client-metadata.json.
REDIRECT_URI = os.getenv("UPWORK_REDIRECT_URI", "http://127.0.0.1:8747/callback")

TOKEN_FILE = os.getenv("UPWORK_TOKEN_FILE", "/data/tokens.json")


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def new_pkce() -> tuple[str, str]:
    """Return (code_verifier, code_challenge) for the S256 PKCE method."""
    verifier = _b64url(secrets.token_bytes(32))
    challenge = _b64url(hashlib.sha256(verifier.encode()).digest())
    return verifier, challenge


def new_state() -> str:
    return _b64url(secrets.token_bytes(16))


def load_tokens() -> Optional[dict[str, Any]]:
    try:
        with open(TOKEN_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if data.get("access_token"):
            return data
    except (OSError, json.JSONDecodeError):
        pass
    return None


def save_tokens(tokens: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(TOKEN_FILE) or "/", exist_ok=True)
    tmp = TOKEN_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(tokens, f)
    os.replace(tmp, TOKEN_FILE)


def build_authorization_url() -> tuple[str, str, str]:
    """Build the authorization URL. Returns (url, code_verifier, state)."""
    verifier, challenge = new_pkce()
    state = new_state()
    params = {
        "response_type": "code",
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "resource": RESOURCE,
        "state": state,
    }
    url = AUTHORIZATION_ENDPOINT + "?" + urllib.parse.urlencode(params)
    return url, verifier, state


def _parse_token_response(resp: httpx.Response) -> dict[str, Any]:
    if resp.status_code != 200:
        try:
            err = resp.json()
        except Exception:
            err = {"raw": resp.text[:500]}
        raise RuntimeError(
            f"token endpoint returned HTTP {resp.status_code}: {err}"
        )
    tok = resp.json()
    if "access_token" not in tok:
        raise RuntimeError(f"token endpoint returned no access_token: {tok}")
    return tok


def _normalize(tok: dict[str, Any], prev: Optional[dict[str, Any]] = None) -> dict[str, Any]:
    expires_in = int(tok.get("expires_in") or 3600)
    tok["expires_at"] = time.time() + expires_in - 60  # 60s safety margin
    if "refresh_token" not in tok and prev and prev.get("refresh_token"):
        tok["refresh_token"] = prev["refresh_token"]
    tok["client_id"] = CLIENT_ID
    return tok


def exchange_code(code: str, code_verifier: str) -> dict[str, Any]:
    """Exchange the authorization code for access + refresh tokens."""
    data = {
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": REDIRECT_URI,
        "client_id": CLIENT_ID,
        "code_verifier": code_verifier,
        "resource": RESOURCE,
    }
    resp = httpx.post(TOKEN_ENDPOINT, data=data, timeout=30.0)
    tok = _normalize(_parse_token_response(resp))
    save_tokens(tok)
    return tok


def refresh_tokens(tokens: dict[str, Any]) -> dict[str, Any]:
    """Refresh the access token using the refresh token."""
    if not tokens.get("refresh_token"):
        raise RuntimeError("no refresh token available")
    data = {
        "grant_type": "refresh_token",
        "refresh_token": tokens["refresh_token"],
        "client_id": CLIENT_ID,
    }
    resp = httpx.post(TOKEN_ENDPOINT, data=data, timeout=30.0)
    tok = _normalize(_parse_token_response(resp), prev=tokens)
    save_tokens(tok)
    return tok


def get_access_token() -> Optional[str]:
    """Return a valid access token, refreshing if necessary. None if unauthorized."""
    tokens = load_tokens()
    if not tokens:
        return None
    if tokens.get("expires_at", 0) > time.time():
        return tokens["access_token"]
    try:
        refreshed = refresh_tokens(tokens)
        return refreshed["access_token"]
    except Exception:
        return None


def revoke() -> None:
    tokens = load_tokens()
    if tokens and tokens.get("access_token"):
        try:
            httpx.post(
                REVOCATION_ENDPOINT,
                data={
                    "token": tokens["access_token"],
                    "client_id": CLIENT_ID,
                },
                timeout=15.0,
            )
        except Exception:
            pass
    if os.path.exists(TOKEN_FILE):
        os.remove(TOKEN_FILE)
