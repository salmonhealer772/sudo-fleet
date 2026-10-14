#!/usr/bin/env python3
"""Add the fleet-shared google-workspace MCP server to ONE agent's config.yaml.

    python3 mcp_servers_enable.py <config.yaml>

Why this exists
---------------
Hermes' native MCP client discovers remote MCP servers from the top-level
``mcp_servers`` block in its config. The fleet-shared Google Workspace service
(sudo-gws) must be reachable by EVERY agent, so up.sh calls this for every
deploy: a fresh agent gets the google-workspace MCP surface with no manual
step, and an already-deployed agent is upgraded on its next roll.

Why a TEXT edit and not a YAML round-trip
-----------------------------------------
``config/<name>.yaml`` is hand-maintained (credentials, API-server settings,
per-agent skins). A YAML round-trip would rewrite the whole file, deleting
comments and reflowing unrelated settings. So: a surgical edit that touches
only the ``mcp_servers`` block, then a REAL YAML parse of the result to prove
the file still loads and carries the server entry. The new text is written to
a temp file and validated BEFORE it replaces the original.

Exit codes: 0 = enabled (or already enabled), 1 = usage/missing file,
2 = could not produce a valid config (original left untouched).
"""

import os
import re
import sys

SERVER_KEY = "google_workspace"
# Baked fleet address of the shared service. 27462 = 8000 + cksum("gws") % 22000
# (the fleet MCP_PORT convention); 192.168.5.15 is the lima k3s node LAN IP.
# Keep in sync with factories/sudo-letta/mods/google-workspace/mods/index.mjs
# and factories/sudo-gws/manifests/service.yaml.
SERVER_URL = "http://192.168.5.15:27462/mcp"

_MCP_RE = re.compile(r"^mcp_servers\s*:.*$")
_KEY_RE = re.compile(r"^(\s+)%s\s*:.*$" % re.escape(SERVER_KEY))
_URL_RE = re.compile(r"^(\s+)url\s*:.*$")


def _strip_comment(value):
    return value.split(" #", 1)[0].strip()


def _block_end(lines, start):
    """Index just past the block opened at `start` (next top-level key)."""
    end = len(lines)
    for j in range(start + 1, len(lines)):
        raw = lines[j]
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if not raw[0].isspace():  # next top-level key
            end = j
            break
    return end


def _find_servers_block(lines):
    for i, line in enumerate(lines):
        if _MCP_RE.match(line.rstrip("\n")):
            return i, _block_end(lines, i)
    return None, None


def enable_server(text, key, url):
    """Return (new_text, changes). Never raises on odd input."""
    changes = []
    lines = text.splitlines(keepends=True)

    start, end = _find_servers_block(lines)
    if start is None:
        # No mcp_servers block: append a fresh one at the end.
        if text and not text.endswith("\n"):
            text += "\n"
        if text and not text.endswith("\n\n"):
            text += "\n"
        text += (
            "mcp_servers:\n"
            "  %s:\n"
            "    url: \"%s\"\n" % (key, url)
        )
        return text, ["added a top-level mcp_servers block with %s" % key]

    body = lines[start + 1:end]

    # Find the server key entry (and its url) inside the block.
    key_idx, key_indent = None, "  "
    for i, line in enumerate(body):
        m = _KEY_RE.match(line.rstrip("\n"))
        if m:
            key_idx, key_indent = i, m.group(1)
            break

    if key_idx is None:
        # Append the server entry to the end of the mcp_servers block.
        entry = [
            "%s%s:\n" % (key_indent, key),
            "%s  url: \"%s\"\n" % (key_indent, url),
        ]
        if body and not body[-1].endswith("\n"):
            body[-1] += "\n"
        body.extend(entry)
        changes.append("added %s to mcp_servers" % key)
    else:
        # Server key exists: ensure the url matches (refresh if stale).
        sub = body[key_idx + 1:]
        url_idx = None
        for j, line in enumerate(sub):
            if _URL_RE.match(line.rstrip("\n")):
                url_idx = key_idx + 1 + j
                break
        if url_idx is None:
            body.insert(key_idx + 1, "%s  url: \"%s\"\n" % (key_indent, url))
            changes.append("added url to mcp_servers.%s" % key)
        else:
            cur = _strip_comment(body[url_idx].split(":", 1)[1])
            if cur.strip().strip("\"'") != url:
                body[url_idx] = "%s  url: \"%s\"\n" % (key_indent, url)
                changes.append("mcp_servers.%s.url -> %s" % (key, url))
            else:
                changes.append("mcp_servers.%s.url already correct" % key)

    return "".join(lines[:start + 1]) + "".join(body) + "".join(lines[end:]), changes


