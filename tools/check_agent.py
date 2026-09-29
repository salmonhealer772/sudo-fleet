#!/usr/bin/env python3
"""check-agent -- read a sibling's trail, live off the cluster.

Contract:  docs/check-agent-CONTRACT.md
Behavior:  features/check-agent.feature
Interface: tests/comm_tools.py (`Fleet`, `check_agent`), pinned by
           tests/test_check_agent.py

Usage
    python3 tools/check_agent.py fa-glm-l                     # last 100 events
    python3 tools/check_agent.py fa-glm-l --n 10              # the last 10 events
    python3 tools/check_agent.py fa-glm-l --n -1              # the ENTIRE trail
    python3 tools/check_agent.py fa-glm-l --mode compressed   # the plain chat log
    python3 tools/check_agent.py fa-glm-l --n 20 --json       # machine-readable
    python3 tools/check_agent.py fa-glm-l --show-command      # the live reach

ONE tool, ONE depth knob (`n`), two modes -- the merged check-agent that
replaced check-agent-logs AND check-what-agent-is-doing. There is no /status and
no /ps surface: "what is it doing right now" falls out of the freshest entries.

    full (default)  GET the sibling's -watch sidecar /events?n=N -- every event
                    (user/thinking/assistant/tool_call/tool_result/session/
                    process_state) as ndjson, schema {ts, conversation,
                    event, ...}. n=-1 -> the whole events file.
    compressed      read the sibling's transcript.txt directly through the host
                    bridge (the same read `stream.sh -t` does) -- plain chat
                    only: real prompts + replies, no thinking or tool noise.
                    n=-1 -> `cat` the whole transcript (no `tail` bound).

`n` means the same thing in both modes: k>0 = the last k entries; -1 = the
ENTIRE file with no depth cap; omitted = the default depth of 100.

The sibling is resolved live against the cluster (`kubectl get services -n
default` on the HOST), so a spawned sibling appears and a removed one drops off
with nothing baked in. Two cluster facts the live backend absorbs:

  * `sudo-<name>-watch` does NOT resolve from inside an agent pod (no cluster
    DNS for the service names), so the live ClusterIP is read from the roster
    and GET directly -- see AddressBookTransport.
  * a sibling's `kind` (Letta planner vs Hermes engineer) is learned from its
    Deployment's `app` label (sudo-letta | sudo-agent), because the two kinds
    keep their transcript at different paths on the shared data volume -- see
    LiveFleet / _read_transcript.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from urllib.parse import urlsplit, urlunsplit

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
for _path in (_ROOT, os.path.join(_ROOT, "tests"), _HERE):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import shlex  # noqa: E402

import comm_tools  # noqa: E402  (tests/comm_tools.py -- the reference interface)
from comm_tools import (DEFAULT_DEPTH, HERMES_TRANSCRIPT_PATH,  # noqa: E402
                        TRANSCRIPT_PATH, AmbiguousSibling, SiblingNotFound,
                        check_agent)
from real_transport import HostBridgeError, RealTransport  # noqa: E402

LETTA = "letta"
HERMES = "hermes"

#: Where a Hermes engineer's transcript actually lives on the shared data
#: volume (the same file `stream.sh -t` reads). `comm_tools` pins the
#: HERMES_TRANSCRIPT_PATH constant as the in-container path; on the running
#: fleet the engineer writes it here, so the live backend reads this first and
#: keeps the pinned path as the fallback.
HERMES_LIVE_TRANSCRIPT_PATH = "/opt/data/watch/transcript.txt"

#: The `app` label -> kind the fleet stamps on every agent Deployment.
APP_KINDS = {"sudo-agent": HERMES, "sudo-letta": LETTA}

N_WHOLE_FILE = -1


class TranscriptUnreadable(RuntimeError):
    """A sibling's transcript file could not be read through the host bridge."""

    def __init__(self, sibling, attempts):
        self.sibling = sibling
        self.attempts = list(attempts)
        detail = "; ".join(f"{path} => {err}" for path, err in self.attempts)
        super().__init__(f"could not read the transcript of {sibling}: {detail}")


