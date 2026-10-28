#!/bin/sh
# probe-soul.sh — READ-ONLY: split SOUL.md into the hand-written identity and the
# factory-managed fleet block, and hash each SEPARATELY.
#
# Why this exists: the fleet-comm persona block is re-applied to SOUL.md on EVERY
# boot (bin/mcp_entrypoint.sh). So when an agent is recreated onto an image whose
# comm/PERSONA-SNIPPET.md changed, SOUL.md's whole-file md5 MUST change — and that
# is correct, not a regression. Judging "is the agent still itself?" by the whole
# file md5 would therefore report a false failure the moment h3's memory contract
# ships. This probe hashes the parts that must NOT change (the identity outside
# the markers) separately from the part that must (the managed block).
#
# It prints hashes and byte counts only — never the text — because SOUL.md can
# carry operator-specific identity and this output is committed to a public repo.
#
#   kubectl -n <ns> exec <pod> -c <container> -- sh -s < probe-soul.sh
set -u
H="${HERMES_HOME:-/opt/data}"
S="$H/SOUL.md"

echo "=== probe-soul.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
if [ ! -f "$S" ]; then echo "MISSING $S"; exit 1; fi
md5sum "$S"
wc -lc "$S"

python3 - "$S" <<'PY' 2>&1
import hashlib, sys
raw = open(sys.argv[1], "rb").read()
B = b"<!-- FLEET-COMM-AWARENESS-BEGIN -->"
E = b"<!-- FLEET-COMM-AWARENESS-END -->"
i, j = raw.find(B), raw.find(E)
if i < 0 or j < 0:
    print("no fleet block markers found")
    print("WHOLE sha256", hashlib.sha256(raw).hexdigest(), "bytes", len(raw))
    raise SystemExit
pre = raw[:i]
block = raw[i:j + len(E)]
post = raw[j + len(E):]
for name, part in (("IDENTITY_PREFIX", pre), ("FLEET_BLOCK", block), ("SUFFIX", post)):
    print("%-16s sha256=%s bytes=%d lines=%d"
          % (name, hashlib.sha256(part).hexdigest(), len(part), part.count(b"\n")))
# does the managed block currently carry the memory contract?
print("BLOCK_HAS_MEMORY_SECTION", b"## Your memory" in block)
print("BLOCK_HAS_ONE_ENTRY_IS_ONE_FACT", b"One entry is one fact" in block)
PY
echo "=== end ==="
