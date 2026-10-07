# issue-triage — tool contract

**One next action per issue.** Triage turns a noisy Paperclip inbox into a small set of clear decisions. For each issue handed in, `triage()` returns exactly one action — `resume`, `reassign`, `unblock`, `escalate`, or `close` — plus a one-line reason and, for a resume, whether the assignee needs a nudge.

Source of truth for the behaviour being collapsed: the bundled `paperclip-operations/issue-triage` skill (`packages/skills-catalog/catalog/bundled/paperclip-operations/issue-triage/SKILL.md`). This tool implements its per-issue decision, not its API plumbing.

## Interface

```python
from issue_triage import triage, Action

actions = triage(issues, now=None)   # -> list[Action], one per issue, same order
```

- **Inputs:** `issues` — a list of issue mappings (below). `now` — an optional timezone-aware `datetime` used as the reference instant for staleness; defaults to the wall clock, and tests always pass it.
- **Output:** a list of `Action` dataclasses, one per input issue, **in the same order**.
- **Purity:** no network, no disk, no global state, no randomness. The input list and its dicts are never mutated, so the same issues + the same `now` always produce the same actions.

```python
@dataclass(frozen=True)
class Action:
    issue_id: str   # the issue's id/key, echoed back
    action: str     # one of ACTIONS
    reason: str     # one line: why this action, for the triage comment
    wake: bool      # resume only: True = the assignee must be nudged

ACTIONS = ("resume", "reassign", "unblock", "escalate", "close")
```

`Action.as_dict()` yields exactly `{issue_id, action, reason, wake}` for JSON output.

## Issue fields read

Only these keys are ever consulted; every one is optional and defaults safely.

| field | meaning |
|---|---|
| `id` / `issueId` / `key` / `number` | identity, echoed into `Action.issue_id` (`"?"` if absent) |
| `status` | `todo`, `in_progress`, `in_review`, `blocked`, `done`, `cancelled` — matched case-insensitively, `-`/space normalised (`In-Review` == `in_review`) |
| `assignee` | the agent/human who owns the work |
| `updatedAt` / `lastActivityAt` / `lastCommentAt` / `lastUpdate` | last-touched time, ISO-8601 (a trailing `Z` is accepted) or `datetime` |
| `blockedBy` / `blockedByIssueIds` | first-class blockers: `[{"id","status"}]` or bare ids |
| `liveContinuation` | a monitor or queued continuation is still running |
| `reviewer` | the reviewer on an `in_review` issue |
| `pendingInteraction` | an open `request_confirmation` / `ask_user_questions` |
| `duplicateOf` | this issue duplicates another |

## The decision ladder

First matching rung wins; every rung is terminal, so an issue can never get two actions.

1. **Terminal status** (`done` / `cancelled`) → **close**. The thread is over.
2. **`duplicateOf` set** → **close**, naming the original.
3. **`blocked`**
   - no first-class blockers (free text only) → **escalate** — the blocker list is not real; convert it to `blockedByIssueIds` or name the one next action.
   - all blockers `done`/`cancelled` → **unblock** — clear the block, let the assignee resume.
   - any blocker `cancelled` → **unblock** — remove/replace it in `blockedByIssueIds`.
   - otherwise (a blocker is genuinely still open) → **resume** (not a wake) — the blockers-resolved wake fires automatically; re-triaging is noise.
4. **`in_review`**
   - no `reviewer` and no `pendingInteraction` → **reassign** — the review path is not real.
   - otherwise → **resume** — the review is with a real reviewer; leave it alone.
5. **`todo` / `in_progress`**
   - no `assignee` → **reassign** — nothing is driving the issue.
   - **stale** (see below) with a `liveContinuation` → **resume**, not a wake — a long-running continuation is not a stall.
   - **stale** without a `liveContinuation` → **resume** with `wake=True` — this is the skill's *wake-needed*: break the silence with the next concrete step.
   - `todo` (fresh) → **resume** with `wake=True` — assigned but not started.
   - `in_progress` (fresh) → **resume**, not a wake — the heartbeat is doing its job.
6. **Anything else** (unknown or missing status) → **escalate**. The tool never guesses a verdict it cannot justify.

## Staleness

`stale` means: an activity timestamp is present **and** `now - timestamp > 24h` (`STALE_HOURS`). A missing timestamp is **not** stale — "cannot tell" must never manufacture a wake. Plain seconds are never assumed; only ISO-8601 strings or `datetime` objects are parsed, and anything unparseable is treated as absent.

## Blocker statuses

A blocker entry with no status (a bare id, or `blockedByIssueIds`) is **open** — never clear a block you cannot verify. Only an explicit `done`/`cancelled` resolves a blocker.

## Mapping from the source skill

The bundled skill lists six verdicts; the tool emits five actions so every issue ends with something you can actually do next.

| source verdict | tool action |
|---|---|
| resume | `resume` (`wake=False`) |
| wake-needed | `resume` (`wake=True`) |
| reassign | `reassign` |
| unblock | `unblock` |
| escalate | `escalate` |
| close | `close` |

## Out of scope (deliberately)

- **Fetching.** The tool does no I/O. Pull the inbox (`GET /api/agents/me/inbox-lite`) and each candidate's `heartbeat-context` yourself, then hand the list in. This keeps the decision testable and keeps the API surface wherever the caller already owns it.
- **Acting.** The tool decides; it does not comment, reassign, or change status. The caller applies the action and writes the comment the reason describes.
- **Priority ordering.** One pass yields one action per issue; ranking the pass is the caller's job.
