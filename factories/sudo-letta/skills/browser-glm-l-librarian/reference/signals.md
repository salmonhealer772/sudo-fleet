# Signals that separate professional from hobby

## Alive vs corpse
| Read | Healthy | Dying | Dead |
|---|---|---|---|
| Last commit | < 3 months | 6–18 months | > 18 months, or "chore: bump deps" only |
| Last release | < 6 months | > 12 months | "no releases" with a 2021 README |
| Issues | triaged, maintainer replies | open pile, occasional reply | no maintainer in thread |
| PRs | merged, or closed with reason | stale | "please rebase" from 3 years ago |
| Repo state | active | — | **archived**, or a pinned "this project is seeking maintainers" issue |
| Successor | none needed | — | README points to a fork / "we recommend X" |

A single-maintainer project is fine if releases are regular and issues get
answered. It is a *risk*, and the risk is stated in the answer, not hidden.

## Professional build
- CI config present and passing on the default branch (not just a badge — open
  the actions/runs list and check the last green run's date).
- Tests that run against the real thing (integration fixtures, not only unit
  mocks). Look for `fixtures/`, `testdata/`, docker-compose in the test dir.
- Types / API docs generated from source.
- `CHANGELOG` with real entries, semver stated, breaking changes called out.
- `SECURITY.md`, signed releases, dependency-update bot activity.
- Migrations/upgrade guide for anything stateful.
- Non-trivial docs: a real "production" or "operations" section. Absence of one
  is a strong tell that nobody has run it at scale but the author.

## Licence reality check
- MIT / Apache-2.0 / BSD — fine, note attribution obligations.
- AGPL — fine for services you don't expose, a serious problem for a product.
- SSPL / BSL / "Commons Clause" — not open source in practice; call it out.
- **Licence-change history** (open-core pivot, relicensing to non-OSI) is one of
  the strongest predictors of future pain. Search the repo issues for
  "license" and read the reaction.
- CLA + single-vendor copyright assignment = the above change is *possible*.
  Community-owned (foundation, DCO, distributed copyright) = it isn't.

## Dependency health (transitive risk)
- Count runtime deps; each is a supply-chain and upgrade liability.
- Look for pinned ancient majors in its manifest.
- Check whether a critical dep is itself unmaintained or has a CVE feed open.
- Native/build steps (needs a C toolchain, `-sys` crates, node-gyp) = deployment
  pain. Fine if honest, disqualifying on a locked-down host.

## Operational cost
- Memory floor, startup time, whether it needs root, whether it needs a daemon,
  what backing store it requires, backup story, and whether it survives restarts
  without state loss. State this in the answer — the "professional" option is
  often heavier, and they need to know before they install it.

## Practitioner ground truth
Prefer, in this order: a real project's dependency file → an issue in a real
project where someone solved this → a migration write-up from someone who ran the
old one → forum/reddit/HN production reports. Blog "top 10" lists and AI answer
sites are candidate generators, never evidence.
