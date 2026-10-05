#!/usr/bin/env bash
set -euo pipefail

# bin/talk.sh — Talk to a sudo-agent running in Kubernetes
# Usage: bash bin/talk.sh --name

# Parse the --name flag, because the target pod is `deploy/sudo-$NAME`; an
# unrecognised arg aborts with usage instead of guessing.
NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name|--*)  NAME="${1#--}"; shift ;;
    *)           echo "Usage: bash bin/talk.sh --name" >&2; exit 1 ;;
  esac
done
# Reject an empty name (see down.sh — same reason: `sudo-` is not a real pod).
if [[ -z "$NAME" ]]; then
  echo "Usage: bash bin/talk.sh --name" >&2
  echo "Example: bash bin/talk.sh --alice" >&2
  exit 1
fi
# Refuse `--all`: talking to every agent at once is meaningless, and a bulk
# teardown (which `--all` implies to muscle memory) is rm-containers.sh's job.
if [[ "${NAME,,}" == "all" ]]; then
  echo "Use rm-containers.sh --ALL instead." >&2; exit 1
fi

# Auto-detect kubeconfig, because `sudo`/`su` changes $HOME and kubectl then
# loses the config it found at login; try the known k3s/operator paths in
# order so a plain `bash talk.sh --name` just works.
if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in "/etc/rancher/k3s/k3s.yaml" "/home/world15/.kube/config" "$HOME/.kube/config"; do
    if [[ -f "$cfg" ]]; then export KUBECONFIG="$cfg"; break; fi
  done
fi

# Attach an interactive TTY (`-it`) to the agent's `hermes` REPL, because this
# is a live conversation, not a one-shot; the TTY is what makes prompts and
# streaming replies render correctly. If the pod is not Ready, kubectl errors
# out (with its own message) — there is nothing to pre-check here.
kubectl exec -it "deploy/sudo-$NAME" -- hermes
