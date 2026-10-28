Feature: Summarize an agent's status into a short colloquial line

  summarize-status turns a status_input dict into a short, colloquial
  summary that OPENS with the 1-3 concrete next actions. PURE — no
  network, no side effects, deterministic.

  Background:
    Given the summarize-status module is available

  Scenario: Opens with the next actions when present
    Given a status_input with agent "planner", phase "running", and
      next_actions ["clear the stuck run", "fire a fresh ticket"]
    When I call summarize with that status_input
    Then the result starts with "Next for planner (running):"
    And the result contains "clear the stuck run; fire a fresh ticket"
    And the result contains "PROMPT (42 events"

  Scenario: A stuck agent opens with a stuck note instead
    Given a status_input with agent "planner", phase "running", stuck true,
      and empty next_actions
    When I call summarize with that status_input
    Then the result starts with "planner looks stuck in running."
    And the result does not contain "Next for"

  Scenario: No actions and not stuck reads "no pending actions"
    Given a status_input with agent "planner", phase "idle", empty
      next_actions, no last_event, and 0 events
    When I call summarize with that status_input
    Then the result contains "no pending actions"

  Scenario: Empty status_input degrades gracefully
    Given an empty status_input dict
    When I call summarize with that status_input
    Then the result contains "unknown"
    And the result is a string

  Scenario: A single next action has no semicolon separator
    Given a status_input with agent "planner", phase "ready", and
      next_actions ["restart the pod"]
    When I call summarize with that status_input
    Then the result contains "restart the pod"
    And the result does not contain "; "
