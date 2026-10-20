#!/usr/bin/env python3
"""Enable the Hermes API server (platforms.api_server) in ONE agent's config.yaml.

    python3 api_server_enable.py <config.yaml>

Why this exists
---------------
Paperclip (hermes_gateway) wakes an agent over its OWN Hermes API server
(POST /v1/runs). That listener is the gateway's ``platforms.api_server``
platform, which is OFF by default in the tracked config.yaml template. up.sh
calls this for every deploy so a fresh agent ships with the API server ON and
an already-deployed agent is upgraded on its next roll.

Why a TEXT edit and not a YAML round-trip
-----------------------------------------
``config/<name>.yaml`` is hand-maintained (credentials, API-server settings,
per-agent skins). A YAML round-trip would rewrite the whole file, deleting
comments and reflowing unrelated settings. So: a surgical edit that only
touches ``platforms.api_server.enabled``, then a REAL YAML parse of the result
to prove the file still loads and the flag is on.

Exit codes: 0 = enabled (or already enabled), 1 = usage/missing file,
2 = could not produce a valid config (original left untouched).
"""

import os
import re
import sys


def _parse(text):
    """(ok, why): ok is None when pyyaml is unavailable, else True/False."""
    try:
        import yaml  # noqa: F401
    except ImportError:
        return None, "pyyaml unavailable"
    try:
        yaml.safe_load(text)
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)
    return True, ""


def _block_end(lines, start):
    """Index just past the block opened at `start` (next top-level key)."""
    end = len(lines)
    for j in range(start + 1, len(lines)):
        raw = lines[j]
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if not raw[0].isspace():
            end = j
            break
    return end


def enable(text):
    """Return (new_text, changed). Never raises on odd input."""
    lines = text.splitlines(keepends=True)

    # Locate the top-level `platforms:` block.
    p_idx = None
    for i, ln in enumerate(lines):
        if re.match(r"^platforms\s*:", ln.rstrip("\n")):
            p_idx = i
            break

    if p_idx is None:
        # No platforms block at all: append a fresh one.
        if text and not text.endswith("\n"):
            text += "\n"
        text += "\nplatforms:\n  api_server:\n    enabled: true\n"
        return text, True

    p_end = _block_end(lines, p_idx)
    body = lines[p_idx + 1:p_end]

    # Find `api_server:` inside the platforms block.
    a_idx, a_indent = None, "  "
    for i, ln in enumerate(body):
        m = re.match(r"^(\s+)api_server\s*:", ln.rstrip("\n"))
        if m:
            a_idx, a_indent = i, m.group(1)
            break

    if a_idx is None:
        # platforms exists but has no api_server key: append it.
        body.append("%sapi_server:\n" % a_indent)
        body.append("%s  enabled: true\n" % a_indent)
        return "".join(lines[:p_idx + 1]) + "".join(body) + "".join(lines[p_end:]), True

    # Scan the api_server sub-block (until a key at <= api_server indent).
    a_start = a_idx + 1
    sub_end = len(body)
    for j in range(a_start, len(body)):
        raw = body[j]
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        m = re.match(r"^(\s+)\S", raw.rstrip("\n"))
        if m and len(m.group(1)) <= len(a_indent):
            sub_end = j
            break
    sub = body[a_start:sub_end]

    # Find `enabled:` inside the api_server sub-block.
    e_idx = None
    for i, ln in enumerate(sub):
        if re.match(r"^\s+enabled\s*:", ln.rstrip("\n")):
            e_idx = i
            break

    if e_idx is None:
        # api_server has no enabled line: insert one right after api_server:.
        body.insert(a_idx + 1, "%s  enabled: true\n" % a_indent)
        return "".join(lines[:p_idx + 1]) + "".join(body) + "".join(lines[p_end:]), True

    cur = sub[e_idx].rstrip("\n")
    if re.search(r"enabled\s*:\s*(true|True|1|yes|on|Yes|On)\s*$", cur):
        return text, False  # already enabled
    sub[e_idx] = re.sub(r"(enabled\s*:\s*).*$", r"\g<1>true", cur) + "\n"
    return (
        "".join(lines[:p_idx + 1])
        + "".join(body[:a_start])
        + "".join(sub)
        + "".join(body[a_start + len(sub):])
        + "".join(lines[p_end:])
    ), True


def main(argv):
    if len(argv) > 1:
        print("usage: api_server_enable.py <config.yaml>", file=sys.stderr)
        return 1
    path = argv[0] if argv else ""
    if not path or not os.path.isfile(path):
        print("✗ %s does not exist — cannot enable platforms.api_server" % path,
              file=sys.stderr)
        return 1
    with open(path, encoding="utf-8") as f:
        original = f.read()

    if not original.strip():
        print("✗ %s is empty — refusing to guess (deploy aborted)" % path, file=sys.stderr)
        return 2

    ok_orig, why_orig = _parse(original)
    if ok_orig is False:
        print("✗ %s does not parse as YAML (%s) — original left untouched" % (path, why_orig),
              file=sys.stderr)
        return 2

    new_text, changed = enable(original)
    if not changed:
        print("→ platforms.api_server already enabled in %s" % path)
        return 0

    # Validate the edited text parses AND the flag is really on.
    ok, why = _parse(new_text)
    if ok is False:
        print("✗ refusing to write %s: %s" % (path, why), file=sys.stderr)
        return 2
    try:
        import yaml  # noqa: F401
        data = yaml.safe_load(new_text)
        if not (isinstance(data, dict)
                and isinstance(data.get("platforms"), dict)
                and isinstance(data["platforms"].get("api_server"), dict)
                and data["platforms"]["api_server"].get("enabled") is True):
            print("✗ edited config lacks platforms.api_server.enabled=true — original untouched",
                  file=sys.stderr)
            return 2
    except ImportError:
        # Textual fallback (pyyaml unavailable, as in some deploy environments):
        # the three keys must appear in order with the right nesting.
        m = re.search(
            r"platforms\s*:\s*\n\s+api_server\s*:\s*\n\s+enabled\s*:\s*true\b",
            new_text)
        if not m:
            print("✗ edited config lacks platforms.api_server.enabled=true (textual) — original untouched",
                  file=sys.stderr)
            return 2
    except Exception as exc:  # noqa: BLE001
        print("✗ could not verify edited config (%s) — original untouched" % exc, file=sys.stderr)
        return 2

    tmp = path + ".api-server.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(new_text)
    os.replace(tmp, path)
    print("→ %s: platforms.api_server.enabled -> true" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
