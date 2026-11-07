#!/usr/bin/env python3
"""Generate email-mcp config.toml from ortie OAuth token JSONs.

Reuses the operator's EXISTING OAuth refresh tokens (no new consent).
Reads one JSON per account (the ortie token files), emits a config.toml.

Usage: gen-config.py <token-dir> <out-config.toml>
"""
import json
import os
import sys

GOOGLE_CLIENT_ID = "406964657835-aq8lmia8j95dhl1a2bvharmfk3t1hgqj.apps.googleusercontent.com"
GOOGLE_CLIENT_SECRET = "kSmqreRr0qwBWJgbf5Y-PjSU"  # Thunderbird public client secret
MS_CLIENT_ID = "9e5f94bc-e8a4-4e73-b8be-63364c29d753"  # Thunderbird public client (no secret)

# account_name -> (email, provider)
ACCOUNTS = [
    ("aidan", "aidanmcohen@gmail.com", "google"),
    ("aidan77223", "aidan77223@gmail.com", "google"),
    ("aidansteam77223", "aidansteam77223@gmail.com", "google"),
    ("sbaco", "aidan@sbadventureco.com", "google"),
    ("neu", "cohen.aid@northeastern.edu", "microsoft"),
]


def refresh_token(token_dir: str, name: str) -> str:
    path = os.path.join(token_dir, f"{name}.json")
    with open(path) as f:
        data = json.load(f)
    rt = data.get("refresh_token")
    if not rt:
        raise SystemExit(f"no refresh_token in {path}")
    return rt


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: gen-config.py <token-dir> <out-config.toml>")
    token_dir, out = sys.argv[1], sys.argv[2]
    parts = ["[settings]\nrate_limit = 30\n"]
    for name, email, provider in ACCOUNTS:
        rt = refresh_token(token_dir, name)
        oauth = (
            f'[accounts.oauth2]\nprovider = "{provider}"\n'
            f'client_id = "{GOOGLE_CLIENT_ID if provider == "google" else MS_CLIENT_ID}"\n'
        )
        if provider == "google":
            oauth += f'client_secret = "{GOOGLE_CLIENT_SECRET}"\n'
        oauth += f'refresh_token = "{rt}"\n'
        if provider == "google":
            imap_host, smtp_host = "imap.gmail.com", "smtp.gmail.com"
        else:
            imap_host, smtp_host = "outlook.office365.com", "smtp.office365.com"
        block = (
            f'\n[[accounts]]\nname = "{name}"\nemail = "{email}"\nfull_name = "Aidan"\n\n'
            f"{oauth}\n"
            f"[accounts.imap]\nhost = \"{imap_host}\"\nport = 993\ntls = true\n\n"
            f"[accounts.smtp]\nhost = \"{smtp_host}\"\nport = 587\ntls = false\nstarttls = true\nverify_ssl = true\n\n"
            f"[accounts.smtp.pool]\nenabled = true\nmax_connections = 1\nmax_messages = 100\n"
        )
        parts.append(block)
    data = "".join(parts)
    with open(out, "w") as f:
        f.write(data)
    os.chmod(out, 0o600)
    print(f"wrote {out} ({len(data)} bytes, mode 600)")


if __name__ == "__main__":
    main()
