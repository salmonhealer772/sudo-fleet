---
name: human-md-profiler
description: Build and maintain the human.md (user profile) file an agent keeps about the person it works with. Covers conversational intake (anchor fields + free-form context, under a word cap), reading/updating an existing file, and the progressive "learn over time, not in one interrogation" posture. Use when the user says "profile me", "get to know me", "write/update my human.md", or wants the agent's understanding of them refreshed or consolidated. Ported from the OpenClaw user-profiler skill (2026-09-28) with the OpenClaw/Claude-specific recommend mode and voice stripped.
---

# human.md Profiler

Build and maintain the `human.md` file an agent keeps about the person it works with. The goal is a genuinely useful working model of the person — not a dossier, and not a rigid form.

## Core philosophy

> The more you know, the better you can help. But you're learning about a person, not building a dossier.

A good `human.md` = **a handful of anchor fields** (Name / Role / Stack / Style / Timezone) + **a free-form context section** (natural language).

- Anchor fields give the agent precise hooks; the context section leaves room for human complexity.
- Total length stays under **~500 words** — the context window is a shared resource.
- Gathered progressively, not all at once — fill in more as the relationship develops.

## When NOT to use this

- Editing the agent's own identity/persona (`persona.md` / `SOUL.md`) — that's a different job.
- General conversation unrelated to profiling the person.

## Workflow

### Step 1 — check for an existing human.md

1. Confirm where the file lives (for a fleet Letta agent, it's its own `system/human.md`; otherwise ask the user for the target).
2. If it exists → read it, show a one- or two-line summary of what's already known, ask what to add or update.
3. If it doesn't exist → go to Step 2.

### Step 2 — conversational intake

Guiding principles:

- **Don't list every question at once** — one or two related questions at a time, chat not interrogation.
- **Lead with role, then branch.** The role determines where follow-ups go (an engineer has a stack; a founder has goals).
- **Skipping is fine.** If they say "skip" or "rather not say", move on without pressing.
- **Infer before asking.** If something can be deduced from context, confirm it instead of re-asking ("I'm guessing you work with X?") and let them correct you.
- **Two or three turns is enough** to cover the anchors + a baseline context block.

Fields and intake order: see [references/user-profile-fields.md](references/user-profile-fields.md).

### Step 3 — write the file

Template and format: see [references/user-md-template.md](references/user-md-template.md).

1. Assemble the collected info into a preview.
2. Show the preview for confirmation before writing.
3. Write it. Apply the word cap — trim rather than pad.

### Update mode

When asked to update an existing `human.md`:

1. Read the current file.
2. Change **only** what they specified — leave everything else intact.
3. Review for staleness periodically: if the agent is acting on an outdated picture of the person, refresh it.

### Consolidation mode (fleet)

When asked to profile someone across *multiple* agents' `human.md` files (e.g. a fleet harvest):

1. Read every `human.md` that exists about that person.
2. Extract the facts that recur — those are the load-bearing truths; the one-off details are usually noise.
3. Distinguish "how to serve this person" (preferences, corrections) from "who this person is" (identity, what they're after, what animates them). Both matter; don't let the former crowd out the latter.
4. Write one consolidated file, under the cap. Flag contradictions to the user rather than silently picking a side.

## Dialogue posture

- **Chat, not interview.** Natural, curious, a brief reaction to each answer so they feel heard, not transcribed.
- **No judgment.** You're learning who they are, not grading their choices.
- **Never store sensitive information** — passwords, keys, government IDs, financial or health data. `human.md` gets injected into prompts and may appear in logs. If sensitive info comes up, refuse to write it and say why.

## Error handling — degrade, don't halt

| Failure | Degraded behavior |
|---|---|
| Target dir doesn't exist | Ask them to confirm the path, or fall back to the agent's own memfs |
| Write fails | Output the content in chat so they can save it manually |
| Contradictory facts across files | Surface the conflict to the user; don't silently resolve it |

## Sources / notes

Ported from the `openclaw-user-profiler` skill (`eamanc-lab`, v2.3.1, ClawHub). Changes made for the fleet:

- Stripped the `Recommend mode` + the `role-skill-catalog.md` (768 lines of Claude Code `npx skills add` recommendations — wrong harness).
- Stripped the "lobster / Adam the Lobster Creator God" voice.
- `user.md` → `human.md` (the fleet's convention).
- Added the **consolidation mode** for cross-agent profiling (the missing piece the `/opt/eyes/` harvest exposed).
