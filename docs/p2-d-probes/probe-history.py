import json
import sys

sys.path.insert(0, "/opt/hermes")

print("=== STEP 3C: history read, counts and dates only ===")

# 1. Raw spans straight out of the store (no content printed).
import sqlite3
c = sqlite3.connect("file:/opt/data/state.db?mode=ro", uri=True)
print("sessions", c.execute("SELECT COUNT(*) FROM sessions").fetchone()[0])
print("messages", c.execute("SELECT COUNT(*) FROM messages").fetchone()[0])
print("schema_version", c.execute("SELECT version FROM schema_version").fetchone()[0])

lo, hi = c.execute("SELECT MIN(started_at), MAX(started_at) FROM sessions").fetchone()
import datetime
def d(ts):
    try:
        return datetime.datetime.utcfromtimestamp(float(ts)).strftime("%Y-%m-%d")
    except Exception:
        return str(ts)
print("session_date_range", d(lo), "->", d(hi))

rows = c.execute("""
    SELECT COUNT(*) FROM sessions
    WHERE started_at < 1792394400
""").fetchone()[0]
print("sessions_started_before_2026-10-19", rows)

# 2. The PRODUCT path: the same tool the agent uses.
from tools.session_search_tool import session_search

out = session_search(query="", limit=3)
s = out if isinstance(out, str) else json.dumps(out, default=str)
try:
    j = json.loads(s)
    res = j.get("results") or []
    print("session_search browse: success=%s results=%d mode=%s"
          % (j.get("success"), len(res), j.get("mode")))
    dates = []
    for r in res:
        dates.append(str(r.get("started_at")))
    print("  result_count %d  (timestamps present: %d)" % (len(res), len(dates)))
except Exception as e:
    print("session_search parse issue:", e)

out2 = session_search(query="email", limit=3)
s2 = out2 if isinstance(out2, str) else json.dumps(out2, default=str)
try:
    j2 = json.loads(s2)
    res2 = j2.get("results") or []
    print("session_search discover('email'): success=%s results=%d mode=%s"
          % (j2.get("success"), len(res2), j2.get("mode")))
    whens = sorted({r.get("when") for r in res2 if r.get("when")})
    print("  matched_dates", whens[:5], "count", len(whens))
except Exception as e:
    print("session_search parse issue:", e)

print("=== content deliberately NOT printed (this agent handles live correspondence) ===")