class AddressBookTransport(RealTransport):
    """RealTransport + live service-name -> ClusterIP resolution for http_get.

    An agent pod cannot resolve `sudo-<name>-watch` (the service names are not
    in the pod's DNS), so a GET by name dies with "Name or service not known".
    The ClusterIP is read from `kubectl get service <name> -n default` over the
    same host bridge the roster uses, cached, and the GET is issued against it.
    If the lookup fails, the given URL is used as-is (so a caller that really
    does have DNS still works).
    """

    def __init__(self, host_kubeconfig=None, bridge_image=None, timeout=None,
                 runner=None):
        kwargs = {}
        if host_kubeconfig is not None:
            kwargs["host_kubeconfig"] = host_kubeconfig
        if bridge_image is not None:
            kwargs["bridge_image"] = bridge_image
        if timeout is not None:
            kwargs["timeout"] = timeout
        if runner is not None:
            kwargs["runner"] = runner
        super().__init__(**kwargs)
        self._cluster_ips = {}

    def http_get(self, url, timeout=None):
        target = self._resolve_url(url)
        if target == url:
            return super().http_get(url, timeout)
        try:
            return super().http_get(target, timeout)
        except Exception:
            # the address book was a lie -- fall back to the name as given.
            return super().http_get(url, timeout)

    def _resolve_url(self, url):
        parts = urlsplit(url)
        host, _, port = parts.netloc.partition(":")
        if not host or _is_ip(host):
            return url
        address = self._cluster_ip(host)
        if not address:
            return url
        netloc = f"{address}:{port}" if port else address
        return urlunsplit((parts.scheme, netloc, parts.path, parts.query,
                           parts.fragment))

    def _cluster_ip(self, service):
        if service in self._cluster_ips:
            return self._cluster_ips[service]
        address = ""
        try:
            stdout = self.host_command(
                ["kubectl", "get", "service", service, "-n", "default",
                 "-o", "jsonpath={.spec.clusterIP}"])
            address = (stdout or "").strip()
        except Exception:
            address = ""
        self._cluster_ips[service] = address
        return address


def _is_ip(host):
    parts = host.split(".")
    if len(parts) != 4:
        return False
    try:
        return all(0 <= int(part) <= 255 for part in parts)
    except ValueError:
        return False


class LiveFleet(comm_tools.Fleet):
    """The roster + resolver the tool uses, with the live kind lookup.

    The reference `Fleet` is handed a `kinds` map by its tests; on the real
    fleet nobody tells us which siblings are Letta planners and which are
    Hermes engineers, so the kind is learned from the Deployment's `app` label
    (with the container name as a fallback) and cached.
    """

    def __init__(self, transport, kinds=None):
        super().__init__(transport, kinds=kinds)
        self._learned = {}

    def _with_kind(self, entry):
        resolved = dict(entry)
        kind = self.kinds.get(entry["sibling"]) or self._learned.get(entry["sibling"])
        if kind is None:
            kind = self._kind_of(entry["sibling"])
            self._learned[entry["sibling"]] = kind
        resolved["kind"] = kind
        return resolved

    def _kind_of(self, sibling):
        deploy = f"sudo-{sibling}"
        reads = (
            ["kubectl", "get", "deploy", deploy, "-n", "default", "-o",
             "jsonpath={.metadata.labels.app}"],
            ["kubectl", "get", "deploy", deploy, "-n", "default", "-o",
             "jsonpath={.spec.template.spec.containers[0].name}"],
        )
        for argv in reads:
            try:
                marker = (self.transport.host_command(argv) or "").strip()
            except Exception:
                continue
            if marker in APP_KINDS:
                return APP_KINDS[marker]
        return LETTA  # the fleet's default flavour


def live_fleet(transport=None, **transport_kwargs):
    """A `LiveFleet` wired to the real transport (see AddressBookTransport)."""
    if transport is None:
        transport = AddressBookTransport(**transport_kwargs)
    return LiveFleet(transport)


# --- the tool ---------------------------------------------------------------

