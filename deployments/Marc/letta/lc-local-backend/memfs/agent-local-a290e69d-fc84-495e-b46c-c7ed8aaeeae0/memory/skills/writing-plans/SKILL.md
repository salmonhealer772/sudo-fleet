---
name: writing-plans
description: "Use when you have a spec or requirements for a multi-step task, before touching code — guides writing comprehensive implementation plans with bite-sized tasks, TDD, and DRY/YAGNI principles. Translated to English 2026-09-28 from the ClawHub superpowers-writing-plans skill (was Chinese)."
---

# Writing Implementation Plans

Write a comprehensive implementation plan, assuming the executor has zero context on the codebase and questionable taste. Document everything they need to know: which files each task touches, the code, the tests and docs they may need to check, how to test. Deliver the full plan as small-grained tasks. DRY. YAGNI. TDD. Commit frequently.

Assume the executor is a capable developer who knows almost nothing about our toolset or problem domain, and isn't great at test design.

**Announce when starting:** "I'm using the writing-plans skill to create an implementation plan."

**Context:** This should run in a dedicated working directory (created by the brainstorming step).

**Save the plan to:** `docs/plans/YYYY-MM-DD-<feature-name>.md`

## Scope check

If the spec covers multiple independent subsystems, it should have been decomposed into sub-project specs at the brainstorming stage. If not, recommend splitting into separate plans — one per subsystem. Each plan should produce working, testable software.

## File structure

Before defining tasks, map which files will be created or modified and what each is responsible for. This is where decomposition decisions get locked.

- Design in units with clear boundaries and well-defined interfaces. Each file should have one clear responsibility.
- You reason best about code you can hold in your head, and edits are more reliable. Prefer smaller, focused files over large do-everything files.
- Files that change together should live together. Split by responsibility, not by technical layer.
- In an existing codebase, follow existing patterns. If the codebase uses large files, don't unilaterally refactor — but if a file you're already modifying has grown too large, include a split in the plan.

This structure guides task decomposition. Each task should produce a meaningful, independently-understandable change.

## Small-grained tasks

**Each step is one action (2-5 minutes):**
- "Write the failing test" — one step
- "Run it to confirm it fails" — one step
- "Write the minimal code to make it pass" — one step
- "Run it to confirm it passes" — one step
- "Commit" — one step

## Plan document header

**Every plan must start with this header:**

```markdown
# [Feature name] Implementation Plan

**Goal:** [one sentence describing what's being built]

**Architecture:** [2-3 sentences describing the approach]

**Tech stack:** [key technologies and libraries]

---
```

## Task structure

```markdown
### Task N: [component name]

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

- [ ] **Step 1: Write the failing test**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `pytest tests/path/test.py::test_name -v`
Expected: FAIL, error "function not defined"

- [ ] **Step 3: Write the minimal implementation**

```python
def function(input):
    return expected
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `pytest tests/path/test.py::test_name -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/path/test.py src/path/file.py
git commit -m "feat: add specific feature"
```
```

## No placeholders

Every step must contain the actual content the executor needs. The following are **plan failures** — never write them:

- "TBD", "TODO", "implement later", "fill in details"
- "Add proper error handling" / "add validation" / "handle edge cases"
- "Write tests for the above" (with no actual test code)
- "Similar to task N" (duplicated code — the executor may read tasks out of order)
- Steps that describe what to do without showing how (code steps must have code blocks)
- Referencing a type, function, or method that isn't defined in any task

## Self-review

After writing the full plan, re-read the spec with fresh eyes and check the plan:

1. **Spec coverage:** go through each section/requirement of the spec. Can you point to the task that implements it? List any gaps.
2. **Placeholder scan:** search the plan for red flags — any pattern from the "no placeholders" section above. Fix them.
3. **Type consistency:** are the types, method signatures, and attribute names used in later tasks consistent with the earlier definitions? A `clearLayers()` in task 3 and `clearFullLayers()` in task 7 is a bug.

Fix issues inline as you find them. No second review pass — fix and continue. If a spec requirement has no task, add a task.

## Working-directory notes

Use a git branch for isolated work:

```bash
# Create a feature branch from the current branch
git checkout -b feature/<feature-name>

# Implement (following the plan tasks)
# ...

# When done
git checkout main && git merge feature/<feature-name>
```

## Execution handoff

After saving the plan, offer execution options:

**"Plan written and saved to `docs/plans/<filename>.md`. Two execution options:**

**1. Sub-agent driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, iterate fast.

**2. Sequential** — execute the tasks in batches in this session, with review checkpoints.

**Which one?"**

- **Sub-agent driven** → for this fleet, that means dispatching each task to the engineer (forge) and verifying before the next, matching the existing spec→delegate→verify→record loop.
- **Sequential** → execute the plan tasks in order in this session, run verification after each task.
