---
name: load-persona
description: Read your concern persona FRESH from /opt/personas/<name>.md (live, never the .draft) plus _shared.md at the START of every run, and report the concern line + the file mtime. The file is the ONLY authority for what you care about.
---

# load-persona

Your single concern is defined by AO in the dashboard, on disk at
`/opt/personas/<your-name>.md`. **That file is the ONLY authority for what you care
about.** It is NOT baked into your SOUL.md, NOT cached in memory, and NOT carried in a
skill. Read it fresh at the start of every run.

## When to run this

At the START OF EVERY RUN — before you scan any provision, and any time you are asked
what your concern is (or asked to report the mtime of the persona file you read).

## The procedure (in order)

1. **Resolve your persona name.** It is the value of the `PERSONA_NAME` environment
   variable (`echo "$PERSONA_NAME"` in the terminal). If `PERSONA_NAME` is unset, fall
   back to `AGENT_NAME`.
2. **Read the LIVE persona file:** `read_file("/opt/personas/<name>.md")`. Read ONLY this
   exact path — it is the live, published file.
3. **Never read a draft.** `/opt/personas/<name>.md.draft` is the unpublished draft. It
   must never reach a running agent. If you only have a `.draft`, that is NOT your concern.
4. **Read the shared half:** `read_file("/opt/personas/_shared.md")` — the identical
   "how to be a good meta-data-agent" block every agent carries. Combine it with your
   concern file.
5. **From the live file, note:**
   - the `**Concern:**` line (line 3 of the file), and
   - the `## What you care about` section, and
   - the `## What you do NOT care about` section.
6. **Get the file mtime** (the proof a save landed): run
   `stat -c '%Y %y' /opt/personas/<name>.md` in the terminal and note the exact value.

## Report (one line, when asked)

Concern: <the **Concern:** line>. Persona file: /opt/personas/<name>.md, mtime <mtime>.

Always report the concern from the file you JUST read and the mtime you JUST stat'ed —
never from memory, never from a previous run, never from a cached copy.
