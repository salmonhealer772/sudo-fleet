# Comm-tool mod packaging (list-siblings / message-agent / check-agent)

The three comm tools ship to `sudo-letta` (Letta/Marc) agents as **Letta Code mod
packages**, exactly like `@letta-ai/web-search`. This file is the packaging
spec: the package shape, the install-source forms `letta install` accepts, and
why the local `./path` form is the one `up.sh` pins.

Canonical source of the packages: `factories/sudo-letta/mods/<name>/` in this
repo (`sudo-fleet`). They are first-class files here (not a vendored copy), so
`up.sh` ships them at deploy time — this repo is the source of truth.

## Package shape

Each mod is a directory with a `package.json` whose manifest lives under the
`letta` key, plus a `mods/index.mjs` entry:

```
mods/<name>/
  package.json
  MOD.md            # agent-facing semantics (human-readable, optional)
  README.md         # (optional)
  mods/
    index.mjs
```

`package.json`:

```json
{
  "name": "@letta-ai/<name>",
  "version": "0.1.0",
  "type": "module",
  "letta": {
    "manifestVersion": 1,
    "mods": ["./mods/index.mjs"],
    "capabilities": ["tools"],
    "engines": { "lettaCodeCli": ">=0.27.14" }
  }
}
```

Required fields: `name` (a valid npm name; scoped `@letta-ai/<name>` keeps the
`mods list` output consistent with the official mods), `version` (an EXACT
version — never `^`/`latest`), and the `letta` manifest
(`manifestVersion: 1`, `mods: ["./mods/index.mjs"]`, `capabilities: ["tools"]`).

`mods/index.mjs` is plain ESM:

```js
export default function activate(letta) {
  if (!letta.capabilities.tools) return;
  return letta.tools.register({
    name: "list_siblings",           // the tool name the agent calls
    description: "...",
    parameters: { type: "object", properties: {...}, required: [...], additionalProperties: false },
    requiresApproval: false,
    parallelSafe: true,
    async run(ctx) { /* read ctx.args, return a string or {status, content} */ },
  });
}
```

No build step: the entry is ESM, and the CLI activates mods on process start.

## Install-source forms `letta install` accepts

From `letta install --help` (letta-code 0.33.2) and the install dispatch in
`letta.js`:

1. `npm:<package>[@<version>]`
   Published npm mod package. Exact pin: `npm:@letta-ai/web-search@0.1.0`.
   `mods list` renders `npm:<name>@<version>`.

2. `git:github.com/<owner>/<repo>[#ref]` (also `https://github.com/<owner>/<repo>[#ref]`,
   `ssh://git@github.com/<owner>/<repo>[#ref]`, `git@github.com:<owner>/<repo>[#ref]`)
   A GitHub repo whose ROOT is the mod package (package.json#letta at the repo
   root). The optional `#ref` (branch / tag / commit) pins the version. One
   repo = one mod package, so a multi-mod repo like `sudo-fleet` cannot use
   this form for a single tool.

3. `./path/to/package` (relative or absolute)
   A local mod package directory. letta reads `package.json` `name` and
   `version`, records the source as `npm:<name>` and the version from the
   `version` field, and copies the directory into the managed mods root
   (`~/.letta/mods/packages/npm/<scope>/<name>/`).

The install dispatch order is: `npm:` → git source → local-path directory →
skill install. A specifier that is neither `npm:` nor a recognized git form is
treated as a local path; if the path resolves to a directory with
`package.json#letta`, it installs as a local mod package.

## Why up.sh pins the local `./path` form

The three comm mods are **not published to the npm registry**, and they are
three separate packages in one repo (so the `git:` repo-root form does not
fit). That leaves the local `./path` form — which is still **idempotent and
exact-version pinned**:

- `letta install ./path/to/list-siblings` records `source = npm:@letta-ai/list-siblings`
  and `version = 0.1.0` (both read from that package's `package.json`).
- `letta mods list` renders exactly `npm:@letta-ai/list-siblings@0.1.0` — the
  SAME string the npm mods' exact-version check greps for.

So `up.sh` verifies a local-path mod with the identical `grep -Fq
"npm:<name>@<version>"` it uses for the npm mods; only the *install specifier*
differs (`<local dir>` vs `npm:<name>@<version>`).

## How up.sh ships + pins them (see bin/up.sh)

1. `kubectl cp $REPO_DIR/mods/. $POD:/tmp/letta-mods/` — the pod cannot see the
   host's repo, so the packages are copied in at deploy time (no image rebuild,
   no published npm package).
2. `letta install /tmp/letta-mods/<name>` — local-path install.
3. Verify each mod with `grep -Fq "npm:@letta-ai/<name>@0.1.0"` against
   `letta mods list` — missing or wrong version forces a (re)install; a verify
   failure aborts the deploy loudly (a silent tool-less agent is never allowed).

## Versioning

Bump the `version` field in `package.json` AND the matching verify string in
`up.sh` together, deliberately, after re-testing live — never `latest`. The
version is what makes the install idempotent: a pod already at `0.1.0` is left
alone; a pod at anything else is reinstalled.
