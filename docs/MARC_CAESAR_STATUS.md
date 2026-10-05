# Marc + Caesar — status

Task: make `Marc` (= psnvc, renamed) and `Caesar` (= forge, renamed) come up on any
Linux box via the sudo-fleet README command, seeded from committed glimors — never
a blank identity.

## What shipped (all pushed + verified)

- `sudo-letta` (master): `--from-glimor <dir>` initContainer seed. **717f582** also
  git-commits the seeded memfs brain before letta starts (Letta only loads
  COMMITTED memory — an untracked brain is silently ignored and the fork wakes
  blank).
- `sudo-agent` (main): `--from-glimor <dir>` initContainer seed into `/opt/data`.
- `sudo-fleet` (main): committed `deployments/Marc/` + `deployments/Caesar/`
  glimors; `435b709` renames the engineer identity in `human.md` (forge->Caesar).

## Glimors (deployments/)

- `deployments/Marc/letta/` — agent record (name=Marc) + memfs brain
  `agent-local-a290e69d-…` + settings.json. Identity rename covers BOTH core-memory
  files (persona.md + human.md): standalone `psnvc`->Marc, `forge`->Caesar;
  infra (`sudo-forge`, `deploy/sudo-forge`, `--forge`) survives.
- `deployments/Caesar/hermes/` — SOUL.md "You are Caesar … paired with Marc" +
  config.yaml + scrubbed state.db + .hermes_history + .local/.

## Scrub

Clean + passes GitHub push protection. Regex-based secret redaction (ghp_/sk-/etc.),
no emails, no family names, no hostnames, no sudo password in any committed file.

## Hostname

Lowercase RFC 1123 transform verified (`LaptopOfBlake` -> `laptopofblake`).

## fabean acceptance (wipe -> README command -> identity evidence)

- `sudo-marc` wakes as Marc (agent-id `agent-local-a290e69d-…`, name=Marc, no blank
  Tutor); memfs committed as `seed-fork-state`; persona + human loaded.
- `sudo-caesar` wakes as Caesar (SOUL "You are Caesar", no bare Hermes).
- Live answers (verified on fabean):
  - Caesar: "I'm Caesar — the engineer half… My planner is Marc, the mind half."
  - Marc: "I'm Marc — the mind half… My other half, the hands, is Caesar, my
    engineer, who runs as the `sudo-forge` deployment."
- Restart: initContainer skips via `.glimor-seeded` marker; state persists.

## Pitfalls fixed during acceptance (recorded for the next fork)

1. **Letta MemFS only loads COMMITTED memory.** A seeded brain with no `.git` (or
   untracked files) is silently ignored -> blank identity. The initContainer must
   `git init` + `git add -A` + `git commit` before letta starts, and the committed
   glimor must stay `.git`-FREE (a nested `.git` makes the outer repo treat the dir
   as a gitlink and not track the files).
2. **Rename both identity files, not just persona.md.** `human.md` also carries the
   planner<->engineer pointer ("my engineer is named X"); leaving it stale makes the
   live "who is your engineer" answer regress to the old name.
