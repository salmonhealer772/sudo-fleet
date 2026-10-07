"""In-memory fakes for the paperclip-ops layer sidecars and host bridge.

Mirrors comm/tests/fakes.py. These stand in for the real HTTP/MCP doors
a tool reaches, with NO sockets.

- FakeMcpSidecar  -> a sibling's "-mcp" service (records prompt-tool
                     calls, returns canned replies).
- FakeWatchSidecar -> a sibling's "-watch" HTTP tap (/events?n=N).
- FakeHostShell   -> the docker-socket + nsenter bridge (kubectl get
                     services for list-siblings, kubectl exec for
                     transcript reads).
- FakeTransport   -> binds the three call kinds (host_command,
                     mcp_call, http_get) to the fakes above.

The reference tool implementations in ops_tools.py consume exactly
these three transport methods, so the fakes model the same surface
the real backend will implement.
"""

from urllib.parse import urlsplit


class Fleet:
    """Minimal Fleet stub — mirrors comm_tools.Fleet for test wiring.

    Resolves sibling names against a fake roster and tracks kinds.
    """

    def __init__(self, transport, kinds=None):
        self.transport = transport
        self.kinds = kinds or {}
        self._roster = []

    def roster(self):
        return self._roster

    def resolve(self, name):
        exact = [e for e in self._roster if e["sibling"].lower() == name.lower()]
        if len(exact) == 1:
            return self._with_kind(exact[0])
        subs = [e for e in self._roster if name.lower() in e["sibling"].lower()]
        if len(subs) == 1:
            return self._with_kind(subs[0])
        if len(subs) > 1:
            raise AmbiguousSibling([e["sibling"] for e in subs])
        raise SiblingNotFound(name)

    def _with_kind(self, entry):
        resolved = dict(entry)
        resolved["kind"] = self.kinds.get(entry["sibling"], "letta")
        return resolved

    def wire_roster(self, specs):
        """Build a roster from (bare_name, kind) specs."""
        self._roster = []
        for name, kind in specs:
            self._roster.append({
                "sibling": name,
                "mcp_host": f"sudo-{name}-mcp:8000",
                "watch_host": f"sudo-{name}-watch:8000",
                "kind": kind,
            })


class SiblingNotFound(Exception):
    def __init__(self, name):
        self.name = name
        super().__init__(f"sibling not found: {name}")


class AmbiguousSibling(Exception):
    def __init__(self, candidates):
        self.candidates = candidates
        super().__init__(f"ambiguous sibling name; candidates: {candidates}")


class FakeHostShell:
    """Mimics running commands on the host through the docker-socket bridge."""

    def __init__(self):
        self.commands = []
        self._exact = {}
        self._sub = {}
        self._files = {}

    def set_exact(self, argv, output):
        self._exact[tuple(argv)] = output

    def set_sub(self, substring, output):
        self._sub[substring] = output

    def set_file(self, path, text):
        self._files[path] = text

    def run(self, argv):
        self.commands.append(list(argv))
        if argv and argv[-1] in self._files:
            lines = self._files[argv[-1]].splitlines()
            if "cat" in argv:
                return "\n".join(lines)
            if "tail" in argv and "-n" in argv:
                n = int(argv[argv.index("-n") + 1])
                if n > 0:
                    return "\n".join(lines[-n:])
                return "\n".join(lines)
        if tuple(argv) in self._exact:
            return self._exact[tuple(argv)]
        joined = " ".join(argv)
        for key, output in self._sub.items():
            if key in joined:
                return output
        return ""


class FakeMcpSidecar:
    """A sibling's -mcp door: records prompt-tool calls, returns canned replies."""

    def __init__(self, url, kind="letta"):
        self.url = url
        self.kind = kind
        self.calls = []
        self.reply = ""
        self.json_object = {"reply": "hi", "status": "ok"}
        self.hermes_json_text = '{"reply": "hi from hermes"}'
        self.inbox_id = "msg-0001"
        self.queue_status = {"pending": [], "recent": []}

    def handle(self, tool, args):
        self.calls.append((tool, dict(args)))
        if tool in ("letta_prompt", "hermes_prompt"):
            if args.get("mode") == "inbox":
                return {"id": self.inbox_id, "status": "pending"}
            if args.get("json"):
                if self.kind == "hermes":
                    return self.hermes_json_text
                return self.json_object
            return self.reply
        if tool in ("letta_queue_status", "hermes_queue_status"):
            return self.queue_status
        return None


