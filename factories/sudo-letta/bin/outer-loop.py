#!/usr/bin/env python3
"""
outer-loop.py - "outer loop" auto-prompt wrapper around the sudo-letta prompt
primitive (letta-p.py) for the Marc agent (deployment sudo-marc) on the
sudo-fleet VM.

WHAT IT DOES
------------
Runs Marc once. The moment that run exits, it immediately runs Marc AGAIN with a
re-injection prompt that (a) restates the fixed OUTER GOAL, (b) states the
current iteration number, (c) summarizes the most recent completions, and
(d) tells Marc to continue toward the goal WITHOUT repeating completed steps.

This is NOT a fixed cron interval: each new run fires as soon as the previous
run ends.

    iter 1: <outer goal>                                  -> reply 1
    iter 2: goal + "you finished: <reply 1>, continue"    -> reply 2
    iter 3: goal + "you finished: <reply 1..2>, continue" -> reply 3
    ... up to the iteration cap.

The prompt plumbing is NOT re-implemented here: we shell out to the existing,
already-verified primitive, feeding the prompt on stdin (avoids all shell-arg
quoting problems):

    cd <this script's dir> && python3 letta-p.py --marc      # resume same chat

This is a plain host-side process. It does not touch the kube cluster itself.

SAFETY RAILS (it is an autonomous loop)
---------------------------------------
  * --max-iterations N        hard cap (default 100) - cannot spin forever.
  * strictly sequential       letta-p.py is synchronous and we wait() on it, so
                              two runs can NEVER overlap.
  * --timeout S               per-run wall clock cap (default 1800s); a hung run
                              is killed instead of blocking the loop forever.
  * --max-consecutive-failures abort after N back-to-back failures (default 3)
                              so a broken cluster is not hammered.
  * exclusive flock           a second outer-loop cannot start on the same log.
  * every reply appended      to /logs/marc-outer-loop/marc-outer-loop.log
                              (fleet log rule: all logs live under /logs/).
  * SIGINT/SIGTERM            clean stop; the log is flushed and closed.

USAGE
-----
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # smoke test: 3 iterations against a trivial goal
    python3 outer-loop.py \
        --goal "Keep a counter. Reply with exactly: COUNTER=<n>, n starting at 1 and incrementing each iteration." \
        --max-iterations 3

    # long-running, goal from the environment
    OUTER_GOAL="keep improving the docs" nohup python3 outer-loop.py --max-iterations 100 &

    # see the prompts without calling Marc
    python3 outer-loop.py --goal "..." --max-iterations 3 --dry-run

systemd (do NOT enable until you actually mean to run it):
    [Service]
    Environment=KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    Environment=OUTER_GOAL=continue your assigned work
    ExecStart=/usr/bin/python3 /root/sudo-fleet/factories/sudo-letta/bin/outer-loop.py --max-iterations 100
    Restart=on-failure
"""

import argparse
import fcntl
import os
import signal
import subprocess
import sys
import time
from collections import deque
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

DEFAULT_AGENT = "marc"
DEFAULT_MAX_ITERATIONS = 100
DEFAULT_PER_RUN_TIMEOUT = 1800      # 30 min per Marc run
DEFAULT_RECENT = 5                  # how many past completions to re-inject
DEFAULT_SLEEP = 2.0                 # small inter-iteration guard gap
DEFAULT_MAX_FAILURES = 3            # consecutive failures before aborting
LOG_DIR = "/logs/marc-outer-loop"
LOG_FILE = os.path.join(LOG_DIR, "marc-outer-loop.log")
LOCK_FILE = os.path.join(LOG_DIR, ".outer-loop.lock")
DEFAULT_GOAL = (
    "Continue your assigned work, make concrete progress, and do not idle. "
    "If your goal is unclear, pick the single most useful next step and do it."
)
RECENT_REPLY_CHARS = 400            # truncate each stored completion

