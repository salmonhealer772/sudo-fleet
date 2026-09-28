# BUILD STEPS — persistence: PVC → glimor folder (hostPath)

> Branch `glimors`. These are build steps for forge: move agent persistent state out of k3s's auto-managed `local-path` storage and into a path **we** own, so "glimor = yaml + pvc folder" is literally true on disk. Spec'd from the live cluster (34 bound PVCs, all `local-path`).

## Ground truth (verified 2026-09-28)

- Every agent has a bound PVC `sudo-<name>-data`, 10Gi, `local-path` storage class (`reclaimPolicy: Delete`, `WaitForFirstConsumer`, it is the k3s **default** class).
- The PVCs are made by the k3s-shipped **`local-path-provisioner`** pod in `kube-system` (running 36d), reacting to the `PersistentVolumeClaim` stanza that `up.sh` embeds in every `deployments/<name>.yaml`.
- The physical data lives at `/var/lib/rancher/k3s/storage/pvc-<uuid>_default_sudo-<name>-data/` — k3s-managed, opaque UUID dirs, **deleted when the PVC is deleted** (`reclaimPolicy: Delete`).
- The factories' `deployments/` dirs (inside the repos) currently hold the yamls; `up.sh` sets `YAML_DIR="$REPO_DIR/deployments"`.

## Why this change

`local-path` + `reclaimPolicy: Delete` means an agent's state is only as safe as the PVC staying bound. Delete the PVC (or `rm-containers.sh`) and k3s deletes the host dir — the agent's brain is gone, nothing owns a copy. That is exactly the "memory-only" risk the steering law exists to kill, except at the PVC layer.

The fix: stop letting k3s own the storage path. Put the state in a directory we control — `sudo-fleet/deployments/<name>/pvc/` — via a **`hostPath` volume**. Then the glimor is literally a folder we can see, copy, and back up.

## The change (one concept, both factories)

Replace the `PersistentVolumeClaim` + `persistentVolumeClaim` volume with a **`hostPath`** volume:

**Current (sudo-letta/up.sh ~line 150 and 225, sudo-agent/up.sh ~line 181 and 278):**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $DEPLOY-data
  labels:
    app: sudo-letta
    agent: $NAME
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
---
# ... deployment ...
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: $DEPLOY-data
```

**Target:**

```yaml
# (PVC stanza removed entirely)
# ... deployment ...
      volumes:
      - name: data
        hostPath:
          path: /opt/0-0/sudo-fleet/deployments/$NAME/pvc
          type: DirectoryOrCreate
```

- Planners keep mounting `data` at `/home/node/.letta`; engineers at `/opt/data`. **No mountPath change** — only the volume source changes.
- `type: DirectoryOrCreate` makes kube create the dir on first run (the "as-used" trigger, same as `WaitForFirstConsumer` gave us).
- The `docker-sock` and (engineer) `config` `hostPath` volumes already exist and stay as-is — this is only the `data` volume.

## The resulting glimor layout

```
/opt/0-0/sudo-fleet/deployments/
├── fa-glm-l/
│   ├── fa-glm-l.yaml          ← up.sh writes it here now (not $REPO_DIR/deployments)
│   └── pvc/                   ← hostPath: the agent's live state, on a path WE own
│       ├── persona.md / SOUL.md
│       ├── memory / messages / skills
│       └── watch/ (events.jsonl, transcript.txt, state.json)
├── fa-glm-h/
│   ├── fa-glm-h.yaml
│   └── pvc/
└── ...
```

One folder = one glimor = yaml + pvc, both on paths we control.

## What this changes and what it doesn't

- **Changes:** storage moves from `/var/lib/rancher/k3s/storage/pvc-<uuid>_.../` to `/opt/0-0/sudo-fleet/deployments/<name>/pvc/`. The PVC stanza is gone; no more `local-path` provisioning for agent state. State survives PVC deletion (kube won't delete a `hostPath` dir).
- **Doesn't change:** the mount path inside the pod (`/home/node/.letta` / `/opt/data`), the agent's view of its own files, the sidecars, the image, the ports.
- **New responsibility (ours):** nothing auto-cleans a `hostPath` dir. `rm-containers.sh`'s `kubectl delete pvc` must become an explicit `rm -rf` of the `pvc/` dir *when and only when* teardown is intended (and only after a glimor save/backup). This is the destroy button moving from kube to us — intentional.

## Two build steps for forge

1. **Retarget the yaml write + the storage volume.** In both `up.sh`: change `YAML_DIR` to write under `/opt/0-0/sudo-fleet/deployments/$NAME/`, remove the PVC stanza, and change the `data` volume from `persistentVolumeClaim` to `hostPath: {path: /opt/0-0/sudo-fleet/deployments/$NAME/pvc, type: DirectoryOrCreate}`.
2. **Fix teardown.** In both `rm-containers.sh` (and `down.sh` if separate): replace `kubectl delete pvc "$DEPLOY-data"` with an explicit, guarded removal of `/opt/0-0/sudo-fleet/deployments/$NAME/pvc` — and only after confirming a glimor save exists. Never delete a `pvc/` dir whose agent hasn't been saved.

## Open / to confirm before building

- **`/opt/0-0` vs `sudo-fleet` naming:** the operator is using them interchangeably ("0-0 = the fleet dir"). The path above is `/opt/0-0/sudo-fleet/deployments/<name>/pvc`. If the fleet home is instead meant to be the `sudo-fleet` repo *itself* (and `sudo-fleet/deployments/` is relative to the repo root), adjust the base once. This doc assumes the app dir is `/opt/0-0/` with `sudo-fleet/` as a subdir (matches the GLIMORS.md operational spine).
- **Is the deployments tree still git-tracked?** `glimors` are runtime state; if `deployments/<name>/pvc/` sits inside the `sudo-fleet` git repo, the `.gitignore` must exclude `pvc/` (state) while keeping `*.yaml` (wiring) tracked. Confirm which, since storing live agent memory in git is a leak risk.
