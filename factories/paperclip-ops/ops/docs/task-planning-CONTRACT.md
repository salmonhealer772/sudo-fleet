# task-planning — tool contract

**PURE task planner**: turn any issue or task brief into a structured
implementation plan with a child task graph.

## Contract

- **Inputs:** `issue` (string) — a plain-text task brief, GitHub issue body,
  or any unstructured request. No other inputs.
- **Behavior:** parse the issue into a child task graph. No network, no
  filesystem, no side effects (PURE). Deterministic: same input always
  yields the same output.
- **Outputs (two forms, same data):**
  - `plan(issue) -> str` — a markdown plan document with title, "## Plan",
    one `### T<n>: <title>` per `##` section, and Owner/Hint/Blockers/
    Acceptance metadata where present.
  - `plan_children(issue) -> list[ChildTask]` — structured child list, each
    ChildTask has `id`, `title`, `owner`, `hint`, `blockers`, `acceptance`,
    `children`. Each has `to_dict()` -> JSON-serializable dict.
- **Parsing rules** (all best-effort, no errors raised for malformed input):
  - Title = first non-empty line, leading `#` stripped.
  - `## <title>` sections become top-level child tasks.
  - `### <title>` sections become nested children of their parent.
  - `Owner: name` line (if present) sets the task owner.
  - `Hint: ...` line (if present) sets the task hint.
  - `- [ ] ...` or `- [x] ...` lines become acceptance criteria (checkbox
    markers stripped).
  - `Blocker: ...` lines mark dependencies (text after `Blocker:`).
- **Task ids:** T1, T2, T3, ... in section appearance order.
- **Determinism:** same input -> same output, no time-dependent behaviour,
  no randomness, no external state.
