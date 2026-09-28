# tools/

The finished comm tools land here — one folder (or file) per tool. These are the real backends that satisfy the interfaces defined in `tests/comm_tools.py`.

Currently four tools are the targets:

- `list-siblings`
- `message-agent`
- `check-what-agent-is-doing`
- `check-agent-logs`

Each tool is specced two ways and tested one way:

- **contract (behavior):** `features/<name>.feature`
- **mechanism (how):** `docs/<name>-CONTRACT.md`
- **test:** `tests/test_<name>.py`

A tool is **finished** when its backend implements the `comm_tools` interface and the matching test file passes against the *real* backend — not just the in-memory fakes.

Nothing here is built yet. This folder is the landing zone for forge's backends.