def check_agent_live(sibling, n=None, mode="full", *, fleet=None):
    """Read a sibling's trail on the LIVE fleet (the call the tool makes).

    Same interface and same return shape as `comm_tools.check_agent`:

      full        the reference call, over RealTransport.http_get
                  (the `-watch` sidecar's /events?n=N)
      compressed  the same `kubectl exec ... -c watch -- tail/cat` read the
                  contract pins, against the kind-correct transcript path
    """
    fleet = live_fleet() if fleet is None else fleet
    if mode != "compressed":
        return check_agent(sibling, n, mode, fleet=fleet)
    entry = fleet.resolve(sibling)
    return _read_transcript(entry, n, fleet)


def _read_transcript(entry, n, fleet):
    """`kubectl exec deploy/sudo-<sibling> -c watch -- tail -n N <transcript>`.

    n=-1 -> `cat` (the entire transcript, no tail bound); omitted -> the same
    default depth of 100 full mode uses.
    """
    kind = entry.get("kind", LETTA)
    paths = ([HERMES_LIVE_TRANSCRIPT_PATH, HERMES_TRANSCRIPT_PATH]
             if kind == HERMES else [TRANSCRIPT_PATH])
    deploy = f"deploy/sudo-{entry['sibling']}"
    attempts = []
    for path in paths:
        if n == N_WHOLE_FILE:
            argv = ["kubectl", "exec", deploy, "-c", "watch", "--", "cat", path]
        else:
            depth = DEFAULT_DEPTH if n is None else n
            argv = ["kubectl", "exec", deploy, "-c", "watch", "--",
                    "tail", "-n", str(depth), path]
        try:
            text = fleet.transport.host_command(argv)
        except Exception as exc:                    # try the next path
            attempts.append((path, f"{type(exc).__name__}: {exc}"))
            continue
        return text.splitlines()
    raise TranscriptUnreadable(entry["sibling"], attempts)


# --- rendering --------------------------------------------------------------

def normalize_events(entries):
    """Reduce the -watch payload to the contract's typed event records.

    The real sidecar streams `application/x-ndjson` (one JSON object per line),
    which RealTransport.http_get hands back as a list of LINES; the in-memory
    fake in the tests hands back dicts directly. Both shapes come out of here as
    the `{ts, conversation, event, ...}` records docs/check-agent-CONTRACT.md
    describes.
    """
    events = []
    for item in entries or []:
        if isinstance(item, dict):
            events.append(item)
            continue
        text = str(item).strip()
        if not text:
            continue
        try:
            parsed = json.loads(text)
        except ValueError:
            events.append({"event": "raw", "text": text})
            continue
        if isinstance(parsed, dict):
            events.append(parsed)
        elif isinstance(parsed, list):
            events.extend(e for e in parsed if isinstance(e, dict))
    return events


def render_trail(sibling, events, n=None):
    """One line per event: time, kind, conversation, and the gist of it."""
    depth = "the whole file" if n == N_WHOLE_FILE else (f"n={n}" if n is not None
                                                        else f"n={DEFAULT_DEPTH}")
    lines = [f"# {sibling}: {len(events)} event"
             f"{'s' if len(events) != 1 else ''} (mode=full, {depth})"]
    for event in events:
        lines.append(f"[{_clock(event.get('ts'))}] {_kind(event):<13} "
                     f"{_clip(str(event.get('conversation', '-')), 30):<30} "
                     f"{_gist(event)}")
    return "\n".join(lines)


def _kind(event):
    return str(event.get("event", "?"))


def _gist(event):
    kind = _kind(event)
    if kind in ("user", "thinking", "assistant", "tool_result"):
        return _clip(_one_line(event.get("text", "")), 160)
    if kind == "tool_call":
        return _clip(f"{event.get('name', '?')} "
                     f"{json.dumps(event.get('args', {}), sort_keys=True)}", 160)
    if kind == "session":
        return f"id={event.get('id', '?')} cwd={event.get('cwd', '?')}"
    if kind == "process_state":
        processes = event.get("processes") or []
        return f"state={event.get('state', '?')} processes={len(processes)}"
    rest = {k: v for k, v in event.items()
            if k not in ("ts", "conversation", "event")}
    return _clip(json.dumps(rest, sort_keys=True), 160)