class FakeWatchSidecar:
    """A sibling's -watch HTTP tap: /events?n=N."""

    def __init__(self, url):
        self.url = url
        self.requests = []
        self.events = []

    def get(self, path):
        self.requests.append(path)
        if path.startswith("/events"):
            return self._events_for(path)
        return None

    def _events_for(self, path):
        n = self._parse_n(path)
        if n == -1:
            return list(self.events)
        if n is None:
            n = 100
        return list(self.events[-n:])

    @staticmethod
    def _parse_n(path):
        if "?n=" in path:
            try:
                return int(path.split("?n=")[1])
            except ValueError:
                return None
        return None


class FakeTransport:
    """Routes the three transport call kinds to the fake sidecars/host."""

    def __init__(self, host):
        self.host = host
        self._mcp = {}
        self._watch = {}

    def register_mcp(self, url, sidecar):
        self._mcp[url] = sidecar

    def register_watch(self, url, sidecar):
        self._watch[url] = sidecar

    def host_command(self, argv):
        return self.host.run(argv)

    def mcp_call(self, url, tool, args):
        return self._mcp[url].handle(tool, args)

    def http_get(self, url):
        parts = urlsplit(url)
        base = f"{parts.scheme}://{parts.netloc}"
        path = parts.path or "/"
        if parts.query:
            path += "?" + parts.query
        return self._watch[base].get(path)


def event(ts, conversation, kind, **fields):
    """Build a typed full-mode event record."""
    record = {"ts": ts, "conversation": conversation, "event": kind}
    record.update(fields)
    return record


def services_text(service_names):
    """Render `kubectl get services` stdout for the given service names."""
    header = "NAME                      TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)    AGE"
    lines = [header]
    for name in service_names:
        lines.append(f"{name:<25} ClusterIP   10.43.0.1     <none>        8000/TCP   1d")
    return "\n".join(lines)


def make_env(specs):
    """Assemble a fully-wired fake fleet.

    specs: list of (bare_name, kind) tuples. kind is "letta" or "hermes".
    Returns a SimpleNamespace with fleet, transport, host, mcp/watch dicts.
    """
    from types import SimpleNamespace

    host = FakeHostShell()
    service_names = []
    for name, _kind in specs:
        service_names.append(f"sudo-{name}-mcp")
        service_names.append(f"sudo-{name}-watch")
    host.set_sub("kubectl get services", services_text(service_names))

    transport = FakeTransport(host)
    mcp, watch = {}, {}
    for name, kind in specs:
        murl = f"http://sudo-{name}-mcp:8000/mcp"
        wurl = f"http://sudo-{name}-watch:8000"
        m = FakeMcpSidecar(murl, kind=kind)
        w = FakeWatchSidecar(wurl)
        mcp[name] = m
        watch[name] = w
        transport.register_mcp(murl, m)
        transport.register_watch(wurl, w)

    kinds = {name: kind for name, kind in specs}
    fleet = Fleet(transport, kinds=kinds)
    return SimpleNamespace(fleet=fleet, transport=transport, host=host,
                           mcp=mcp, watch=watch, specs=specs)


class FakeRunner:
    """A stand-in for real_transport.RealTransport's subprocess runner."""

    def __init__(self, stdout="", fail_times=0, error="transient bridge failure"):
        self.stdout = stdout
        self.fail_times = fail_times
        self.error = error
        self.calls = []

    def __call__(self, cmd, timeout=None):
        self.calls.append((list(cmd), timeout))
        if len(self.calls) <= self.fail_times:
            raise RuntimeError(self.error)
        return self.stdout

    @property
    def count(self):
        return len(self.calls)


class FakeClock:
    """A hand-cranked monotonic clock for TTL tests."""

    def __init__(self, start=1000.0):
        self.t = float(start)

    def __call__(self):
        return self.t

    def advance(self, seconds):
        self.t += float(seconds)
        return self.t


class FakeHttpDoor:
    """A stand-in for urllib.request.urlopen."""

    def __init__(self, body='{"ok": true}', fail_times=0, error=None):
        self.body = body
        self.fail_times = fail_times
        self.error = error if error is not None else ConnectionRefusedError(
            "connection refused")
        self.urls = []

    def __call__(self, request, timeout=None):
        url = getattr(request, "full_url", None) or str(request)
        self.urls.append(url)
        if len(self.urls) <= self.fail_times:
            raise self.error
        return _FakeResponse(self.body)

    @property
    def count(self):
        return len(self.urls)


class _FakeResponse:
    """The slice of http.client.HTTPResponse the transport actually uses."""

    def __init__(self, body):
        self._body = str(body).encode("utf-8")
        self.headers = {}

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        return False