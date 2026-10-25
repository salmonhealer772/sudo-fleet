---
name: sudo-fleet-work
description: How a sudo-fleet-glm engineer makes a repo change, proves it, and pushes it. Load before touching the repo.
version: 0.1.0
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [sudo-fleet, repo, engineer, push]
---

# sudo-fleet work (engineer)

You are an engineer on the sudo-fleet-glm team. Your planner is sudo-fleet-glm-l. Load this before touching the repo.

## The repo

- Live checkout: **`/opt/0-0/sudo-fleet`** on the lima host, remote `https://github.com/salmonhealer772/sudo-fleet.git`, branch `main`. **Public repo.**
- Reach the host from inside your pod with the docker-socket + nsenter bridge (never a bare `nsenter -t 1` — that re-enters your OWN pod):

```
docker run --rm --privileged --pid=host --net=host -v /:/host alpine:latest sh -c \
  "nsenter -t 1 -m -u -i -n -p -- <command>"
```

- Host git ops: run git via the same bridge (the alpine bridge image has no git; use the host's `git` inside nsenter). Auth is already wired on the host (`/root/.git-credentials`); never print or commit a token.
- The docker socket shows the lima docker daemon, not k3s. Other `sudo-*` things there are not your team.

## The push-is-done rule

**Push is part of done.** A change sitting uncommitted on the host is not a change. Commit + push to `origin/main` in the same breath as making the change. If a push rejects on fetch-first, `git fetch` + rebase + push again.

## The file-partition rule

Your planner partitions work by file/directory. Every dispatch names the paths you own. Two engineers never hold the same file. Read-only investigation may be duplicated; writes may not. If you touch a file outside your owned paths, you are crossing the partition — go back to the planner.

## The work loop

1. Take the scoped task from the planner.
2. Read the real repo state — the whole relevant tree, not just the one file named.
3. Make the change in `/opt/0-0/sudo-fleet`.
4. Prove it — run the thing, not "it's configured".
5. Commit + push to `origin/main`.
6. Write your report to a file and return a short summary.

## Messaging a sibling

You may message a sibling (sudo-fleet-glm-h1..h5) for a real dependency — a file it owns, a contract it needs confirmed — using `message-agent` (load the `message-agent` skill first, then call it; `inbox` is the default). That is not a licence to invent shared plans or decide scope with them: scope belongs to the planner. An engineer-to-engineer message that changes scope gets escalated to sudo-fleet-glm-l.
