"""Tests for the task-planning tool (features/task-planning.feature).

Deterministic and PURE: no network, no filesystem, no fixtures needed.
"""

from tools.task_planning import ChildTask, plan, plan_children


def test_plan_returns_markdown_with_title_and_plan():
    issue = "My Issue\n\n## Step 1\nOwner: fa-glm-l\n\n## Step 2"
    result = plan(issue)
    assert result.startswith("# My Issue")
    assert "## Plan" in result
    assert "### T1: Step 1" in result
    assert "### T2: Step 2" in result


def test_plan_children_returns_child_tasks():
    issue = "My Issue\n\n## Step 1\n\n## Step 2"
    children = plan_children(issue)
    assert len(children) == 2
    assert children[0].title == "Step 1"
    assert children[1].title == "Step 2"
    assert children[0].id == "T1"
    assert children[1].id == "T2"


def test_owner_and_hint_parsed():
    issue = "Brief\n\n## Build it\nOwner: fa-glm-l\nHint: check env\nBody here"
    children = plan_children(issue)
    assert len(children) == 1
    assert children[0].owner == "fa-glm-l"
    assert children[0].hint == "check env"

    result = plan(issue)
    assert "Owner: fa-glm-l" in result
    assert "Hint: check env" in result


def test_acceptance_criteria_from_checkboxes():
    issue = "Brief\n\n## Deploy\n- [ ] deploy the fix\n- [ ] test it"
    children = plan_children(issue)
    assert len(children) == 1
    assert children[0].acceptance == ["deploy the fix", "test it"]

    result = plan(issue)
    assert "- [ ] deploy the fix" in result
    assert "- [ ] test it" in result


def test_blockers_captured():
    issue = "Brief\n\n## Deploy\nBlocker: waiting on API key"
    children = plan_children(issue)
    assert len(children) == 1
    assert children[0].blockers == ["waiting on API key"]

    result = plan(issue)
    assert "Blockers: waiting on API key" in result


def test_plan_is_pure_and_deterministic():
    issue = "Brief\n\n## Step 1\nOwner: fa-glm-l"
    result1 = plan(issue)
    result2 = plan(issue)
    assert result1 == result2
    # Also verify plan_children is pure (no mutation across calls)
    children1 = plan_children(issue)
    children2 = plan_children(issue)
    assert [c.to_dict() for c in children1] == [c.to_dict() for c in children2]


def test_empty_issue_default_title():
    result = plan("")
    assert result.startswith("# Implementation Plan")


def test_plan_children_returns_childtask_objects():
    issue = "Brief\n\n## Step 1\n\n## Step 2"
    children = plan_children(issue)
    assert all(isinstance(c, ChildTask) for c in children)
    for child in children:
        d = child.to_dict()
        assert set(d.keys()) == {"id", "title", "owner", "hint", "blockers",
                                  "acceptance", "children"}


def test_nested_sections_become_children():
    issue = "Brief\n\n## Phase 1\n### Sub-task A\nOwner: fa-glm-l"
    children = plan_children(issue)
    assert len(children) == 1
    assert children[0].title == "Phase 1"
    assert len(children[0].children) == 1
    assert children[0].children[0].title == "Sub-task A"
    assert children[0].children[0].owner == "fa-glm-l"

    result = plan(issue)
    assert "### T1: Phase 1" in result
    assert "### T2: Sub-task A" in result


def test_checkbox_acceptance_in_plan_renders():
    issue = "Brief\n\n## Test it\n- [ ] tests pass\n- [ ] coverage 80%"
    result = plan(issue)
    assert "### T1: Test it" in result
    assert "Acceptance:" in result
    assert "- [ ] tests pass" in result
    assert "- [ ] coverage 80%" in result
