Feature: Triage the Paperclip inbox into one next action per issue

  Triage exists to turn a noisy inbox into a small set of clear next actions.
  A triage pass takes a list of issues and returns, for each one, EXACTLY ONE
  action — resume, reassign, unblock, escalate, or close — so the caller never
  has to guess what happens next.

  The pass is a pure decision: same issues in, same actions out. It reaches no
  network, reads no clock of its own (the reference time is passed in), and
  never mutates the issues it was handed. That makes the decision reviewable
  and testable, and it means the tool can run anywhere the issues are already
  in hand.

  The five actions are the Paperclip triage verdicts collapsed to what you can
  actually do next. Where the skill says "wake-needed" (an assignee is stalled
  with no live continuation), the tool returns `resume` with `wake` set, which
  is the same verdict plus the instruction to nudge.

  Background:
    Given a list of issues, each with an id and a status
    And the statuses are todo, in_progress, in_review, blocked, done, or cancelled

  Scenario: Every issue gets exactly one action, in order
    Given an inbox of several issues
    When I call triage
    Then it returns one action per issue
    And the actions are in the same order as the issues
    And no issue gets two actions and no issue is skipped

  Scenario: A finished issue is closed
    Given an issue with status "done"
    When I call triage
    Then the action is "close"
    Because the thread is complete and must not be triaged again

  Scenario: A duplicate is closed and pointed at the original
    Given an open issue that carries "duplicateOf"
    When I call triage
    Then the action is "close"
    And the reason names the original issue

  Scenario: A blocked issue whose blockers are all resolved is unblocked
    Given a "blocked" issue with first-class blockers that are all "done" or "cancelled"
    When I call triage
    Then the action is "unblock"
    Because the block is stale and the assignee can resume

  Scenario: A blocked issue with a cancelled blocker is unblocked
    Given a "blocked" issue with one blocker "cancelled" and one still open
    When I call triage
    Then the action is "unblock"
    Because the cancelled blocker must be removed or replaced before the issue can move

  Scenario: A blocked issue with no first-class blockers is escalated
    Given a "blocked" issue whose block is only free text
    When I call triage
    Then the action is "escalate"
    Because there is nothing to check off and the blocker list must be made real

  Scenario: A blocked issue that is legitimately waiting resumes
    Given a "blocked" issue with at least one blocker still open
    When I call triage
    Then the action is "resume"
    Because the blockers-resolved wake fires automatically and re-triage would be noise

  Scenario: An in_review issue with no reviewer is reassigned
    Given an "in_review" issue with no reviewer and no pending interaction
    When I call triage
    Then the action is "reassign"
    Because the review path is not real

  Scenario: An in_review issue that is genuinely under review resumes
    Given an "in_review" issue with a reviewer or a pending interaction
    When I call triage
    Then the action is "resume"
    Because the review path is alive and must be left alone

  Scenario: A stale in_progress issue is woken
    Given an "in_progress" issue last updated more than 24 hours ago
    And it has no monitor and no queued continuation
    When I call triage
    Then the action is "resume"
    And the action is marked as a wake
    Because the assignee is stalled and must be nudged with the next concrete step

  Scenario: A stale in_progress issue with a live continuation is left alone
    Given an "in_progress" issue last updated more than 24 hours ago
    And a live continuation is running
    When I call triage
    Then the action is "resume"
    And the action is not a wake
    Because a long-running continuation is not a stall

  Scenario: A fresh in_progress issue resumes quietly
    Given an "in_progress" issue updated minutes ago
    When I call triage
    Then the action is "resume"
    And the action is not a wake
    Because the heartbeat is doing its job

  Scenario: Assigned but not progressing is woken
    Given a "todo" issue with an assignee that has not started
    When I call triage
    Then the action is "resume"
    And the action is marked as a wake

  Scenario: A workable issue with no assignee is reassigned
    Given a "todo" or "in_progress" issue with no assignee
    When I call triage
    Then the action is "reassign"
    Because nothing is driving the issue

  Scenario: An unknown status is escalated rather than guessed at
    Given an issue whose status is not one of the six known statuses
    When I call triage
    Then the action is "escalate"
    Because the tool never guesses a verdict it cannot justify

  Scenario: The pass is pure and repeatable
    Given the same issues and the same reference time
    When I call triage twice
    Then both passes return the same actions
    And the issues handed in are unchanged
