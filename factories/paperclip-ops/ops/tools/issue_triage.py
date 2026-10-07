#!/usr/bin/env python3
"""issue-triage -- one next action per inbox issue. Pure, no network.

Contract:  docs/issue-triage-CONTRACT.md
Behavior:  features/issue-triage.feature
Interface: `triage(issues, now=None) -> list[Action]`, pinned by
           tests/test_issue_triage.py

Usage
    python3 tools/issue_triage.py issues.json        # a JSON list of issues
    cat issues.json | python3 tools/issue_triage.py -  # ...from stdin
    python3 tools/issue_triage.py issues.json --json   # machine-readable

`triage()` is a PURE function: it reads ONLY the issue mappings it is handed and
returns exactly one `Action` per issue, in the same order. No network, no disk,
no clock side-effects (`now` is injectable so tests are deterministic), and the
input is never mutated.

The five actions are the Paperclip triage verdicts collapsed to what you can
actually do next. `wake-needed` is a resume that carries a nudge -- see
`Action.wake` and docs/issue-triage-CONTRACT.md.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone

# --- the five actions ------------------------------------------------------

RESUME = "resume"        # the execution path is alive (or is woken) -- leave it running
REASSIGN = "reassign"    # there is no valid owner: no assignee, or a review path that is not real
UNBLOCK = "unblock"      # first-class blockers are resolved -- clear the block
ESCALATE = "escalate"    # needs a human/board, or the state cannot be classified in one pass
CLOSE = "close"          # terminal: complete, duplicate, or no longer relevant

ACTIONS = (RESUME, REASSIGN, UNBLOCK, ESCALATE, CLOSE)

# --- tuning ----------------------------------------------------------------

STALE_HOURS = 24

# Statuses that mean "this thread is over".
TERMINAL_STATUSES = frozenset({"done", "cancelled"})

# A blocker in one of these no longer blocks.
RESOLVED_STATUSES = frozenset({"done", "cancelled"})

# Statuses where somebody is (or should be) actively working the issue.
WORKABLE_STATUSES = frozenset({"todo", "in_progress", "in_review", "blocked"})

# Where a "last touched" timestamp might live, most-specific first.
ACTIVITY_KEYS = ("updatedAt", "lastActivityAt", "lastCommentAt", "lastUpdate")


@dataclass(frozen=True)
class Action:
    """The single next action for one issue.

    issue_id -- the issue's id/key, echoed back so a caller can zip it to the input
    action   -- one of ACTIONS
    reason   -- one line saying WHY, for the triage comment / summary
    wake     -- resume only: True when the assignee must be nudged (stalled),
                False for a quiet "let the heartbeat run"
    """

    issue_id: str
    action: str
    reason: str
    wake: bool = False

    def as_dict(self) -> dict:
        return asdict(self)


# --- the entry point -------------------------------------------------------


def triage(issues, now=None):
    """One `Action` per issue, in input order. See module docstring.

    `now` is the reference instant for staleness (default: the wall clock). Pass
    an explicit timezone-aware datetime for reproducible results.
    """
    reference = now if now is not None else datetime.now(timezone.utc)
    return [_decide(issue, reference) for issue in issues]


# --- the decision ladder ---------------------------------------------------


def _decide(issue, now):
    """Classify one issue. First matching rung wins; every rung is terminal."""
    issue_id = _issue_id(issue)
    status = _norm(issue.get("status"))

    # 0. already over -- nothing to triage, just close it out.
    if status in TERMINAL_STATUSES:
        return Action(issue_id, CLOSE, f"status is {status!r}: the thread is complete")
    if issue.get("duplicateOf"):
        return Action(issue_id, CLOSE,
                      f"duplicate of {issue['duplicateOf']}: close and point at the original")

    # 1. blocked -- the blocker list is the whole decision.
    if status == "blocked":
        return _blocked(issue_id, issue)

    # 2. in_review -- only a real review path may stay in review.
    if status == "in_review":
        return _in_review(issue_id, issue)

    # 3. workable (in_progress / todo) -- owner + liveness decide.
    if status in WORKABLE_STATUSES:
        return _workable(issue_id, status, issue, now)

    # 4. anything else -- do not guess.
    return Action(issue_id, ESCALATE,
                  f"unrecognised status {issue.get('status')!r}: cannot classify in one pass")


def _blocked(issue_id, issue):
    blockers = _blockers(issue)

    if not blockers:
        return Action(issue_id, ESCALATE,
                      "blocked with no first-class blockers (free-text only): "
                      "convert to blockedByIssueIds or name the one next action")

    if all(status in RESOLVED_STATUSES for _, status in blockers):
        return Action(issue_id, UNBLOCK,
                      "all first-class blockers are done/cancelled: clear the block "
                      "and let the assignee resume")

    if any(status == "cancelled" for _, status in blockers):
        return Action(issue_id, UNBLOCK,
                      "a first-class blocker was cancelled: remove/replace it in "
                      "blockedByIssueIds and resume")

    open_ids = ", ".join(bid for bid, status in blockers if status not in RESOLVED_STATUSES)
    return Action(issue_id, RESUME,
                  f"waiting on still-open blocker(s) {open_ids}: the "
                  f"blockers-resolved wake fires automatically, leave it alone")


def _in_review(issue_id, issue):
    if not issue.get("reviewer") and not issue.get("pendingInteraction"):
        return Action(issue_id, REASSIGN,
                      "in_review with no reviewer and no pending interaction: "
                      "the review path is not real, reassign it")
    return Action(issue_id, RESUME,
                  "in_review is with a reviewer / awaiting an interaction: "
                  "leave the review path alone")


def _workable(issue_id, status, issue, now):
    if not issue.get("assignee"):
        return Action(issue_id, REASSIGN,
                      f"{status} with no assignee: nothing is driving the issue")

    if _is_stale(issue, now):
        if issue.get("liveContinuation"):
            return Action(issue_id, RESUME,
                          f"{status} has been quiet for >{STALE_HOURS}h but a live "
                          f"continuation is running: let it finish")
        return Action(issue_id, RESUME,
                      f"stale {status} (>{STALE_HOURS}h, no comments or document "
                      f"updates, no monitor or queued continuation): wake the assignee",
                      wake=True)

    if status == "todo":
        return Action(issue_id, RESUME,
                      "assigned but not started: wake the assignee to pick it up",
                      wake=True)

    return Action(issue_id, RESUME,
                  "in_progress with a live execution path: let the heartbeat continue")


# --- helpers ---------------------------------------------------------------


def _issue_id(issue):
    for key in ("id", "issueId", "key", "number"):
        value = issue.get(key)
        if value is not None:
            return str(value)
    return "?"


def _norm(value):
    """Normalise a status for comparison: 'In-Review' and 'in_review' are one."""
    if value is None:
        return ""
    return str(value).strip().lower().replace("-", "_").replace(" ", "_")


def _blockers(issue):
    """First-class blockers as [(id, normalised_status), ...].

    Accepts `blockedBy` or `blockedByIssueIds`; an entry may be a mapping
    ({"id", "status"}) or a bare id. A bare id has unknown status, which counts
    as OPEN -- never clear a block you cannot verify.
    """
    raw = issue.get("blockedBy") or issue.get("blockedByIssueIds") or []
    blockers = []
    for entry in raw:
        if isinstance(entry, dict):
            blocker_id = _issue_id(entry)
            blockers.append((blocker_id, _norm(entry.get("status"))))
        else:
            blockers.append((str(entry), ""))
    return blockers


def _last_activity(issue):
    for key in ACTIVITY_KEYS:
        if issue.get(key) is not None:
            return _parse_time(issue[key])
    return None


def _parse_time(value):
    """A datetime, or an ISO-8601 string (a trailing 'Z' is accepted), or None."""
    if isinstance(value, datetime):
        parsed = value
    else:
        text = str(value).strip()
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            parsed = datetime.fromisoformat(text)
        except ValueError:
            return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _is_stale(issue, now):
    """Stale iff there IS a timestamp and it is older than STALE_HOURS.

    No timestamp means "cannot tell", which is NOT stale -- a missing field must
    never manufacture a wake.
    """
    last = _last_activity(issue)
    if last is None or now is None:
        return False
    return (now - last) > timedelta(hours=STALE_HOURS)


# --- rendering -------------------------------------------------------------


def render_table(actions):
    """The triage pass as a short per-issue list (the shape the skill asks for)."""
    if not actions:
        return "no issues to triage"

    id_width = max(len("issue"), *(len(a.issue_id) for a in actions))
    action_width = max(len("action"), *(len(a.action) for a in actions))
    lines = [
        f"{'issue':<{id_width}}  {'action':<{action_width}}  why",
        f"{'-' * id_width}  {'-' * action_width}  {'-' * 3}",
    ]
    for action in actions:
        lines.append(f"{action.issue_id:<{id_width}}  {action.action:<{action_width}}  {action.reason}")
    lines.append("")
    lines.append(render_summary(actions))
    return "\n".join(lines)


def render_summary(actions):
    """One line: how many issues, and how the pass broke down by action."""
    if not actions:
        return "0 issues"
    counts = {name: 0 for name in ACTIONS}
    for action in actions:
        counts[action.action] = counts.get(action.action, 0) + 1
    breakdown = ", ".join(f"{counts[name]} {name}" for name in ACTIONS if counts[name])
    wakes = sum(1 for action in actions if action.wake)
    suffix = f" ({wakes} need a wake)" if wakes else ""
    return f"{len(actions)} issue{'s' if len(actions) != 1 else ''}: {breakdown}{suffix}"


# --- CLI -------------------------------------------------------------------


def _read_issues(path):
    text = sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read()
    payload = json.loads(text)
    if isinstance(payload, dict):
        payload = payload.get("issues", [])
    return payload


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Decide the single next action for each issue in an inbox dump.",
        epilog="Input is a JSON list of issues (or {\"issues\": [...]}); "
               "'-' reads stdin.")
    parser.add_argument("path", help="path to a JSON issue dump, or '-' for stdin")
    parser.add_argument("--json", action="store_true",
                        help="print the actions as JSON instead of a table")
    args = parser.parse_args(argv)

    issues = _read_issues(args.path)
    actions = triage(issues)

    if args.json:
        print(json.dumps([a.as_dict() for a in actions], indent=2))
    else:
        print(render_table(actions))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
