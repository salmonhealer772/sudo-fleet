---
name: browser-glm-l-librarian
description: The core procedure for finding the genuinely best open-source software for a job — the one real practitioners actually run, at professional quality. Use on every hunt, before any searching, and again before you answer. Carries the quality bar, the sourcing rules (stars lie, downloads are partly mirror traffic, READMEs are marketing), the ordering of evidence, how to tell a living project from a corpse, the shortlist depth, and the shape of the answer.
---

# Finding the best open source for a job

You are not looking for *an* library. You are looking for the one a serious
engineer would install and then not regret. Those are different searches, and the
second one is mostly about **rejecting** things.

## The bar

A candidate only counts if all five hold:

1. **It is actually used.** Not starred — used. Evidence: dependents, distro/OS
   package presence, answers in real project issue threads, job postings, other
   libraries depending on it as a dependency of *their* dependency.
2. **It is alive.** Commits and releases inside the last 6–12 months; issues get
   answered; not archived; a successor has not been announced.
3. **It is professionally built.** Real tests, CI, typed interfaces or a
   documented API, a changelog, a versioning policy, security reporting route.
   One-person weekend projects can win — but only when they show this.
4. **It fits the actual job.** License, language, platform, licence obligations,
   and operational burden (what it costs to run, back up, upgrade).
5. **It has no quiet disqualifier.** Abandoned maintainer, single point of
   failure, paywalled "enterprise" core doing the real work, no clear
   maintainer succession, a licence change in its history (council → BSL/SSPL is
   a warning pattern).

If nothing meets all five, say so and name the least-bad two. Do not invent a
winner.

## Never trust these signals alone

- **Stars.** Vanity and age. A 12k-star project can be dead.
- **Download counts.** npm/PyPI/Docker Hub counts include CI, mirrors, and
  scraper traffic, and are dominated by a handful of transitive dependents.
  Useful for scale, useless for quality.
- **The README.** It is marketing. The truth is in the issues, the CI badge
  target, the last release date, and the dependents list.
- **LLM-ish summary sites** (awesome-lists, "top 10 X in 2026" posts, AI answer
  engines). Use them to *generate candidate names only*. Never as evidence.
- **Your own memory.** Version numbers, license changes, and what
  "everyone uses" rot fast. Check the live repo.

## Order of evidence, cheap to expensive

1. `reference/registries.md` — where to search for each ecosystem.
2. The project's own repository: last release, last commit, open PR age, issue
   response latency, CI status, license file, `go.mod`/`package.json`/`Cargo.toml`
   for what it depends on and what depends on it.
3. **Downstream reality**: package-manager page (npm/PyPI/crates.io/Debian),
   "Used by" on GitHub, reverse-dependency count on libraries.io.
4. **Practitioner ground truth**: real project threads where people chose
   between candidates; HN/Reddit threads from people running it in production;
   StackOverflow answers that mention the version they used.
5. The docs — for API fit and for whether the hard parts are documented at all
   (`reference/signals.md`).

## Procedure

1. **Restate the job as a spec in one line.** Input, output, constraints,
   environment, and what "professional quality" means here. If the operator's
   request is ambiguous, state the reading you're using in one line and carry on.
2. **Generate a wide field.** 8–15 candidates from registries + awesome-lists +
   "what do people use for X" threads. Do not filter yet.
3. **Kill fast.** For each: last release, archived?, license, language/platform
   match. Most die here. Record why (one line each) — the operator will ask.
4. **Shortlist 5.**
5. **Go deep on the top 3** — the five-point bar above, plus a real check that
   the thing does the job (read a usage example against the spec; run it if you
   can and it's cheap).
6. **Answer** in the format below. If two things are near-tied, say which wins on
   what axis and pick one.

## When the ask is "something like X, but…"

- Find X's *successor* and X's *closest rivals first* — often the answer is X's
  own next branch or the project the old maintainers moved to.
- Search for the migration/comparison discussions rather than new lists; the
  people who left X wrote down exactly why.
- Replacements frequently die on one specific feature X had. Find that feature's
  gap before recommending, and say so.

## Answer format

```
**The pick:** <name> — <one line what it is>
Why it's the professional choice: <3–5 hard reasons, each with a checkable fact>
The runner-up: <name> — <what it does better, what it does worse>
Rejected: <name> (dead since <date>) · <name> (architecturally wrong for <reason>) · …
Cost of adopting it: <licence obligations, ops burden, migration>
The catch: <the one thing that will annoy them, named honestly>
```

Short. Facts, not adjectives. Every claim attributable to something you looked
at in this session.
