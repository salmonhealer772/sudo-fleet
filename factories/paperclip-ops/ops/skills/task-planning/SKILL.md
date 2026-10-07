---
name: task-planning
description: Turn an issue or task brief into a structured implementation plan — a child task graph with owners, hints, blockers, and acceptance criteria. Use when handed an unstructured task and you need a concrete plan of attack. Load this skill before running task_planning.py.
---

# task-planning

Turn an issue (a plain-text task brief or GitHub issue body) into a
structured implementation plan. The plan is a child task graph where
every leaf is small enough for a single session and every task carries
an owner, a hint, blockers, and acceptance criteria.

The tool is **PURE**: no network, no filesystem, no side effects. The
same data is available as a structured child list (`plan_children`) for
machine consumption.

## How to call it

```python
from tools.task_planning import plan, plan_children

plan_doc = plan(issue_text)              # markdown plan string
children = plan_children(issue_text)     # list of ChildTask dicts
```

The `issue` argument is any plain text: a GitHub issue body, a task
brief, a paragraph of requirements. The tool parses it for structure:

- The first line (or `#`-stripped) becomes the plan title.
- `## Section Title` lines become **child tasks**.
- `Owner: name` inside a section sets the task's owner.
- `Hint: ...` inside a section sets a hint for whoever works the task.
- `- [ ]` checklist lines inside a section become **acceptance criteria**.
- `Blocker: ...` lines mark what must resolve first.
- `### Subsection` lines become nested children of their parent task.

## Output shape

`plan()` returns a markdown string:

```markdown
# <title>

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

## Plan

### T1: First section
Owner: fa-glm-l
Hint: check env
Blockers: waiting on API key
Acceptance:
- [ ] deploy the fix
- [ ] test it
Done when every acceptance criterion above is met.
```

`plan_children()` returns `ChildTask` objects with fields: `id`,
`title`, `owner`, `hint`, `blockers`, `acceptance`, `children`. Each
has a `to_dict()` method for JSON serialization.

## When to use it

- Someone hands you an unstructured issue and asks "what should we do?"
- You need to break a task into child tasks before delegating via
  `message-agent` to a sibling engineer.
- You want acceptance criteria you can tick off as each child completes.

## Examples

Given this issue:

```
Shore up the WebSocket channel

## Add reconnect logic
Owner: fa-glm-h
Hint: exponential backoff, max 30s
- [ ] reconnect on disconnect
- [ ] backoff caps at 30s

## Switch to SSE fallback
Blocker: reconnect logic done
- [ ] fallback tests pass
```

`plan(issue)` returns a markdown plan with two child tasks (T1, T2),
owners/hints filled, the blocker linking T2 to T1, and acceptance
checklists for both. `plan_children(issue)` returns two `ChildTask`
objects with the same structure as dicts.
