Feature: Turn an issue into a structured implementation plan

  The `plan` tool takes a plain-text issue (a task brief or issue body)
  and produces a structured implementation plan: a child task graph
  with owners, hints, blockers, and acceptance criteria. The tool is
  PURE — no network, no filesystem, no side effects.

  The same data is available as a structured child list via
  `plan_children(issue)`, each child a dict with id, title, owner, hint,
  blockers, acceptance, children.

  Background:
    Given a repo with the paperclip-ops/ops task-planning module available

  Scenario: Plan from a `##` sections issue
    Given the issue text has a title line and two `##` sections
    When I call `plan(issue)`
    Then the result is a markdown string starting with "# <title>"
    And it contains "## Plan"
    And it contains a heading for each `##` section title
    And `plan_children(issue)` returns two ChildTask objects
    And each child's title matches a `##` section

  Scenario: Owner and Hint lines are parsed
    Given the issue has a section with "Owner: fa-glm-l" and "Hint: check env"
    When I call `plan(issue)`
    Then the rendered plan contains "Owner: fa-glm-l"
    And the rendered plan contains "Hint: check env"
    And the corresponding ChildTask has owner "fa-glm-l" and hint "check env"

  Scenario: Acceptance criteria from checkboxes
    Given the issue has "- [ ] deploy the fix" and "- [ ] test it"
    When I call `plan(issue)`
    Then the rendered plan contains "- [ ] deploy the fix"
    And the corresponding ChildTask acceptance list has two entries

  Scenario: Blockers are captured
    Given the issue has "Blocker: waiting on API key"
    When I call `plan(issue)`
    Then the rendered plan contains "Blocker: waiting on API key"
    And the corresponding ChildTask blockers list contains it

  Scenario: plan() is pure and deterministic
    Given the same issue string
    When I call plan(issue) twice
    Then both results are identical strings

  Scenario: Empty issue gets a default title
    When I call plan("")
    Then the result starts with "# Implementation Plan"

  Scenario: plan_children returns ChildTask objects with to_dict
    Given any issue with sections
    When I call plan_children(issue)
    Then each child is a ChildTask instance
    And calling to_dict() on each child returns a dict with all expected keys

  Scenario: Nested sections become child-task children
    Given the issue has a `##` section containing a `###` subsection
    When I call plan_children(issue)
    Then the parent ChildTask has one child
    And that child's title matches the `###` section title
