"""Patch: auto-save every user message to memory programmatically, no LLM decision."""
import sys

PATH = "/opt/hermes/agent/background_review.py"

with open(PATH) as f:
    code = f.read()

# The review worker `_run_review_in_thread` is the one place we can reach the
# PARENT agent's real memory store with the latest user-message snapshot, before
# the review fork is built. Its body has churned across base-image versions, so
# the anchor that used to be stable no longer is:
#   * "    st = _ReviewForkState()\n"                                  -> present in
#     OLDER bases (immediately before the fork is built — the ideal insertion
#     point); removed in newer bases.
#   * "    from tools.terminal_tool import set_approval_callback as _set_approval_callback\n"
#     -> the local import that opens the worker in NEWER bases (5177d04 re-anchor).
#   * "    from tools.terminal_tool import set_approval_callback\n"    -> the same
#     import WITHOUT the alias (a middle base); it also appears in the
#     _set_thread_approval_callback helper of older bases, so it is tried LAST
#     and only after the two unambiguous anchors miss.
# We try anchors in order and insert the auto-save block immediately after the
# FIRST one that matches, so a fresh box (newest base) and a stale box (older
# base) both patch cleanly. If none match, fail loud — a silently unpatched
# image would ship without save-every-message memory.

AUTO_SAVE = '''    # ---- PROGRAMMATIC AUTO-SAVE: save every user message to memory ----
    try:
        store = agent._memory_store
        if store is not None and messages_snapshot:
            for msg in reversed(messages_snapshot):
                if isinstance(msg, dict) and msg.get("role") == "user":
                    content = msg.get("content", "")
                    if isinstance(content, str) and content and len(content) < 5000:
                        store.add("memory", content)
                        store.add("user", content[:2000])
                        logger.info("Auto-saved user message to memory")
                    break
    except Exception as ex:
        logger.warning("Auto-save failed (non-critical): %s", ex)
    # ---- end auto-save ----
'''

if "PROGRAMMATIC AUTO-SAVE" in code:
    print("Already patched (auto-save present) — no-op")
else:
    anchors = [
        "    st = _ReviewForkState()\n",
        "    from tools.terminal_tool import set_approval_callback as _set_approval_callback\n",
        "    from tools.terminal_tool import set_approval_callback\n",
    ]
    patched = False
    for anchor in anchors:
        if anchor in code:
            code = code.replace(anchor, anchor + AUTO_SAVE, 1)
            patched = True
            print("Patched _run_review_in_thread with programmatic auto-save (anchor: %s)" % anchor.strip())
            break
    if not patched:
        print(
            "ERROR: no known insertion point found in %s (tried: %s)"
            % (PATH, " | ".join(a.strip() for a in anchors)),
            file=sys.stderr,
        )
        sys.exit(1)
    with open(PATH, "w") as f:
        f.write(code)
