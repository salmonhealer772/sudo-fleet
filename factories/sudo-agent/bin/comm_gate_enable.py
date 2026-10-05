#!/usr/bin/env python3
"""Enable the sudo-comm-gate plugin in ONE agent's Hermes config.yaml.

    python3 comm_gate_enable.py <config.yaml> [plugin-key]

Why this exists
---------------
A Hermes plugin of kind ``standalone`` is opt-in: it loads only when its key
appears in ``plugins.enabled``. up.sh calls this for every deploy, so a fresh
agent gets the comm gate with no manual step, and an already-deployed agent is
upgraded on its next roll. Unlike the watch plugin, the comm gate does NOT need
``stream_reasoning_deltas`` — it only registers ``on_skill_lifecycle`` +
``pre_tool_call`` — so this helper edits ONLY ``plugins.enabled``.

Why a TEXT edit and not a YAML round-trip
-----------------------------------------
``config/<name>.yaml`` is hand-maintained: operators add credentials, API
server settings and per-agent skins. A YAML round-trip would rewrite the whole
file, deleting comments and reflowing unrelated settings. So: a surgical edit
that touches only the ``plugins.enabled`` list, then a REAL YAML parse of the
result to prove the file still loads and carries the key. The new text is
written to a temp file and validated BEFORE it replaces the original.

Exit codes: 0 = enabled (or already enabled), 1 = usage/missing file,
2 = could not produce a valid config (original left untouched).
"""

import os
import re
import sys

PLUGIN_KEY_DEFAULT = "sudo-comm-gate"

_ENABLED_RE = re.compile(r"^(\s+)enabled:\s*(.*?)\s*$")
_ITEM_RE = re.compile(r"^(\s+)-?\s*(.*?)\s*$")
_PLUGINS_RE = re.compile(r"^plugins:\s*(#.*)?$")


def _strip_comment(value):
    return value.split(" #", 1)[0].strip()


def _find_plugins_block(lines):
    start = None
    for i, line in enumerate(lines):
        if _PLUGINS_RE.match(line.rstrip("\n")):
            start = i
            break
    if start is None:
        return None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        raw = lines[j]
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if not raw[0].isspace():  # next top-level key
            end = j
            break
    return start, end


def enable_plugin(text, key):
    """Return (new_text, changes). Never raises on odd input."""
    changes = []
    lines = text.splitlines(keepends=True)
    block = _find_plugins_block(lines)
    if block is None:
        if text and not text.endswith("\n"):
            text += "\n"
        if text and not text.endswith("\n\n"):
            text += "\n"
        text += "plugins:\n  enabled:\n    - %s\n" % key
        return text, ["added a top-level plugins: block"]

    start, end = block
    body = lines[start + 1:end]

    en_idx, en_indent, en_val = None, "  ", ""
    for i, line in enumerate(body):
        m = _ENABLED_RE.match(line.rstrip("\n"))
        if m:
            en_idx, en_indent, en_val = i, m.group(1), _strip_comment(m.group(2))
            break
    if en_idx is None:
        body.insert(0, "%senabled:\n" % en_indent)
        body.insert(1, "%s  - %s\n" % (en_indent, key))
        changes.append("created plugins.enabled with %s" % key)
    elif en_val.startswith("["):
        inner = en_val[1:en_val.rindex("]")] if "]" in en_val else en_val[1:]
        items = [x.strip().strip("'\"") for x in inner.split(",") if x.strip()]
        if key not in items:
            items.append(key)
            body[en_idx] = "%senabled: [%s]\n" % (en_indent, ", ".join(items))
            changes.append("added %s to plugins.enabled" % key)
    else:
        j, item_indent, present = en_idx + 1, None, False
        while j < len(body):
            m2 = _ITEM_RE.match(body[j].rstrip("\n"))
            if not m2 or not body[j].lstrip().startswith("-"):
                break
            if item_indent is None:
                item_indent = m2.group(1)
            if _strip_comment(m2.group(2)).strip().strip("'\"") == key:
                present = True
            j += 1
        if not present:
            body.insert(en_idx + 1,
                        "%s- %s\n" % (item_indent or (en_indent + "  "), key))
            changes.append("added %s to plugins.enabled" % key)

    return "".join(lines[:start + 1]) + "".join(body) + "".join(lines[end:]), changes


def verify(text, key):
    try:
        import yaml
    except ImportError:
        if not re.search(r"(?m)^\s+enabled:.*\b%s\b" % re.escape(key), text) \
           and not re.search(r"(?m)^\s+-\s*%s\s*$" % re.escape(key), text):
            return False, "plugins.enabled does not list %s (textual check)" % key
        return True, "textual check only (pyyaml unavailable)"
    try:
        data = yaml.safe_load(text)
    except Exception as exc:
        return False, "YAML no longer parses: %s" % exc
    if not isinstance(data, dict):
        return False, "config root is not a mapping"
    plugins = data.get("plugins")
    if not isinstance(plugins, dict):
        return False, "no plugins mapping after the edit"
    enabled = plugins.get("enabled")
    if not isinstance(enabled, list) or key not in [str(x) for x in enabled]:
        return False, "plugins.enabled does not list %s (got %r)" % (key, enabled)
    return True, "plugins.enabled=%s" % (enabled,)


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
    if len(argv) > 2:
        print("usage: comm_gate_enable.py <config.yaml> [plugin-key]",
              file=sys.stderr)
        return 1
    path = argv[0] if argv else ""
    key = argv[1] if len(argv) > 1 else PLUGIN_KEY_DEFAULT
    if not path:
        print("usage: comm_gate_enable.py <config.yaml> [plugin-key]",
              file=sys.stderr)
        return 1
    if not os.path.isfile(path):
        print("✗ %s does not exist — cannot enable %s" % (path, key),
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
        print("✗ %s does not parse as YAML (%s)." % (path, why_orig),
              file=sys.stderr)
        print("  Hermes would ignore this config entirely; fix it before "
              "rolling. The file was NOT modified.", file=sys.stderr)
        return 2

    edited, changes = enable_plugin(original, key)
    ok, why = verify(edited, key)
    if not ok:
        print("✗ refusing to write %s: %s" % (path, why), file=sys.stderr)
        return 2
    if not changes:
        print("→ plugins already enabled in %s (%s)" % (path, why))
        return 0

    tmp = path + ".comm-gate.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(edited)
    ok2, why2 = verify(open(tmp, encoding="utf-8").read(), key)
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
