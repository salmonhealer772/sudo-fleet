---
name: issue-triage
description: Turn a Paperclip inbox into one next action per issue. Use when you have a batch of issues that are stale in_progress, blocked, in_review, or assigned-but-not-progressing, and need the single action to take on each — resume, reassign, unblock, escalate, or close — without reading every thread. Load this skill before running issue_triage.py; the tool is the decision, this skill is when to reach for it.
---

# issue-triage

Convert a noisy inbox into a small set of clear next actions. One pass leaves
every issue you hand in with exactly one verdict, so you (or a manager reading
the pass) know what happens next without touching the threads.

## When to use

- Daily or shift-start review of `in_progress`, `in_review`, and `blocked` work.
- An inbox has many open assignments and no clear priority.
- You were woken by a comment that suggests an old issue stalled.

## When not to use

- You are already checked out on one specific issue and the wake context names
  it. Work that issue — don't triage the whole inbox.
- An issue already has an open `request_confirmation` / `ask_user_questions`.
  Wait for the answer; re-triage is noise.

## How to call it (the tool lives at `ops/tools/issue_triage.py`)

The tool is a pure function — hand it the issues you already have:

```sh
python3 tools/issue_triage.py inbox.json          # a JSON list of issues
cat inbox.json | python3 tools/issue_triage.py -  # ...or from stdin
python3 tools/issue_triage.py inbox.json --json   # machine-readable
```

or from Python:

```python
from issue_triage import triage
for action in triage(issues):
    print(action.issue_id, action.action, action.reason)
```

It returns **one `Action` per issue, in the order you passed them in**. Nothing
is fetched and nothing is written — pull the issue list from the Paperclip API
first (`GET /api/agents/me/inbox-lite`, then `heartbeat-context` per candidate),
then hand it to `triage`.

## The five actions

| action | means |
|---|---|
| `resume` | the execution path is alive (or is woken) — leave it running |
| `reassign` | there is no valid owner: no assignee, or a review path that isn't real |
| `unblock` | first-class blockers are resolved — clear the block |
| `escalate` | needs a human/board, or the state can't be classified in one pass |
| `close` | terminal: complete, duplicate, or no longer relevant |

A `resume` with `action.wake == True` is the skill's **wake-needed**: the
assignee is stalled with no live continuation, so post the one comment that
names the next concrete step before letting the heartbeat continue. A `resume`
with `wake == False` means the path is fine — **do not comment**.

Per-issue reasoning (blocker resolution, the 24h stale rule, why a missing
timestamp is never treated as stale) is pinned in
`docs/issue-triage-CONTRACT.md`; the behaviour is pinned in
`features/issue-triage.feature`.

## Don't-do list

- Don't @-mention agents during triage; mentions cost budget. Reassign instead.
- Don't re-comment on a `blocked` issue if your last comment was also a blocked
  update with no reply since.
- Don't cancel cross-team issues — reassign to the responsible manager.
- Don't change a status without a comment that explains the change.
- Don't guess: if `triage` says `escalate`, escalate rather than re-classifying
  it by hand.
