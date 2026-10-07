# tools/

The finished ops tools land here — one folder (or file) per tool. Each
tool is specced two ways and tested one way:

- **contract (behavior):** `features/<name>.feature`
- **mechanism (how):** `docs/<name>-CONTRACT.md`
- **test:** `tests/test_<name>.py`

A tool is **finished** when its backend implements the `ops_tools`
interface and the matching test file passes against the real backend —
not just the in-memory fakes.

## Landed

*(None yet — tools are being built in parallel. This README is updated
as each tool lands.)*

## Still to build

- paperclip_api
- goal_decompose
- assign_picker
- attention_detector
- issue_triage
- task_planning
- summarize_status
- status_card_query

## Conventions

- Every tool module lives in `tools/` and exposes a `run()` callable.
- The `ops_gate` enforces the load-first prerequisite (see
  `tools/ops_gate.py`).
- Tests use the fakes in `tests/fakes.py` and the `env` fixture from
  `tests/conftest.py`.
- The `ops_tools.discover_tools()` function auto-discovers every
  present module in `tools/` and registers it in the `registry` dict.
  Missing modules are silently skipped (tolerant discovery).