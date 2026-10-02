# sudo-letta comm mods

The three comm-tool mod packages an agent is born with:

- `list-siblings/`  -> `@letta-ai/list-siblings`  (tool `list_siblings`)
- `message-agent/`  -> `@letta-ai/message-agent`  (tool `message_agent`)
- `check-agent/`    -> `@letta-ai/check-agent`    (tool `check_agent`)
- `keyboard-mac/`   -> `@letta-ai/keyboard-mac`   (tool `keyboard_mode`)

These are installed at deploy time by `kube-scripts/up.sh` (see the `NPM_MODS` /
`COMM_MODS` block) via `kubectl cp` + `letta install <path>`, and verified at
their exact pinned version the same way the official npm mods are.

CANONICAL SOURCE: this repo on `main`, at `factories/sudo-letta/mods/`. These
are first-class files, not a vendored snapshot — edit them here, and bump the
versions in both `package.json` and `up.sh` together.
