# Verification record — watch_sidecar.py self_pid_tree() /proc parse guard

- Date: 2026-10-11
- Repo: salmonhealer772/sudo-fleet (branch `main`)
- Change: in BOTH `watch_sidecar.py` copies, move the `/proc/<pid>/stat` parse in
  `self_pid_tree()` INSIDE the `try`/`except` and widen the guard to
  `(IndexError, ValueError, OSError)`.
  - `factories/sudo-agent/bin/watch_sidecar.py` (line ~622)
  - `factories/sudo-letta/bin/watch_sidecar.py` (line ~348)
- Bug: the parse ran OUTSIDE the guard, so a transiently-short `stat` line during
  process exit raised an uncaught `IndexError` and killed the monitor-loop worker
  thread (`IndexError: list index out of range` at `self_pid_tree`, then
  "worker thread died"). The worker feeds process-state/activity events, so the
  pod looked merely "restarting" rather than broken.

## RUNTIME

This change is NOT deployed. The fleet roll is deliberately withheld (the change
brief reserves the roll decision for the operator), so the runtime effect is
UNVERIFIED by design — no pod was recreated and no image was rebuilt.

Evidence gathered instead:

1. Live crash signature re-derived from the currently-deployed (pre-fix) image —
   the bug is real and firing:
   - `kubectl logs sudo-psnvc-76c5998b97-bt4dw -c watch --previous` -> IndexError
     at `/opt/letta-watch/watch_sidecar.py:348`, "worker thread died"
   - `kubectl logs sudo-ms-glm-h-55db59c8f9-hz5qz -c watch --previous` -> IndexError
     at `/opt/watch-sidecar/watch_sidecar.py:622`, "worker thread died"

2. Targeted reproduction (in-pod python3) with a simulated short stat line
   `"1234 (hermes) "` (the transient shape while a pid exits):
   - PRE-FIX expression (parse outside the guard): raises
     `IndexError: list index out of range` — the uncaught raise that kills the worker.
   - POST-FIX guarded form: no exception; the pid is skipped (returns None).
   - Empty string (the `_read_file` OSError fallback): no exception.
   Raw output:

```
simulated short stat line: '1234 (hermes) '
PRE-FIX  : IndexError raised  -> list index out of range   (this killed the worker)
POST-FIX : no exception, skipped pid (returned None)
POST-FIX : empty stat -> no exception (returned None)
```

3. Both edited files pass `python3 -m py_compile`.

## CONFIG

The committed source in both factories now guards the parse. The `git diff` for
this change is exactly the block below (identical shape in both files):

```
-        ppid = _read_file("/proc/%s/stat" % entry).split(")")[-1].split()[1]
         try:
+            # Parse INSIDE the guard: a transiently-short /proc/<pid>/stat
+            # during process exit must not escape (an uncaught IndexError
+            # here killed the monitor-loop worker thread).
+            ppid = _read_file("/proc/%s/stat" % entry).split(")")[-1].split()[1]
             if int(ppid) in tree:
                 tree.add(int(entry))
-        except (IndexError, ValueError):
+        except (IndexError, ValueError, OSError):
             pass
```

TIMING / DRIFT NOTE: `bin/watch_sidecar.py` is COPYed into the images, so this
change has NO runtime effect until the image is rebuilt + re-imported and the
pods are recreated via `kube-scripts/up.sh`. That rebuild/roll is NOT part of
this change; it is the operator's deferred decision. Until then the deployed
image still contains the unguarded parse.

## AUTH

Not applicable — this change touches no auth surface (no credentials, tokens,
roles, or access-control paths). No auth claim is altered.

## EXPOSURE

Not applicable — no Service, port, NodePort, or network path is added, changed,
or exposed by this change. The watch sidecar's existing loopback surface is
unchanged.

## Outcome

PASS (static + targeted reproduction). Runtime unverified because the change is
not deployed. No bypass of the pre-commit change-protocol hook.
