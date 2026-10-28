import json, os, sys

# Show the tool_call/tool_result pairs for ONE session, from the tape tail.
# Prints the command (safe: a comm-CLI invocation), the status, and a SHORT
# result snippet — enough to see BLOCKED vs allowed, with no message content.
path = "/opt/data/watch/stream.jsonl"
sess = sys.argv[1] if len(sys.argv) > 1 else ""
size = os.path.getsize(path)
block = min(size, 8 * 1024 * 1024)
with open(path, "rb") as f:
    f.seek(size - block)
    raw = f.read().decode("utf-8", "replace")

rows = []
for line in raw.splitlines():
    if not line.startswith("{"):
        continue
    try:
        rows.append(json.loads(line))
    except ValueError:
        pass

print("session filter:", sess or "(all)")
n = 0
for r in rows:
    if r.get("event") not in ("tool_call", "tool_result"):
        continue
    if sess and not str(r.get("session_id") or "").startswith(sess):
        continue
    n += 1
    tool = r.get("tool") or ""
    args = r.get("args") or {}
    cmd = ""
    if isinstance(args, dict):
        cmd = str(args.get("command") or args.get("name") or "")[:150]
    if r["event"] == "tool_call":
        print("tool_call    %-10s %s" % (tool, cmd))
    else:
        res = str(r.get("result") or "")
        res = res.replace("\n", " ")[:200]
        print("tool_result  %-10s status=%-6s dur=%-6s %s"
              % (tool, r.get("status"), r.get("duration_ms"), res))
print("pairs_total", n)
