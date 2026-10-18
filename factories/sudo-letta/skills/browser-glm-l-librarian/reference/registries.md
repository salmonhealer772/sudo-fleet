# Where to search, by ecosystem

Cheap first pass. These give names; the repo and its dependents give the verdict.

## Cross-cutting
- `github.com/search` with `stars:>500 pushed:>2026-04-01` and the topic
  (`topic:self-hosted`, `topic:cli`, `topic:kubernetes-operator`, …). Sort by
  *recently updated* with a star floor, never by stars alone.
- `libraries.io` — reverse dependents across ecosystems, one place.
- `awesome-*` lists and `selfh.st`, `awesome-selfhosted.net` — candidate
  generation only.
- `alternativeto.net` / `opensourcealternative.to` — for "something like X".
- `news.ycombinator.com/item` threads — search `<product> production` and read
  the complaints; the top comment is usually the person who migrated away.

## JavaScript / TypeScript
- npmjs.com package page: weekly downloads, dependents, last publish, repository
  link, `types` present?
- `npmgraph.js.org` for the dependency tree of a candidate (bloat = risk).
- If the candidate is a build tool / bundler, check its own docs for the
  framework integrations (vite/esbuild/webpack plugins) — that's the adoption
  signal.

## Python
- pypi.org project page: release history, "Requires-Python", wheels available
  for your platform (source-only = pain), and the repo link.
- `pypistats.org` for real-ish download trend.
- `libraries.io/pypi/<name>` for dependents.

## Rust
- crates.io: recent-downloads column, reverse-deps, `last updated`.
- `docs.rs` — whether docs build and are current is itself a quality signal.
- `lib.rs` for a faster overview than the crates.io page.

## Go
- `pkg.go.dev/<module>`: "Imported by" count and the modules that import it.
- `go.mod` requirement freshness; std-lib-first preference is a quality signal
  in this ecosystem.

## C / C++
- distro packaging (Debian, Fedora, Arch, Alpine) — being packaged and current
  in distros is the strongest "real people use it" signal in this world.
- `vcpkg`/`conan`/`meson wrap` presence.
- Check release tarballs for GPG signing; unsigned is a yellow flag.

## Java / Kotlin
- Maven Central: version count, last release, "Used By" via
  `mvnrepository.com`.

## Docker / self-hosted
- Docker Hub pull counts (mirror-skewed — scale only), `linuxserver.io` presence,
  compose examples in the repo, image update cadence, image size, and whether the
  image runs as non-root.

## Infrastructure / k8s
- `artifacthub.io`, operator-hub listing, CRD stability (`v1` vs `v1alpha1`),
  upgrade notes in the repo.

## Databases / storage engines
- DB-Engines ranking for scale, but decide on the *storage model* and the
  operational story (backup/restore docs, replication, upgrade path).
