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

- **check-agent** — `tools/check_agent.py` (runnable CLI + `check_agent_live()`),
  the merged trail read (replaces check-agent-logs AND
  check-what-agent-is-doing), on the same `real_transport.py` bridge.

  ```sh
  python3 tools/check_agent.py fa-glm-l                     # last 100 events
  python3 tools/check_agent.py fa-glm-l --n 10              # the last 10 events
  python3 tools/check_agent.py fa-glm-l --n -1              # the ENTIRE trail
  python3 tools/check_agent.py fa-glm-l --mode compressed   # the plain chat log
  python3 tools/check_agent.py fa-glm-l --json              # machine-readable
  python3 tools/check_agent.py fa-glm-l --show-command      # the live reach it uses
  ```

  `full` (default) GETs the sibling's `-watch` `/events?n=N`; `compressed` reads
  its `transcript.txt` directly over the bridge (`kubectl exec deploy/sudo-<name>
  -c watch -- tail -n N <path>`, or `cat` for `n=-1`). The sibling name is
  resolved live against the roster, exactly like list-siblings.

  The live backend absorbs two cluster facts (both documented in the module):

  - `sudo-<name>-watch` does NOT resolve inside an agent pod, so
    `AddressBookTransport` reads the service's live ClusterIP off the host
    (`kubectl get service <name> -o jsonpath={.spec.clusterIP}`, cached) and GETs
    that.
  - a sibling's `kind` is learned from its Deployment's `app` label
    (`LiveFleet._kind_of`: `sudo-letta` -> planner, `sudo-agent` -> engineer),
    because the two kinds keep their transcript at different paths:
    `/home/node/.letta/watch/transcript.txt` (planner) vs
    `/opt/data/watch/transcript.txt` (engineer).

  Full mode returns the `-watch` trail; `normalize_events()` reduces the real
  ndjson stream (a list of JSON lines) and the tests' list-of-dicts fake to the
  same typed `{ts, conversation, event, ...}` records the contract describes.

## Still to build

- `message-agent` backend (needs `RealTransport.mcp_call`)
