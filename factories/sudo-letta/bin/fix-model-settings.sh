#!/usr/bin/env bash
set -uo pipefail

# bin/fix-model-settings.sh — re-apply a glimor's declared model_settings
# (context_window_limit / max_tokens) onto a LIVE sudo-letta agent record.
#
# WHY THIS EXISTS (the "fix B" that broke Marc):
#   `letta model set <handle>` — run by bin/up.sh on EVERY deploy — applies the
#   CLI's CATALOG DEFAULT for the model. For a BYOK `openai-compatible` endpoint
#   the catalog has no entry, so it falls back to context_window_limit=128000.
#   That silently OVERWRITES the smaller cap seeded from the glimor, even though
#   the served vLLM model caps at max_model_len=65536 — and a prompt over the cap
#   is then 400'd by the server.
#   The agent record's model_settings IS the source of truth (verified: the
#   one-shot runner reads record.model_settings.context_window_limit, and
#   `letta model get --agent <id>` reports it). So after a deploy, re-apply the
#   glimor's declared values here.
#
# SAFE BY DESIGN: additive + idempotent; it never edits up.sh, and it is only
# run for an agent you name (never implicitly for marc/caesar).
#
# Usage:
#   bash bin/fix-model-settings.sh --name <agent> [--from-glimor <dir>]
#     --from-glimor <dir>   read context_window_limit + max_tokens from
#                           <dir>/letta/lc-local-backend/agents/*.json (the seed)
#                           and write them onto the live pod record.
#     (no --from-glimor)    report the live settings only; make no change.

NAME=""; GLIMOR_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-glimor) GLIMOR_DIR="$2"; shift 2 ;;
    --name)        NAME="$2";     shift 2 ;;
    --*)           NAME="${1#--}"; shift ;;
    *) echo "Usage: bash bin/fix-model-settings.sh --name <agent> [--from-glimor <dir>]" >&2; exit 1 ;;
  esac
done
[[ -n "$NAME" ]] || { echo "Usage: bash bin/fix-model-settings.sh --name <agent> [--from-glimor <dir>]" >&2; exit 1; }
NAME_L="${NAME,,}"

KUBECTL="${KUBECTL:-kubectl}"
if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in "$HOME/.kube/config" /etc/rancher/k3s/k3s.yaml; do
    if [[ -f "$cfg" && -r "$cfg" ]]; then export KUBECONFIG="$cfg"; break; fi
  done
fi

POD="$($KUBECTL get pods -l agent="$NAME_L" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -n "$POD" ]] || { echo "✗ no running pod for agent=$NAME_L" >&2; exit 1; }
echo "→ pod $POD (deploy sudo-$NAME_L)"

APPLY="False"; CTX="0"; MT="0"
if [[ -n "$GLIMOR_DIR" ]]; then
  REC="$(ls "$GLIMOR_DIR"/letta/lc-local-backend/agents/*.json 2>/dev/null | head -1)"
  [[ -n "$REC" ]] || { echo "✗ no agent record under $GLIMOR_DIR/letta/lc-local-backend/agents/" >&2; exit 1; }
  read -r CTX MT < <(python3 - "$REC" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); ms = d.get("model_settings") or {}
print(int(ms.get("context_window_limit", 0) or 0), int(ms.get("max_tokens", 0) or 0))
PY
)
  echo "→ desired (from glimor $REC): context_window_limit=$CTX max_tokens=$MT"
  APPLY="True"
else
  echo "→ no --from-glimor: reporting live settings only (no change)"
fi

PY="$(cat <<PYEOF
import json, glob, os
CTX = $CTX
MT = $MT
APPLY = $APPLY
paths = sorted(glob.glob("/home/node/.letta/lc-local-backend/agents/*.json"))
if not paths:
    raise SystemExit("NO AGENT RECORD FOUND")
for p in paths:
    d = json.load(open(p))
    ms = d.setdefault("model_settings", {})
    before = (ms.get("context_window_limit"), ms.get("max_tokens"))
    if APPLY:
        if CTX:
            ms["context_window_limit"] = CTX
        if MT:
            ms["max_tokens"] = MT
        tmp = p + ".tmp"
        with open(tmp, "w") as f:
            json.dump(d, f, indent=2); f.write("\n")
        os.replace(tmp, p)
    print(("patched " if APPLY else "live    "), os.path.basename(p),
          "name=", d.get("name"), "tags=", d.get("tags"),
          before, "->", (ms.get("context_window_limit"), ms.get("max_tokens")))
PYEOF
)"

printf '%s' "$PY" | $KUBECTL exec -i "$POD" -c sudo-letta -- python3 -
echo "✓ done ($([[ "$APPLY" == "True" ]] && echo applied || echo report-only))"
