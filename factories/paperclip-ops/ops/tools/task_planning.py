"""task-planning -- turn an issue into a structured implementation plan.

Contract:  docs/task-planning-CONTRACT.md
Behavior:  features/task-planning.feature
Interface: tests/test_task_planning.py (pure, deterministic)

This tool is PURE: no network, no filesystem, no side effects.

`plan(issue)` takes a plain-text issue string (a GitHub issue body, a
task brief, any unstructured request) and returns a markdown plan
document plus a structured child-task list. The plan is a child task
graph where every leaf is small enough to be a single session, every
non-leaf is a roll-up, every task carries an owner/hint, a blocker
status, and acceptance criteria. The structured child list is the same
data as JSON-serializable dicts for machine consumption.

Naming follows the comm layer convention: the function is `plan`, the
module is `task_planning`, the docs are `*-CONTRACT.md`.
"""

from __future__ import annotations

import re
from typing import Any


# --- structured types -------------------------------------------------------


class ChildTask:
    """One node in the plan's child task graph."""

    def __init__(self, id: str, title: str, owner: str = "", hint: str = "",
                 blockers: list[str] | None = None,
                 acceptance: list[str] | None = None,
                 children: list["ChildTask"] | None = None) -> None:
        self.id = id
        self.title = title
        self.owner = owner
        self.hint = hint
        self.blockers = list(blockers) if blockers else []
        self.acceptance = list(acceptance) if acceptance else []
        self.children = list(children) if children else []

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "title": self.title,
            "owner": self.owner,
            "hint": self.hint,
            "blockers": list(self.blockers),
            "acceptance": list(self.acceptance),
            "children": [c.to_dict() for c in self.children],
        }

    def is_leaf(self) -> bool:
        return not self.children


# --- helpers ----------------------------------------------------------------


def _strip_checkbox(line: str) -> str:
    """Strip leading `- [ ]` / `- [x]` marker and surrounding whitespace."""
    return re.sub(r"^-\s*\[[ xX]?\]\s*", "", line.strip())


def _owned_block(block: str) -> tuple[str, str, str]:
    """Parse one markdown block into (owner, hint, body).

    A block may start with `Owner: name` on its first line and/or a
    `Hint: ...` line. Everything after those metadata lines is the body.
    Returns ("", "", body) if no metadata is present.
    """
    owner = ""
    hint = ""
    lines = block.strip().splitlines()
    body_lines: list[str] = []
    for line in lines:
        m = re.match(r"^Owner:\s*(.+)$", line)
        if m:
            owner = m.group(1).strip()
            continue
        m = re.match(r"^Hint:\s*(.+)$", line)
        if m:
            hint = m.group(1).strip()
            continue
        body_lines.append(line)
    return owner, hint, "\n".join(body_lines).strip()


# --- the tool ----------------------------------------------------------------


def plan(issue: str) -> str:
    """Turn an issue into a structured implementation plan (markdown).

    PURE: no network, no filesystem, no side effects.

    Parses the issue for:
    - A top-level title (first non-empty line, stripped of `#` markers).
    - Sections headed by `## <title>` which become child tasks.
    - `Owner: name`, `Hint: ...`, and `- [ ]` checkbox lines inside each
      section, which populate owner/hint/acceptance respectively.

    Returns a markdown plan document. The same data is available as a
    structured child list via `plan_children(issue)`.
    """
    _id_counter["n"] = 0
    children = plan_children(issue)
    return _render_plan(issue, children)


def plan_children(issue: str) -> list[ChildTask]:
    """Return the structured child-task list parsed from an issue.

    PURE. Each child task's title is derived from the issue's `##`
    sections. Owner/hint come from `Owner:`/`Hint:` lines. Acceptance
    criteria come from `- [ ]` checklist lines. Nested sections (`###`)
    become the child's own children recursively.
    """
    lines = issue.splitlines()
    title_line = lines[0].strip().lstrip("#").strip() if lines else ""
    body_lines = lines[1:] if lines else []
    if not title_line:
        title_line = "Implementation Plan"

    # Reset the id counter for each call so ids start at T1.
    _id_counter["n"] = 0

    sections = _parse_sections(body_lines)
    if sections:
        return [_section_to_task(s) for s in sections]

    return _fallback_tasks(body_lines, title_line)


def _parse_sections(lines: list[str]) -> list[dict[str, Any]]:
    """Group lines into `## ` sections. Returns empty if no `##` found."""
    sections: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    for line in lines:
        if line.strip().startswith("## "):
            if current is not None:
                sections.append(current)
            title = line.strip()[3:].strip()
            current = {"title": title, "body": []}
        elif current is not None:
            current["body"].append(line)
    if current is not None:
        sections.append(current)
    return sections