_log_fh = None
_stop = False


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg):
    """Print to stdout and append to the persistent log (both flushed)."""
    line = f"[{now()}] {msg}"
    print(line, flush=True)
    if _log_fh:
        _log_fh.write(line + "\n")
        _log_fh.flush()


def summarize(text):
    """Collapse a reply to a single truncated line for re-injection."""
    flat = " ".join((text or "").split())
    if len(flat) > RECENT_REPLY_CHARS:
        flat = flat[:RECENT_REPLY_CHARS].rstrip() + " ..."
    return flat or "(empty reply)"


def build_prompt(goal, iteration, max_iterations, recent):
    """Compose the re-injection prompt for this iteration."""
    lines = [
        f"[OUTER LOOP] iteration {iteration} of {max_iterations}",
        f"Outer goal: {goal}",
        "",
    ]
    if recent:
        lines.append("Progress so far (most recent completions, oldest first):")
        for it, summary in recent:
            lines.append(f"  - iteration {it}: {summary}")
        lines.append("")
        lines.append(
            "Continue toward the outer goal. Build on the progress above. "
            "Do NOT repeat steps that are already complete. Take the next "
            "concrete action and reply with a short summary of what you did."
        )
    else:
        lines.append(
            "This is the first iteration. Begin working toward the outer goal "
            "now: take a concrete first action and reply with a short summary "
            "of what you did."
        )
    return "\n".join(lines)


def run_once(agent, prompt, timeout):
    """Invoke the existing prompt primitive once. Returns (reply, ok, error)."""
    cmd = [sys.executable or "python3", "letta-p.py", f"--{agent}"]
    try:
        proc = subprocess.run(
            cmd,
            cwd=SCRIPT_DIR,
            input=prompt,              # prompt goes in on stdin
            capture_output=True,
            text=True,
            timeout=timeout,
            env=os.environ.copy(),
        )
    except subprocess.TimeoutExpired:
        return "", False, f"timed out after {timeout}s"
    except FileNotFoundError as exc:
        return "", False, f"cannot launch primitive: {exc}"
    if proc.returncode != 0:
        err = proc.stderr.strip() or f"exit code {proc.returncode}"
        return proc.stdout.strip(), False, err
    return proc.stdout.strip(), True, ""


def _handle_signal(signum, _frame):
    global _stop
    _stop = True
    log(f"received signal {signum}; will stop after the current run finishes")


def parse_args():
    ap = argparse.ArgumentParser(
        description="Outer-loop auto-prompt wrapper around letta-p.py (Marc).",
    )
    ap.add_argument("--goal", default=os.environ.get("OUTER_GOAL") or DEFAULT_GOAL,
                    help="the fixed outer goal to keep driving the agent toward "
                         "(default: $OUTER_GOAL, else a generic placeholder)")
    ap.add_argument("--agent", default=os.environ.get("OUTER_AGENT", DEFAULT_AGENT),
                    help=f"sudo-letta agent name (default: {DEFAULT_AGENT})")
    ap.add_argument("--max-iterations", type=int,
                    default=int(os.environ.get("OUTER_LOOP_MAX_ITERATIONS", DEFAULT_MAX_ITERATIONS)),
                    help=f"hard iteration cap (default: {DEFAULT_MAX_ITERATIONS})")
    ap.add_argument("--timeout", type=int,
                    default=int(os.environ.get("OUTER_LOOP_TIMEOUT", DEFAULT_PER_RUN_TIMEOUT)),
                    help=f"per-run wall-clock timeout in seconds (default: {DEFAULT_PER_RUN_TIMEOUT})")
    ap.add_argument("--sleep", type=float,
                    default=float(os.environ.get("OUTER_LOOP_SLEEP", DEFAULT_SLEEP)),
                    help=f"seconds to idle between runs (default: {DEFAULT_SLEEP})")
    ap.add_argument("--recent", type=int, default=DEFAULT_RECENT,
                    help=f"how many past completions to re-inject (default: {DEFAULT_RECENT})")
    ap.add_argument("--max-consecutive-failures", type=int,
                    default=int(os.environ.get("OUTER_LOOP_MAX_FAILURES", DEFAULT_MAX_FAILURES)),
                    help=f"abort after this many back-to-back failures (default: {DEFAULT_MAX_FAILURES})")
    ap.add_argument("--log", default=os.environ.get("OUTER_LOOP_LOG", LOG_FILE),
                    help=f"log file path (default: {LOG_FILE})")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the prompts and exit without calling the agent")
    return ap.parse_args()


