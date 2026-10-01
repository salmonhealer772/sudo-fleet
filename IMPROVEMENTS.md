# sudo-fleet — Improvements Backlog

Running list of things to do. Each item gets broken into dispatchable parts
before it goes to an engineer. Status: [ ] todo · [/] in-progress · [x] done.

---

## 1. Consolidate the 3-repo system into one repo

The current split (sudo-fleet + sudo-agent + sudo-letta as three separate git
repos) is worse than a single repo. Roll sudo-agent and sudo-letta INTO
sudo-fleet so there is one repo, one entity.

- [ ] Merge sudo-agent into sudo-fleet
- [ ] Merge sudo-letta into sudo-fleet
- [ ] Separate out all the bins (scripts/binaries/entrypoints) into an organized
      structure — one clean, predictable layout instead of scattered under
      multiple repo roots
- [ ] Collapse the nested-clone flow in setup.sh (Command 1 currently clones
      sudo-agent + sudo-letta at runtime; with one repo they are already present)
- [ ] Update README + SPEC + all cross-repo references (paths, URLs) to the
      single-repo layout

## 2. Better comments on all the scripts

Every script (setup.sh, k8s-up.sh, k8s-down.sh, the factory up.sh/down.sh,
mcp_entrypoint.sh, the watch sidecars, etc.) needs richer inline documentation.

- [ ] More sub-comments, broken down per logical block
- [ ] Each comment states SPECIFICALLY what that part of the code does — not
      vague, line-level: "this block does X, because Y, and fails if Z"
- [ ] Call out the non-obvious/silent-failure-prone bits explicitly (sudo/TTY
      handling, swallowed errors, exit-code traps) so the next reader sees the
      intent, not just the mechanism


## 3. Backup / save scripts in kube-scripts/

We want first-class scripts that take a full backup of either the **entire
fleet** or **one agent**, so the fleet can be rebuilt exactly as it is. The
first fleet backup was done by hand by forge on 2026-10-01
(`/opt/backups/fleet-20261001-004811/`, report in forge's
`/opt/data/fleet-backup-result.md`). That procedure becomes a few scripts in
`sudo-fleet/kube-scripts/`.

- [x] Document exactly how forge took the 2026-10-01 backup (summary below;
      full detail + restore procedure in the backup's own MANIFEST.md)
- [ ] `kube-scripts/backup-agent.sh --<name>` — back up one agent (PVC data,
      its k8s objects, per-agent config, glimor if any)
- [ ] `kube-scripts/backup-fleet.sh` — back up every agent + cluster-wide
      objects + repo (git bundle) + images + MANIFEST.md
- [ ] Matching restore path (one agent / whole fleet), proven by a
      throwaway restore test
- [ ] Off-box copy (Google) with secrets (.env) excluded or encrypted

### How forge took the 2026-10-01 backup (the source spec for the scripts)

Read-only capture from the forge pod through the docker+nsenter host bridge —
no agent stopped, restarted or redeployed. Output:
`/opt/backups/fleet-<UTC ts>/` (7.1 GiB), with `backup.log` timestamping each phase.

1. **Phase 0 — cluster snapshot:** text listings of every object (`all-wide`,
   pods, deployments, pvcs, nodes) → `k8s/*.txt`, plus `agent-inventory.txt`
   (each agent's name, kind, image).
2. **Phase 1 — k8s yaml export:** `kubectl get -o yaml` of deployments, services,
   configmaps, pvcs, pvs, secrets, namespaces, nodes, kube-system, dashboard →
   `k8s/*.yaml`. Contains API keys in plaintext (deployment env) — sensitive.
3. **Phase 2/3 — per-PVC capture (all 42 PVCs):** read straight from the
   local-path storage root `/var/lib/rancher/k3s/storage/pvc-<uid>_<ns>_<name>`:
   - every sqlite `.db` gets a consistent `sqlite3 .backup` snapshot →
     `pvcs/<name>.sqlite.tar.gz`
   - the raw directory (db + wal + shm together) → `pvcs/<name>.tar.gz`
   - `sudo-letta-redis` has no PVC (ephemeral) — only its yaml is captured.
4. **Images:** `docker save | gzip` of sudo-agent, sudo-letta, hermes-agent
   (base), node:22-bookworm-slim, redis:7-alpine, alpine → `images/` +
   `digests.txt`.
5. **Repo:** `git bundle create --all` of sudo-fleet (all refs incl. stash), a
   working-tree tar (this is the ONLY place the gitignored `.env` secrets are
   captured), a glimors tar, and HEAD/branch refs → `repo/`.
6. **Integrity:** `SHA256SUMS` over every file (206), verified with
   `sha256sum -c`; `git bundle verify` must run from inside a git repo.
7. **Restore test:** fa-glm-h → throwaway `sudo-restoretest-h` and fa-glm-l →
   `sudo-restoretest-l`: `up.sh --<new>` → empty its PVC dir → `cp -a` the
   extracted tar in → `chown` (10000 hermes / 1000 letta) → `rollout restart`.
   Both came up 2/2 with the right identity (SOUL.md / persona.md,
   `lastAgent` pin) and `state.db` passed `integrity_check`; then fully deleted.
8. **MANIFEST.md:** contents, cluster facts, image digests, repo SHA, and the
   step-by-step restore (code+images, one agent, whole fleet).

**Gaps found:** no Google upload — no credentialed gcloud account or rclone
remote exists on lima or fabean; needs a GCS bucket + service-account key (or
`gcloud auth application-default login`), then `gsutil -m rsync`. `k8s/` and
`repo/` must be encrypted before any off-box copy. Whole-fleet restore (path C)
is derived from the tested per-agent path, not itself tested.