def _section_to_task(section: dict[str, Any]) -> ChildTask:
    """Convert a parsed `##` section into a ChildTask.

    Assigns the parent's id BEFORE processing children so the parent
    gets a lower id than any of its descendants.
    """
    body = "\n".join(section["body"])
    # Reserve an id for this task first so the parent always has a
    # lower id than any child processed within its body.
    task_id = _next_id(section["title"])
    acceptance, blockers, sub_children, owners, hints = _parse_body_lines(body)
    final_owner = owners[0] if owners else ""
    final_hint = hints[0] if hints else ""
    return ChildTask(
        id=task_id,
        title=section["title"],
        owner=final_owner,
        hint=final_hint,
        blockers=blockers,
        acceptance=acceptance,
        children=sub_children,
    )


def _parse_body_lines(body: str) -> tuple[list[str], list[str], list[ChildTask]]:
    """Extract acceptance criteria, blockers, hints, owners, and nested tasks from body."""
    acceptance: list[str] = []
    blockers: list[str] = []
    hints: list[str] = []
    owners: list[str] = []
    sub_sections: list[dict[str, Any]] = []
    in_sub: bool = False

    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith("### "):
            sub_sections.append({"title": stripped[4:].strip(), "body": []})
            in_sub = True
        elif in_sub and sub_sections:
            sub_sections[-1]["body"].append(line)
        elif stripped.startswith("- [ ]") or stripped.startswith("- [x]"):
            acceptance.append(_strip_checkbox(stripped))
        elif stripped.startswith("Blocker:"):
            blockers.append(stripped[len("Blocker:"):].strip())
        elif stripped.startswith("Hint:"):
            hints.append(stripped[len("Hint:"):].strip())
        elif stripped.startswith("Owner:"):
            owners.append(stripped[len("Owner:"):].strip())
        elif in_sub and sub_sections and not stripped.startswith("### "):
            # Non-matching lines inside a sub-section are preserved
            # so _owned_block can parse Owner:/Hint: from the sub-body.
            sub_sections[-1]["body"].append(line)

    sub_children = [_section_to_task(s) for s in sub_sections]
    return acceptance, blockers, sub_children, owners, hints


def _fallback_tasks(lines: list[str], title: str) -> list[ChildTask]:
    """When no `##` sections: each `- **Title**:` bullet becomes a task."""
    tasks: list[ChildTask] = []
    current_body: list[str] = []
    current_title: str = ""

    for line in lines:
        m = re.match(r"^-\s+\*\*(.+?)\*\*:", line)
        if m and current_title:
            tasks.append(_build_fallback_task(current_title, current_body))
            current_body = []
            current_title = m.group(1).strip()
        elif m and not current_title:
            current_title = m.group(1).strip()
        else:
            current_body.append(line)

    if current_title:
        tasks.append(_build_fallback_task(current_title, current_body))
    return tasks if tasks else [ChildTask(id=_next_id(title), title=title)]


def _build_fallback_task(title: str, body_lines: list[str]) -> ChildTask:
    owner, hint, body = _owned_block("\n".join(body_lines))
    acceptance, blockers, sub_children = _parse_body_lines(body)
    return ChildTask(
        id=_next_id(title),
        title=title,
        owner=owner,
        hint=hint,
        blockers=blockers,
        acceptance=acceptance,
        children=sub_children,
    )


_id_counter: dict[str, int] = {"n": 0}


def _next_id(title: str) -> str:
    """Generate a task id like T1, T2, ... per call (resets per plan)."""
    _id_counter["n"] += 1
    return f"T{_id_counter['n']}"


def _render_plan(issue: str, children: list[ChildTask]) -> str:
    """Render the issue + child tasks into a markdown plan document."""
    title_line = issue.splitlines()[0].strip().lstrip("#").strip() if issue.strip() else "Implementation Plan"
    if not title_line:
        title_line = "Implementation Plan"

    out: list[str] = [
        f"# {title_line}",
        "",
        "> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.",
        "",
        "## Plan",
        "",
    ]
    for child in children:
        out.append(_render_task(child, depth=0))
        out.append("")
    return "\n".join(out)


def _render_task(task: ChildTask, depth: int = 0) -> str:
    """Render one task and its children recursively."""
    indent = "  " * depth
    lines: list[str] = [f"{indent}### {task.id}: {task.title}", ""]
    if task.owner:
        lines.append(f"{indent}Owner: {task.owner}")
    if task.hint:
        lines.append(f"{indent}Hint: {task.hint}")
    if task.blockers:
        lines.append(f"{indent}Blockers: {', '.join(task.blockers)}")
    if task.acceptance:
        lines.append(f"{indent}Acceptance:")
        for crit in task.acceptance:
            lines.append(f"{indent}- [ ] {crit}")
    if task.children:
        lines.append("")
        for child in task.children:
            lines.append(_render_task(child, depth=depth + 1))
            lines.append("")
    elif task.acceptance:
        lines.append("")
        lines.append(f"{indent}Done when every acceptance criterion above is met.")
    return "\n".join(lines)
