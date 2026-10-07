"""Tests for the issue-triage tool (features/issue-triage.feature).

Deterministic on purpose: every case hands `triage` the exact issues and the
exact reference time it expects, so the decision ladder -- not the clock -- is
what is under test.
"""

import os
import sys
from datetime import datetime, timedelta, timezone

_TOOLS_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
if _TOOLS_DIR not in sys.path:
    sys.path.insert(0, _TOOLS_DIR)

from issue_triage import (  # noqa: E402  (after the path is set up)
    CLOSE,
    ESCALATE,
    REASSIGN,
    RESUME,
    UNBLOCK,
    triage,
)

NOW = datetime(2026, 10, 7, 12, 0, tzinfo=timezone.utc)


def _ago(hours):
    return (NOW - timedelta(hours=hours)).isoformat()


# --- one action per issue, in order ----------------------------------------


def test_one_action_per_issue_in_order():
    # Arrange
    issues = [
        {"id": "PC-1", "status": "blocked"},
        {"id": "PC-2", "status": "todo", "assignee": "marc"},
        {"id": "PC-3", "status": "done"},
    ]
    # Act
    actions = triage(issues, now=NOW)
    # Assert: one per issue, same order, nothing skipped
    assert [a.issue_id for a in actions] == ["PC-1", "PC-2", "PC-3"]
    assert len(actions) == len(issues)


def test_empty_inbox_returns_no_actions():
    assert triage([], now=NOW) == []


# --- close -----------------------------------------------------------------


def test_done_issue_closes():
    # Act
    action = triage([{"id": "PC-9", "status": "done"}], now=NOW)[0]
    # Assert
    assert action.action == CLOSE


def test_cancelled_issue_closes():
    action = triage([{"id": "PC-9", "status": "cancelled"}], now=NOW)[0]
    assert action.action == CLOSE


def test_duplicate_closes_and_names_the_original():
    # Act
    action = triage([{"id": "PC-10", "status": "todo",
                      "assignee": "marc", "duplicateOf": "PC-4"}], now=NOW)[0]
    # Assert
    assert action.action == CLOSE
    assert "PC-4" in action.reason


# --- blocked ---------------------------------------------------------------


def test_blocked_with_all_blockers_resolved_unblocks():
    # Arrange: every first-class blocker is done/cancelled
    issue = {"id": "PC-20", "status": "blocked", "assignee": "marc", "blockedBy": [
        {"id": "PC-11", "status": "done"},
        {"id": "PC-12", "status": "cancelled"},
    ]}
    # Act
    action = triage([issue], now=NOW)[0]
    # Assert
    assert action.action == UNBLOCK


def test_blocked_with_a_cancelled_blocker_unblocks():
    # Arrange: one blocker cancelled, one still open
    issue = {"id": "PC-21", "status": "blocked", "blockedBy": [
        {"id": "PC-13", "status": "cancelled"},
        {"id": "PC-14", "status": "in_progress"},
    ]}
    # Act
    action = triage([issue], now=NOW)[0]
    # Assert
    assert action.action == UNBLOCK


def test_blocked_free_text_only_escalates():
    # Arrange: no first-class blockers at all
    issue = {"id": "PC-22", "status": "blocked", "note": "blocked by the billing team"}
    # Act
    action = triage([issue], now=NOW)[0]
    # Assert
    assert action.action == ESCALATE


def test_blocked_with_an_open_blocker_resumes():
    # Arrange: a blocker is genuinely still in flight
    issue = {"id": "PC-23", "status": "blocked", "blockedBy": [
        {"id": "PC-15", "status": "in_progress"},
    ]}
    # Act
    action = triage([issue], now=NOW)[0]
    # Assert
    assert action.action == RESUME
    assert not action.wake
    assert "PC-15" in action.reason


def test_blocker_with_unknown_status_is_not_cleared():
    # Arrange: a bare blocker id -- status cannot be verified
    issue = {"id": "PC-24", "status": "blocked", "blockedByIssueIds": ["PC-16"]}
    # Act
    action = triage([issue], now=NOW)[0]
    # Assert: never clear a block you cannot verify
    assert action.action == RESUME


# --- in_review -------------------------------------------------------------


def test_in_review_without_reviewer_reassigns():
    # Arrange: no reviewer and no pending interaction = not a real review path
    issue = {"id": "PC-30", "status": "in_review", "assignee": "marc"}
    # Act
    action = triage([issue], now=NOW)[0]
    # Assert
    assert action.action == REASSIGN


