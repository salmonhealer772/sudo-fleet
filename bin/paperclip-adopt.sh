#!/usr/bin/env bash
set -uo pipefail

# bin/paperclip-adopt.sh — reconcile: every sudo-fleet agent in the cluster is
# hired in Paperclip. This is what makes Paperclip NATIVE to sudo-fleet rather
# than a manual step.
#
# Called by bin/k8s-up.sh (after the router pair is up), by the factory up.sh
# scripts (right after one agent is stood up), and by bin/k8s-auto-up.sh on
# every boot — so a brand-new agent is hired the moment it exists, and a
# cluster that comes back from a reboot re-hires anything missing.
#
# Safe to run any time: if Paperclip is not installed in this cluster it exits
# 0 with a note (a fleet without the control plane is still a valid fleet).
#
# Usage: bash bin/paperclip-adopt.sh [--namespace sudo-fleet] [--quiet]

FLEET_HOME="${FLEET_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CRED="/logs/paperclip/paperclip.env"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
NS=""
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --quiet)     QUIET=1; shift ;;
    *) echo "Usage: bash bin/paperclip-adopt.sh [--namespace <ns>] [--quiet]" >&2; exit 1 ;;
  esac
done

export KUBECONFIG="$KUBECONFIG_PATH"

if [[ ! -f "$CRED" ]]; then
  [[ "$QUIET" == "1" ]] || echo "→ Paperclip not installed in this cluster ($CRED missing) — skipping auto-hire"
  exit 0
fi
if ! kubectl get ns "${NS:-paperclip}" >/dev/null 2>&1 2>/dev/null; then
  [[ "$QUIET" == "1" ]] || echo "→ namespace paperclip missing — run bin/paperclip-up.sh to install the control plane"
  exit 0
fi

# Every agent deployment carries the label the factory sets: app=sudo-letta or
# app=sudo-agent, plus agent=<name>. Search ALL namespaces (the factories apply
# into whatever namespace the operator's kubeconfig selects).
mapfile -t ROWS < <(kubectl get deploy -A \
  -l 'app in (sudo-letta,sudo-agent)' \
  -o custom-columns='NS:.metadata.namespace,DEPLOY:.metadata.name,AGENT:.metadata.labels.agent' \
  --no-headers 2>/dev/null | grep -v '^<none>')

if [[ "${#ROWS[@]}" -eq 0 ]]; then
  [[ "$QUIET" == "1" ]] || echo "→ no sudo-fleet agent deployments found — nothing to hire"
  exit 0
fi

_fail=0
for row in "${ROWS[@]}"; do
  read -r dns deploy agent <<<"$row"
  [[ -n "$deploy" ]] || continue
  if [[ -n "$NS" && "$dns" != "$NS" ]]; then continue; fi
  lname="${agent:-${deploy#sudo-}}"
  # Paperclip display name: the agent label with its first letter capitalised.
  pname="$(printf '%s' "$lname" | sed -E 's/^(.)/\U\1/')"
  if [[ "$QUIET" == "1" ]]; then
    bash "$FLEET_HOME/bin/paperclip-hire.sh" --name "$pname" --deploy "$deploy" \
      --namespace "$dns" >/dev/null 2>&1 || _fail=$((_fail + 1))
  else
    echo ""
    echo "── adopting $dns/$deploy as Paperclip agent '$pname' ──"
    bash "$FLEET_HOME/bin/paperclip-hire.sh" --name "$pname" --deploy "$deploy" \
      --namespace "$dns" || _fail=$((_fail + 1))
  fi
done

if [[ "$_fail" -gt 0 ]]; then
  echo "⚠ ${_fail} agent(s) could not be hired — see the errors above" >&2
  exit 1
fi
[[ "$QUIET" == "1" ]] || echo ""
[[ "$QUIET" == "1" ]] || echo "✓ all sudo-fleet agents are hired in Paperclip"
