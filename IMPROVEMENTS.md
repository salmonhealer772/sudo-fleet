# sudo-fleet — Improvements Backlog

Running list of things to do. Each item gets broken into dispatchable parts
before it goes to an engineer. Status: [ ] todo · [/] in-progress · [x] done.

---

## 1. Consolidate the 3-repo system into one repo

The current split (sudo-fleet + sudo-agent + sudo-letta as three separate git
repos) is worse than a single repo. Roll sudo-agent and sudo-letta INTO
sudo-fleet so there is one repo, one entity.

- [ ] Merge sudo-agent into sudo-fleet
- [ ] Merge sudo-letta into sudo-fleet
- [ ] Separate out all the bins (scripts/binaries/entrypoints) into an organized
      structure — one clean, predictable layout instead of scattered under
      multiple repo roots
- [ ] Collapse the nested-clone flow in setup.sh (Command 1 currently clones
      sudo-agent + sudo-letta at runtime; with one repo they are already present)
- [ ] Update README + SPEC + all cross-repo references (paths, URLs) to the
      single-repo layout

## 2. Better comments on all the scripts

Every script (setup.sh, k8s-up.sh, k8s-down.sh, the factory up.sh/down.sh,
mcp_entrypoint.sh, the watch sidecars, etc.) needs richer inline documentation.

- [ ] More sub-comments, broken down per logical block
- [ ] Each comment states SPECIFICALLY what that part of the code does — not
      vague, line-level: "this block does X, because Y, and fails if Z"
- [ ] Call out the non-obvious/silent-failure-prone bits explicitly (sudo/TTY
      handling, swallowed errors, exit-code traps) so the next reader sees the
      intent, not just the mechanism

