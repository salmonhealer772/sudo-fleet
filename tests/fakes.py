"""In-memory fakes for the sudo-fleet comm layer sidecars and host bridge.

These stand in for the real HTTP/MCP doors a tool reaches, with NO sockets:

- FakeMcpSidecar  -> a sibling's "-mcp" service (records prompt-tool calls,
                     returns canned replies for letta_prompt / hermes_prompt
                     and *_queue_status).
- FakeWatchSidecar -> a sibling's "-watch" HTTP tap (/events?n=N) -- the trail
                     the merged check-agent tool reads.
- FakeHostShell   -> the docker-socket + nsenter bridge (kubectl get services
                     for list-siblings, kubectl exec tail/cat for the
                     compressed transcript read).
- FakeTransport   -> binds the three call kinds (host_command, mcp_call,
                     http_get) to the fakes above, keyed by URL.

The reference tool implementations in comm_tools.py consume exactly these
three transport methods, so the fakes model the same surface the real backend
will implement.
"""

from urllib.parse import urlsplit

from comm_tools import Fleet


class FakeHostShell:
    """Mimics running commands on the host through the docker-socket bridge.

    Records every argv it is asked to run, and returns canned stdout. It can
    also model a sibling's on-disk transcript file (via set_file) so the
    compressed-logs "tail -n N" / "cat" read behaves like the real `kubectl
    exec ... tail/cat` the tool issues.
    """

    def __init__(self):
        self.commands = []      # list of argv (list of str), in call order
        self._exact = {}        # tuple(argv) -> stdout
        self._sub = {}          # substring -> stdout
        self._files = {}        # path -> full file text

    def set_exact(self, argv, output):
        self._exact[tuple(argv)] = output

    def set_sub(self, substring, output):
        self._sub[substring] = output

    def set_file(self, path, text):
        self._files[path] = text

    def run(self, argv):
        self.commands.append(list(argv))

        # Transcript file read: `kubectl exec ... tail -n N <path>` / `cat <path>`.
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
        self.kind = kind            # "letta" (planner) or "hermes" (engineer)
        self.calls = []             # list of (tool_name, args_dict)
        self.reply = ""             # plain-text reply for direct (non-json) mode
        self.json_object = {"reply": "hi", "status": "ok"}  # letta json reply
        self.hermes_json_text = '{"reply": "hi from hermes"}'  # hermes json reply
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
    """A sibling's -watch HTTP tap: /events?n=N (the check-agent trail).

    /status, /ps and /stream are deliberately absent -- the merged check-agent
    tool has no status/ps/stream surface; the live "what is it doing now"
    answer falls out of the freshest /events.
    """

    def __init__(self, url):
        self.url = url
        self.requests = []          # list of requested paths (with query), in order
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
            n = 100  # sidecar default depth
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
    """Build a typed full-mode event record (schema from check-agent)."""
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
    Returns a SimpleNamespace with:
      - fleet:      a comm_tools.Fleet wired to the fake transport
      - transport:  the FakeTransport
      - host:       the FakeHostShell
      - mcp/watch:  dicts of bare_name -> FakeMcpSidecar / FakeWatchSidecar
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
