---
name: clawhub
version: 1.1.0
description: Download and install skills from ClawHub (https://clawhub.ai). Use when the user wants to browse, search, or install skills from the ClawHub skill registry. Note: this skill documents the CORRECT ClawHub API (verified 2026-09-28) — the registry's own skills sometimes ship stale hostnames/bugs.
---

# ClawHub Skill Registry

ClawHub is a public skill registry for AI agents, hosted at https://clawhub.ai. This skill documents the real API surface and the correct install workflow.

## API endpoints (verified 2026-09-28)

Base: `https://clawhub.ai/api/v1`

| Purpose | Endpoint |
|---|---|
| **Search** by keyword | `GET /api/v1/search?q=<keyword>` — returns `{ results: [...] }`. Each result has `canonicalUrl`, `displayName`, `downloads`, and `slug`. |
| **List** catalog (paginated) | `GET /api/v1/skills` — returns `{ items: [...], nextCursor }`, 25/page. Ignores `?q=`. |
| **Top by downloads** | `GET /api/v1/skills?sort=downloads` — `items[]` with `stats.downloads`. |
| **Skill detail** | `GET /api/v1/skills/<slug>?ownerHandle=<owner>` — returns latest version + tags. |
| **Download zip** | `GET /api/v1/download?slug=<slug>&version=<version>` — returns a zip of the skill. |

### The owner-disambiguation rule (CRITICAL)

Many skills share a bare slug (e.g. there are 4+ `skill-vetter` skills). The API 409s with `AMBIGUOUS_SKILL_SLUG` on a bare slug whenever more than one publisher uses it. It returns the disambiguation in its error body, e.g.:

```
"ref": "@spclaudehome/skill-vetter"
```

**The download endpoint takes `ownerHandle` directly:**

```bash
curl "https://clawhub.ai/api/v1/download?slug=skill-vetter&ownerHandle=spclaudehome&version=1.0.0" -o skill.zip
```

- `version` must be a real version string (e.g. `1.0.0`), NOT `latest`. Resolve it first via the detail endpoint: `GET /api/v1/skills/<slug>?ownerHandle=<owner>` → `latestVersion.version` or `skill.tags.latest`.
- The search results' `reference`/`install` fields are sometimes `null`; the reliable owner+slug comes from `canonicalUrl` (`/owner/skills/slug` → owner=owner, slug=slug).

### Installation to Letta

`letta skills install clawhub:<slug>` works for **unambiguous** bare slugs. It does NOT pass through `@owner/` — the CLI's `parseClawHubSpecifier` drops the owner and hits the bare-slug endpoint, so it 409s on ambiguous slugs. Workaround for ambiguous slugs: download the zip via `/api/v1/download` (with `ownerHandle`) and copy its contents into `<memfs>/skills/<name>/`.

Also: `letta skills install` needs `unzip` present. If it fails with `spawn unzip ENOENT`, `apt-get install unzip` (after `apt-get update`) and retry.

## Workflow

1. **Search**: `curl "https://clawhub.ai/api/v1/search?q=keyword"` — parse `results[].canonicalUrl` / `displayName` / `downloads`.
2. **Top skills**: `curl "https://clawhub.ai/api/v1/skills?sort=downloads"` — parse `items[].stats.downloads` and `items[].slug`.
3. **Resolve owner+version** if the slur is ambiguous (409, or you need a specific publisher): detail endpoint.
4. **Install**: unambiguous slug → `letta skills install clawhub:<slug> --agent $AGENT_ID`; ambiguous → download zip with `ownerHandle` and copy into memfs.
5. **Vet before install** — see the `skill-vetter` skill for the security checklist.

## skills.sh vs ClawHub (the `source` field is the tell)

Some search results are **`skills-sh` skills, not `clawhub` skills** — their `source` field reads `"skills-sh"` instead of `"clawhub"`. These live on **`www.skills.sh`** (a different registry), and the ClawHub API will NOT serve their content: `/api/v1/skills/<slug>` returns "Skill not found" for them. Fetching their `www.skills.sh` URL returns a **Next.js SPA shell** (raw `<html><head>...` with `_next/` chunk scripts), not raw skill content — so there's no clean curl of the body. Treat a `skills-sh` result as a *lead on a concept*, not a directly-downloadable skill: read its name/description and act on the idea (e.g. "shellcheck-configuration" → just `apt-get install shellcheck`), rather than over-engineering a fetch route.

## Known stale info in third-party clawhub skills

The `clawhub-wrapper` skill (douglarek) references a dead API host `wry-manatee-359.convex.site` and its download script drops owner disambiguation. Use the `clawhub.ai/api/v1` endpoints above, not any copied-from-the-registry hostnames.
