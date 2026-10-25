#!/usr/bin/env python3
"""Single source of truth for the per-agent Hermes API-server port.

    python3 api_server_ports.py assign <config_dir> <name>
    python3 api_server_ports.py sweep  <config_dir>
    python3 api_server_ports.py guard  <config_dir> [name]

Why this exists
---------------
Hermes' ``api_server`` platform (the gateway's own OpenAI-compatible HTTP
listener that Paperclip wakes over ``POST /v1/runs``) defaults to a FIXED
``127.0.0.1:8642``. Every sudo-agent pod runs ``hostNetwork: true``, so every
pod shares the node's network namespace and a second agent to boot on 8642 dies
with "Port 8642 already in use" -> the gateway exits -> CrashLoopBackOff. On
2026-10-25 that took 37 Hermes pods down at once.

The fix is a dedicated, collision-proof, per-agent port in **8700-8799
exclusively**. That block is deliberately separate from the MCP / watch hashed
window (8000..29999) so an api_server port can never collide with an MCP or
watch port *by construction*, and one ``grep`` shows every api_server port in
the fleet.

Assignment
----------
``stable_port(name)`` is a deterministic, machine-independent hash of the agent
name into 8700..8799 (SHA-256, so it does not depend on cksum/CRC table luck or
word size). 100 slots for the current ~66 configs means two names can hash to
the same slot, so a collision is resolved by linear-probing the 8700..8799 ring
in SORTED name order. That resolution is fully deterministic (same set of names
-> same ports) and the result is WRITTEN into each config, so:

  * idempotent — running the sweep twice changes nothing;
  * stable — a config that already carries a valid, unique port is NEVER touched
    (part C of the contract), so a given agent keeps its port across re-runs and
    across later agent additions.

The factory (bin/up.sh) calls ``assign`` for the one agent it is deploying; the
migration calls ``sweep`` over every existing config; ``guard`` is the loud
regression check (also wired into up.sh so the next agent added is caught by
tooling, not by a crashloop three days later).

Why a TEXT edit and not a YAML round-trip
-----------------------------------------
``config/<name>.yaml`` is hand-maintained (credentials, per-agent skins,
comments). A YAML round-trip would rewrite the whole file, deleting comments and
reflowing unrelated settings. So the writer is a surgical edit that touches only
the ``platforms.api_server.port`` line, then a REAL ``yaml.safe_load`` of the
result proves the file still parses and carries the port — the same pattern as
``mcp_servers_enable.py`` / ``api_server_enable.py``. The new text is written to
a temp file and validated BEFORE it replaces the original, and any pre-existing
duplicate ``port:`` key is collapsed to one.

Exit codes: 0 = ok, 1 = usage, 2 = config problem (unreadable / invalid YAML /
verification failed), 3 = guard violation.
"""

import hashlib
import os
import re
import sys
from collections import Counter

PORT_BASE = 8700
PORT_COUNT = 100          # 8700..8799 inclusive
PORT_MAX = PORT_BASE + PORT_COUNT - 1
DEFAULT_PORT = 8642       # Hermes' built-in api_server default (the collision)

_PORT_KEY_RE = re.compile(r"^\s+port\s*:")


def stable_port(name):
    """Deterministic, machine-independent port in 8700..8799 for a name."""
    digest = hashlib.sha256(("api-server:%s" % name).encode("utf-8")).hexdigest()
    return PORT_BASE + (int(digest, 16) % PORT_COUNT)


def is_valid(port):
    return isinstance(port, int) and PORT_BASE <= port <= PORT_MAX


def read_current_port(text):
    """Return the explicit platforms.api_server.port, or None if absent/broken.

    Reads with yaml.safe_load (the configs are known-valid YAML); a file that
    does not parse returns None and is treated as "no explicit port", which the
    guard then flags as resolving to the default.
    """
    try:
        import yaml  # noqa: F401
    except ImportError:
        return _read_port_textual(text)
    try:
        data = yaml.safe_load(text)
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    platforms = data.get("platforms")
    if not isinstance(platforms, dict):
        return None
    api = platforms.get("api_server")
    if not isinstance(api, dict):
        return None
    port = api.get("port")
    if isinstance(port, bool):
        return None
    if isinstance(port, int):
        return port
    if isinstance(port, str) and port.strip().isdigit():
        return int(port.strip())
    return None


def _read_port_textual(text):
    """Fallback read when pyyaml is unavailable (deploy environments)."""
    block = _api_server_block_lines(text)
    for ln in block:
        m = re.match(r"^\s+port\s*:\s*(\d+)\s*$", ln)
        if m:
            return int(m.group(1))
    return None


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


def _api_server_block_lines(text):
    """Raw lines of the platforms.api_server sub-block, or [] if absent."""
    lines = text.splitlines()
    p_idx = None
    for i, ln in enumerate(lines):
        if re.match(r"^platforms\s*:", ln):
            p_idx = i
            break
    if p_idx is None:
        return []
    a_idx = a_indent = None
    for j in range(p_idx + 1, len(lines)):
        raw = lines[j]
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if not raw[0].isspace():
            break  # left the platforms block
        m = re.match(r"^(\s+)api_server\s*:", raw)
        if m:
            a_idx, a_indent = j, len(m.group(1))
            break
    if a_idx is None:
        return []
    block = []
    for j in range(a_idx + 1, len(lines)):
        raw = lines[j]
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        ind = len(raw) - len(raw.lstrip(" "))
        if ind <= a_indent:
            break
        block.append(raw)
    return block