def _one_line(text):
    return " ".join(str(text).split())


def _clip(text, width):
    text = str(text)
    return text if len(text) <= width else text[:width - 1] + "…"


def _clock(ts):
    try:
        import datetime
        return datetime.datetime.fromtimestamp(float(ts)).strftime("%H:%M:%S")
    except (TypeError, ValueError, OSError):
        return "-" if ts is None else str(ts)[:8]


def _depth_label(n):
    if n == N_WHOLE_FILE:
        return "the whole file"
    return str(DEFAULT_DEPTH if n is None else n)


def _transcript_command(sibling, n):
    depth = ("cat" if n == N_WHOLE_FILE
             else f"tail -n {_depth_label(n)}")
    return (f"kubectl exec deploy/sudo-{sibling} -c watch -- "
            f"{depth} <transcript>")


# --- cli --------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Read a sibling agent's trail -- the full event stream "
                    "(default) or the compressed chat transcript.")
    parser.add_argument("sibling",
                        help="sibling agent name (bare), e.g. fa-glm-l")
    parser.add_argument("--n", type=int, default=None, metavar="N",
                        help="trailing depth: k>0 = the last k entries; "
                             "-1 = the ENTIRE file; omit for the default 100")
    parser.add_argument("--mode", choices=("full", "compressed"), default="full",
                        help="full (default) = the raw event trail; "
                             "compressed = the plain chat transcript")
    parser.add_argument("--json", action="store_true",
                        help="print the trail as JSON")
    parser.add_argument("--show-command", action="store_true",
                        help="print the live reach this tool uses, then exit")
    parser.add_argument("--timeout", type=float, default=None,
                        help="per-call timeout in seconds (default 60)")
    args = parser.parse_args(argv)

    if args.n is not None and args.n != N_WHOLE_FILE and args.n <= 0:
        print(f"check-agent: n must be a positive integer or -1 (the entire "
              f"file); got {args.n}", file=sys.stderr)
        return 2

    transport = AddressBookTransport(**({} if args.timeout is None
                                        else {"timeout": args.timeout}))

    if args.show_command:
        for command in transport.bridge_commands(
                ["kubectl", "get", "services", "-n", "default"]):
            print(shlex.join(command))
        print()
        suffix = "" if args.n is None else f"?n={args.n}"
        print(f"resolve kind: <bridge> kubectl get deploy sudo-<sibling> "
              f"-n default -o jsonpath={{.metadata.labels.app}}")
        print(f"full:         GET http://<watch ClusterIP>:8000/events{suffix}")
        print(f"compressed:   <bridge> {_transcript_command(args.sibling, args.n)}")
        return 0

    fleet = live_fleet(transport=transport)
    try:
        trail = check_agent_live(args.sibling, args.n, args.mode, fleet=fleet)
    except SiblingNotFound as exc:
        print(f"check-agent: {exc}", file=sys.stderr)
        return 1
    except AmbiguousSibling as exc:
        print(f"check-agent: {exc}", file=sys.stderr)
        return 1
    except HostBridgeError as exc:
        print(f"check-agent: could not reach the host: {exc}", file=sys.stderr)
        return 1
    except TranscriptUnreadable as exc:
        print(f"check-agent: {exc}", file=sys.stderr)
        return 1

    if args.mode == "compressed":
        lines = list(trail)
        if args.json:
            print(json.dumps(lines, indent=2))
            return 0
        print(f"# {args.sibling}: {len(lines)} transcript line"
              f"{'s' if len(lines) != 1 else ''} (mode=compressed, "
              f"n={_depth_label(args.n)})")
        print("\n".join(lines))
        return 0

    events = normalize_events(trail)
    if args.json:
        print(json.dumps(events, indent=2))
    else:
        print(render_trail(args.sibling, events, args.n))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