def main():
    global _log_fh, _stop
    args = parse_args()

    # Make sure kubectl can find the cluster even in a bare environment.
    if not os.environ.get("KUBECONFIG") and os.path.exists("/etc/rancher/k3s/k3s.yaml"):
        os.environ["KUBECONFIG"] = "/etc/rancher/k3s/k3s.yaml"

    if not os.path.isdir(SCRIPT_DIR) or not os.path.exists(os.path.join(SCRIPT_DIR, "letta-p.py")):
        sys.exit(f"error: letta-p.py not found in {SCRIPT_DIR}")

    # --dry-run needs neither a log nor a lock.
    if args.dry_run:
        recent = deque(maxlen=args.recent)
        for iteration in range(1, args.max_iterations + 1):
            print("=" * 70)
            print(build_prompt(args.goal, iteration, args.max_iterations, recent))
            recent.append((iteration, f"(dry-run placeholder for iteration {iteration})"))
        return 0

    os.makedirs(os.path.dirname(args.log) or ".", exist_ok=True)

    # Exclusive advisory lock: only one outer-loop per log location.
    lock_fh = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(f"error: another outer-loop already holds {LOCK_FILE}")

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    _log_fh = open(args.log, "a")
    log("=" * 70)
    log(f"outer loop START agent={args.agent} max_iterations={args.max_iterations} "
        f"timeout={args.timeout}s sleep={args.sleep}s log={args.log}")
    log(f"outer goal: {args.goal}")

    recent = deque(maxlen=args.recent)
    consecutive_failures = 0
    exit_code = 0
    completed = 0

    for iteration in range(1, args.max_iterations + 1):
        if _stop:
            log("stop requested before next iteration; exiting")
            break

        prompt = build_prompt(args.goal, iteration, args.max_iterations, recent)
        log("-" * 70)
        log(f"ITERATION {iteration}/{args.max_iterations} START - prompt sent to {args.agent}:")
        for ln in prompt.splitlines():
            log(f"    | {ln}")

        started = time.time()
        reply, ok, err = run_once(args.agent, prompt, args.timeout)
        elapsed = time.time() - started

        if ok:
            completed += 1
            consecutive_failures = 0
            log(f"ITERATION {iteration}/{args.max_iterations} DONE in {elapsed:.1f}s - reply:")
            for ln in (reply or "(empty reply)").splitlines():
                log(f"    < {ln}")
            recent.append((iteration, summarize(reply)))
        else:
            consecutive_failures += 1
            log(f"ITERATION {iteration}/{args.max_iterations} FAILED in {elapsed:.1f}s: {err}")
            if reply:
                for ln in reply.splitlines():
                    log(f"    < {ln}")
            if consecutive_failures >= args.max_consecutive_failures:
                log(f"aborting: {consecutive_failures} consecutive failures "
                    f"(>= --max-consecutive-failures {args.max_consecutive_failures})")
                exit_code = 1
                break

        if iteration < args.max_iterations and not _stop:
            if args.sleep > 0:
                time.sleep(args.sleep)

    else:
        # for-loop ran to the cap without break
        pass

    reached_cap = (completed + consecutive_failures) >= args.max_iterations
    log("-" * 70)
    log(f"outer loop FINISHED: iterations_run={completed + consecutive_failures} "
        f"completed={completed} max_iterations={args.max_iterations} "
        f"reached_cap={reached_cap} exit_code={exit_code}")
    log("=" * 70)
    _log_fh.close()
    _log_fh = None
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