def _port_key_count(text):
    return sum(1 for ln in _api_server_block_lines(text) if _PORT_KEY_RE.match(ln))


def set_api_server_port(text, port):
    """Return text with platforms.api_server.port set to `port`.

    Surgical text edit (never a YAML round-trip). Handles the three shapes the
    contract requires: (1) an existing ``port:`` value is replaced; (2) an
    ``api_server:`` block lacking ``port:`` gets one inserted; (3) a config with
    no ``platforms:`` key gets the block appended. Any pre-existing duplicate
    ``port:`` line is collapsed to one. Never raises on odd input.
    """
    lines = text.splitlines(keepends=True)

    p_idx = None
    for i, ln in enumerate(lines):
        if re.match(r"^platforms\s*:", ln.rstrip("\n")):
            p_idx = i
            break

    if p_idx is None:
        # No platforms block at all: append a fresh one.
        out = text
        if out and not out.endswith("\n"):
            out += "\n"
        if out and not out.endswith("\n\n"):
            out += "\n"
        out += "platforms:\n  api_server:\n    port: %d\n" % port
        return out

    p_end = _block_end(lines, p_idx)
    body = lines[p_idx + 1:p_end]  # a copy; we edit and re-join it below

    # Find `api_server:` inside the platforms block (default indent "  ").
    a_idx, a_indent = None, "  "
    for i, ln in enumerate(body):
        m = re.match(r"^(\s+)api_server\s*:", ln.rstrip("\n"))
        if m:
            a_idx, a_indent = i, m.group(1)
            break

    if a_idx is None:
        # platforms exists but has no api_server key: append it.
        body.append("%sapi_server:\n" % a_indent)
        body.append("%s  port: %d\n" % (a_indent, port))
        return "".join(lines[:p_idx + 1]) + "".join(body) + "".join(lines[p_end:])

    # Bounds of the api_server sub-block: until a key at <= api_server indent.
    sub_end = len(body)
    for j in range(a_idx + 1, len(body)):
        raw = body[j]
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        m = re.match(r"^(\s+)\S", raw.rstrip("\n"))
        if m and len(m.group(1)) <= len(a_indent):
            sub_end = j
            break

    # Every `port:` line inside that sub-block (absolute index in `body`).
    port_abs = [
        j for j in range(a_idx + 1, sub_end)
        if _PORT_KEY_RE.match(body[j].rstrip("\n"))
    ]

    if not port_abs:
        body.insert(a_idx + 1, "%s  port: %d\n" % (a_indent, port))
    else:
        # Set the first port line's value; drop any extras (self-heal dups).
        body[port_abs[0]] = re.sub(
            r"^(\s*port\s*:\s*).*$", r"\g<1>%d" % port,
            body[port_abs[0]].rstrip("\n"),
        ) + "\n"
        for extra in reversed(port_abs[1:]):
            del body[extra]

    return "".join(lines[:p_idx + 1]) + "".join(body) + "".join(lines[p_end:])


def verify_port(text, port):
    """(ok, why): prove the edited text parses AND carries exactly this port,
    with no duplicate ``port:`` key under api_server."""
    n = _port_key_count(text)
    if n != 1:
        return False, "platforms.api_server has %d port: keys (expected exactly 1)" % n
    try:
        import yaml  # noqa: F401
    except ImportError:
        return (
            re.search(r"(?m)^\s+port\s*:\s*%d\s*$" % port, text) is not None,
            "textual check only (pyyaml unavailable)",
        )
    try:
        data = yaml.safe_load(text)
    except Exception as exc:  # noqa: BLE001
        return False, "YAML no longer parses: %s" % exc
    if not isinstance(data, dict):
        return False, "config root is not a mapping"
    platforms = data.get("platforms")
    if not isinstance(platforms, dict):
        return False, "no platforms mapping after the edit"
    api = platforms.get("api_server")
    if not isinstance(api, dict):
        return False, "no platforms.api_server mapping after the edit"
    if api.get("port") != port:
        return False, "platforms.api_server.port is %r, not %d" % (api.get("port"), port)
    return True, "platforms.api_server.port == %d (parses, single key)" % port


def _write_atomic(path, new_text, port):
    """Validate, then write via temp file + os.replace (the repo's pattern)."""
    ok, why = verify_port(new_text, port)
    if not ok:
        print("✗ refusing to write %s: %s" % (path, why), file=sys.stderr)
        return False
    tmp = path + ".api-port.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(new_text)
    os.replace(tmp, path)
    return True