def verify(text, key, url):
    """Prove the edited text parses AND carries the server entry."""
    try:
        import yaml
    except ImportError:
        return bool(re.search(r"(?m)^\s+%s\s*:.*$" % re.escape(key), text)), \
            "textual check only (pyyaml unavailable)"
    try:
        data = yaml.safe_load(text)
    except Exception as exc:
        return False, "YAML no longer parses: %s" % exc
    if not isinstance(data, dict):
        return False, "config root is not a mapping"
    servers = data.get("mcp_servers")
    if not isinstance(servers, dict):
        return False, "no mcp_servers mapping after the edit"
    entry = servers.get(key)
    if not isinstance(entry, dict):
        return False, "mcp_servers.%s is not a mapping (got %r)" % (key, entry)
    if entry.get("url") != url:
        return False, "mcp_servers.%s.url is %r, not %r" % (key, entry.get("url"), url)
    return True, "mcp_servers.%s.url=%s" % (key, url)


def parses(text):
    try:
        import yaml
    except ImportError:
        return None, "pyyaml unavailable"
    try:
        yaml.safe_load(text)
    except Exception as exc:
        return False, str(exc)
    return True, ""


def main(argv):
    if len(argv) > 1:
        print("usage: mcp_servers_enable.py <config.yaml>", file=sys.stderr)
        return 1
    path = argv[0] if argv else ""
    if not path:
        print("usage: mcp_servers_enable.py <config.yaml>", file=sys.stderr)
        return 1
    if not os.path.isfile(path):
        print("✗ %s does not exist — cannot enable %s" % (path, SERVER_KEY),
              file=sys.stderr)
        return 1
    with open(path, encoding="utf-8") as f:
        original = f.read()

    if not original.strip():
        print("✗ %s is empty — refusing to guess (deploy aborted)" % path,
              file=sys.stderr)
        return 2
    ok_orig, why_orig = parses(original)
    if ok_orig is False:
        print("✗ %s does not parse as YAML (%s)." % (path, why_orig), file=sys.stderr)
        print("  Hermes would ignore this config entirely; fix it before rolling. "
              "The file was NOT modified.", file=sys.stderr)
        return 2

    edited, changes = enable_server(original, SERVER_KEY, SERVER_URL)
    ok, why = verify(edited, SERVER_KEY, SERVER_URL)
    if not ok:
        print("✗ refusing to write %s: %s" % (path, why), file=sys.stderr)
        return 2
    if not changes or all(c.startswith("mcp_servers.%s.url already" % SERVER_KEY)
                          for c in changes):
        print("→ mcp_servers already enabled in %s (%s)" % (path, why))
        return 0

    tmp = path + ".mcp-servers.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(edited)
    ok2, why2 = verify(open(tmp, encoding="utf-8").read(), SERVER_KEY, SERVER_URL)
    if not ok2:
        os.unlink(tmp)
        print("✗ edited config failed verification (%s) — original untouched"
              % why2, file=sys.stderr)
        return 2
    os.replace(tmp, path)
    print("→ %s: %s (%s)" % (path, "; ".join(changes), why2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