def test_in_review_with_a_reviewer_resumes():
    # Arrange
    issue = {"id": "PC-31", "status": "in_review", "assignee": "marc",
             "reviewer": "ceasar"}
    # Act
    action = triage([issue], now=NOW)[0]
    # Assert
    assert action.action == RESUME
    assert not action.wake


def test_in_review_named_by_a_different_spelling_is_still_in_review():
    # Arrange: "In-Review" normalises to in_review
    issue = {"id": "PC-32", "status": "In-Review", "assignee": "marc"}
    # Act
    action = triage([issue], now=NOW)[0]
    # Assert
    assert action.action == REASSIGN


def test_in_review_with_a_pending_interaction_resumes():
    # Arrange
    issue = {"id": "PC-33", "status": "in_review", "assignee": "marc",
             "pendingInteraction": True}
    # Act
    action = triage([issue], now=NOW)[0]
    # Assert
    assert action.action == RESUME


# --- in_progress / todo ----------------------------------------------------


def test_stale_in_progress_wakes_the_assignee():
    # Arrange: quiet for 30h, no live continuation
    issue = {"id": "PC-40", "status": "in_progress", "assignee": "marc",
             "updatedAt": _ago(30)}
    # Act
    action = triage([issue], now=NOW)[0]
    # Assert: resume, but as a wake
    assert action.action == RESUME
    assert action.wake is True


def test_stale_in_progress_with_a_live_continuation_is_left_alone():
    # Arrange: quiet, but something is actually still running
    issue = {"id": "PC-41", "status": "in_progress", "assignee": "marc",
             "updatedAt": _ago(30), "liveContinuation": True}
    # Act
    action = triage([issue], now=NOW)[0]
    # Assert
    assert action.action == RESUME
    assert action.wake is False


def test_fresh_in_progress_resumes_quietly():
    # Arrange: updated 5 minutes ago
    issue = {"id": "PC-42", "status": "in_progress", "assignee": "marc",
             "updatedAt": _ago(0.1)}
    # Act
    action = triage([issue], now=NOW)[0]
    # Assert
    assert action.action == RESUME
    assert action.wake is False


def test_in_progress_without_a_timestamp_is_not_manufactured_into_a_wake():
    # Arrange: no timestamp at all -- "cannot tell" is not "stale"
    issue = {"id": "PC-43", "status": "in_progress", "assignee": "marc"}
    # Act
    action = triage([issue], now=NOW)[0]
    # Assert
    assert action.wake is False


def test_assigned_todo_is_woken():
    # Arrange: assigned but not progressing
    issue = {"id": "PC-44", "status": "todo", "assignee": "marc"}
    # Act
    action = triage([issue], now=NOW)[0]
    # Assert
    assert action.action == RESUME
    assert action.wake is True


def test_workable_issue_without_an_assignee_reassigns():
    # Act / Assert
    assert triage([{"id": "PC-45", "status": "todo"}], now=NOW)[0].action == REASSIGN
    assert triage([{"id": "PC-46", "status": "in_progress",
                    "updatedAt": _ago(0.1)}], now=NOW)[0].action == REASSIGN


# --- escalate / purity -----------------------------------------------------


def test_unknown_status_escalates():
    # Act
    action = triage([{"id": "PC-50", "status": "banana"}], now=NOW)[0]
    # Assert
    assert action.action == ESCALATE


def test_missing_status_escalates():
    action = triage([{"id": "PC-51"}], now=NOW)[0]
    assert action.action == ESCALATE


def test_actions_are_serialisable_and_always_in_the_vocabulary():
    from issue_triage import ACTIONS

    issues = [
        {"id": "PC-60", "status": "done"},
        {"id": "PC-61", "status": "blocked"},
        {"id": "PC-62", "status": "todo", "assignee": "marc"},
        {"id": "PC-63", "status": "in_review", "assignee": "marc"},
    ]
    actions = triage(issues, now=NOW)
    for action in actions:
        assert action.action in ACTIONS
        assert set(action.as_dict()) == {"issue_id", "action", "reason", "wake"}


def test_triage_is_pure_and_repeatable():
    # Arrange
    issues = [
        {"id": "PC-70", "status": "in_progress", "assignee": "marc",
         "updatedAt": _ago(30)},
        {"id": "PC-71", "status": "blocked", "blockedBy": [{"id": "PC-1", "status": "done"}]},
    ]
    snapshot = [dict(issue) for issue in issues]
    # Act
    first = triage(issues, now=NOW)
    second = triage(issues, now=NOW)
    # Assert: same decisions, and the input was not mutated
    assert [a.as_dict() for a in first] == [a.as_dict() for a in second]
    assert issues == snapshot
