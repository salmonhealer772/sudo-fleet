# tools/

The finished comm tools land here — one folder (or file) per tool. These are the real backends that satisfy the interfaces defined in `tests/comm_tools.py`.

Currently three tools are the targets:

- `list-siblings`
- `message-agent`
- `check-agent`

Each tool is specced two ways and tested one way:

- **contract (behavior):** `features/<name>.feature`
- **mechanism (how):** `docs/<name>-CONTRACT.md`
- **test:** `tests/test_<name>.py`

A tool is **finished** when its backend implements the `comm_tools` interface and the matching test file passes against the *real* backend — not just the in-memory fakes.

## Landed

- **list-siblings** — `tools/list_siblings.py` (runnable CLI + `live_roster()`),
  on top of `tools/real_transport.py` (`RealTransport.host_command()` through
  the docker-socket + nsenter bridge, and `live_fleet()` to wire a `Fleet`).

  ```sh
  python3 tools/list_siblings.py                  # the whole live roster
  python3 tools/list_siblings.py --filter glm     # substring match
  python3 tools/list_siblings.py --json           # machine-readable
  python3 tools/list_siblings.py --show-command   # the host reach it uses
  ```

  It runs `kubectl get services -n default` on the HOST via the bridge and feeds
  that stdout to the reference `comm_tools.parse_services`, so the roster is live
  (spawned siblings appear, removed ones drop off) with nothing baked in.

  `real_transport.RealTransport` also implements the other two doors the comm
  layer needs (`mcp_call` = MCP `initialize` + `tools/call`, `http_get` = GET a
  `-watch` sidecar), so one transport serves all three tools — but only the
  list-siblings path is exercised by `tests/test_list_siblings.py` so far.

## Still to build

- `message-agent` backend (needs `RealTransport.mcp_call`)
- `check-agent` backend (needs `RealTransport.http_get` + `host_command`)
