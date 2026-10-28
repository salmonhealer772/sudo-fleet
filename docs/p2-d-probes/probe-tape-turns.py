import collections, json, os, sys

# Find turn_start rows in the tape and report the EVENT VOCABULARY per turn, so
# "same shape before and after the upgrade" is a measurement, not a claim.
# Prints event names + turn ids only; no payload text.
path = "/opt/data/watch/stream.jsonl"
size = os.path.getsize(path)
window = min(size, 60 * 1024 * 1024)
with open(path, "rb") as f:
    f.seek(size - window)
    raw = f.read().decode("utf-8", "replace")

rows = []
for line in raw.splitlines():
    if line.startswith("{"):
        try:
            rows.append(json.loads(line))
        except ValueError:
            pass

turns = collections.OrderedDict()
for r in rows:
    ev = r.get("event")
    tid = r.get("turn_id") or ""
    if not tid:
        continue
    turns.setdefault(tid, collections.Counter())[ev] += 1

print("turns_in_window", len(turns))
print("window_bytes", window, "rows", len(rows))
print("--- last 6 turns: event vocabulary ---")
for tid, hist in list(turns.items())[-6:]:
    print(" turn %s" % tid[:28])
    print("   " + ", ".join("%s=%d" % (k, v) for k, v in sorted(hist.items())))
    needed = ("turn_start", "delta", "completion")
    have = [n for n in needed if hist.get(n)]
    print("   core_shape(%s): %s" % ("+".join(needed), "PRESENT" if len(have) == 3 else "MISSING %s" % [n for n in needed if n not in have]))
    print("   tool_events:", "yes" if (hist.get("tool_call") or hist.get("tool_result")) else "no")