def _scan(config_dir):
    """Return (names, info) for every *.yaml config, info[name] = {path, text,
    port}. Sorted by name so every assignment below is deterministic."""
    names = sorted(
        f[:-5] for f in os.listdir(config_dir)
        if f.endswith(".yaml") and os.path.isfile(os.path.join(config_dir, f))
    )
    info = {}
    for name in names:
        path = os.path.join(config_dir, name + ".yaml")
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        info[name] = {"path": path, "text": text, "port": read_current_port(text)}
    return names, info


def _plan(config_dir):
    """Split configs into `keep` (valid + unique port, leave alone) and
    `reassign` (missing / out-of-range / duplicate port, or a duplicated
    ``port:`` key)."""
    names, info = _scan(config_dir)
    counts = Counter(
        info[n]["port"] for n in names if is_valid(info[n]["port"])
    )
    keep = {}
    reassign = []
    taken = set()
    for n in names:
        p = info[n]["port"]
        duplicated_key = _port_key_count(info[n]["text"]) > 1
        if (not duplicated_key) and is_valid(p) and counts.get(p, 0) == 1:
            keep[n] = p
            taken.add(p)
        else:
            reassign.append(n)
    return names, info, keep, reassign, taken


def _assignments(reassign, taken):
    """Deterministic collision-free ports: probe the 8700..8799 ring in sorted
    name order, skipping already-taken ports."""
    result = {}
    taken = set(taken)
    for n in sorted(reassign):
        p = stable_port(n)
        while p in taken:
            p = PORT_BASE + ((p - PORT_BASE + 1) % PORT_COUNT)
        taken.add(p)
        result[n] = p
    return result


def cmd_assign(config_dir, name):
    path = os.path.join(config_dir, name + ".yaml")
    if not os.path.isfile(path):
        print("✗ %s does not exist — cannot assign an api_server port" % path,
              file=sys.stderr)
        return 1
    names, info, keep, reassign, taken = _plan(config_dir)
    if name not in info:
        print("✗ %s not found in %s" % (name + ".yaml", config_dir), file=sys.stderr)
        return 1
    if name in keep:
        print(keep[name])
        return 0
    assignments = _assignments(reassign, taken)
    port = assignments[name]
    new_text = set_api_server_port(info[name]["text"], port)
    if not _write_atomic(path, new_text, port):
        return 2
    print(port)
    return 0


def cmd_sweep(config_dir):
    names, info, keep, reassign, taken = _plan(config_dir)
    assignments = _assignments(reassign, taken)
    changed = 0
    for n in sorted(assignments):
        path = info[n]["path"]
        new_text = set_api_server_port(info[n]["text"], assignments[n])
        if new_text == info[n]["text"]:
            continue
        if not _write_atomic(path, new_text, assignments[n]):
            return 2
        changed += 1
        print("→ %s.yaml: platforms.api_server.port -> %d" % (n, assignments[n]))
    print("swept %d configs: %d assigned, %d already valid+unique, 0 skipped"
          % (len(names), changed, len(keep)))
    return 0


def cmd_guard(config_dir, name=None):
    names, info, keep, reassign, taken = _plan(config_dir)
    resolved = {}
    for n in names:
        p = info[n]["port"]
        resolved[n] = p if p is not None else DEFAULT_PORT

    violations = []  # (port, [members], kind)
    counts = Counter(resolved.values())
    for port in sorted(counts):
        members = [n for n in names if resolved[n] == port]
        if port == DEFAULT_PORT:
            violations.append((port, members, "default"))
        elif not is_valid(port):
            violations.append((port, members, "out-of-range"))
        elif counts[port] > 1:
            violations.append((port, members, "duplicate"))

    if name is not None:
        violations = [(p, m, k) for (p, m, k) in violations if name in m]

    if violations:
        for port, members, kind in violations:
            if kind == "default":
                print("✗ resolves to the built-in default %d: %s"
                      % (port, ", ".join(members)), file=sys.stderr)
            elif kind == "out-of-range":
                print("✗ api_server port %d is outside %d..%d: %s"
                      % (port, PORT_BASE, PORT_MAX, ", ".join(members)), file=sys.stderr)
            else:
                print("✗ duplicate api_server port %d: %s"
                      % (port, ", ".join(members)), file=sys.stderr)
        print("guard FAILED: %d violation(s)" % len(violations), file=sys.stderr)
        return 3
    scope = name if name else "all %d configs" % len(names)
    print("✓ guard OK: %s resolve to unique api_server ports in %d..%d"
          % (scope, PORT_BASE, PORT_MAX))
    return 0


_USAGE = """usage:
  api_server_ports.py assign <config_dir> <name>   ensure one config's port, print it
  api_server_ports.py sweep  <config_dir>          ensure every config's port (idempotent)
  api_server_ports.py guard  <config_dir> [name]   fail loudly on 8642 or duplicate ports
"""


def main(argv):
    if not argv:
        print(_USAGE, file=sys.stderr)
        return 1
    cmd = argv[0]
    if cmd == "assign" and len(argv) == 3:
        return cmd_assign(argv[1], argv[2])
    if cmd == "sweep" and len(argv) == 2:
        return cmd_sweep(argv[1])
    if cmd == "guard" and len(argv) in (2, 3):
        return cmd_guard(argv[1], argv[2] if len(argv) == 3 else None)
    print(_USAGE, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
