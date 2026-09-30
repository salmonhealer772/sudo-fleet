"""Robustness tests for the comm layer (the five hardening concerns).

Everything here runs against the in-memory fakes in `fakes.py` plus the
injected runner / clock / HTTP-door fakes -- no cluster, no sockets, no
sleeping on the clock.

Covered:

1. bounded retry on a transient failure: the host reach (whole ladder), the
   HTTP GET, and the MCP call each self-heal once and keep their FINAL failure
   contract;
2. the ClusterIP address book: never caches an empty answer, expires on its
   TTL (so a recreated Service is picked up), re-resolves after a dead GET, and
   keeps a known address through a bridge blip;
3. a `-watch` payload with NO valid event reports "appears down" (SidecarDown)
   instead of turning into a pile of `raw` pseudo-events -- while a genuinely
   mixed stream keeps its events;
4. an empty transcript (compressed) and an empty trail (full) are annotated,
   not silently blank.
"""

import io
import json
import urllib.error

import pytest

import real_transport as rt
from comm_tools import TRANSCRIPT_PATH
from fakes import FakeClock, FakeHttpDoor, FakeRunner, event

import check_agent as ca

WATCH_URL = "http://sudo-fa-glm-l-watch:8000/events"
MCP_URL = "http://sudo-fa-glm-l-mcp:8000/mcp"
HTML_ERROR = "<html><head><title>503 Service Unavailable</title></head></html>"

MCP_TOOLS_CALL_REPLY = json.dumps({
    "jsonrpc": "2.0",
    "result": {"content": [{"type": "text",
                            "text": json.dumps({"reply": "pong"})}]},
})


class ScriptedRunner(FakeRunner):
    """FakeRunner whose stdout is a script: one entry per host_command call."""

    def __init__(self, outputs, **kwargs):
        super().__init__(**kwargs)
        self.outputs = list(outputs)

    def __call__(self, cmd, timeout=None):
        super().__call__(cmd, timeout)
        return self.outputs.pop(0) if self.outputs else self.stdout


def address_book(runner, clock=None, **kwargs):
    """An AddressBookTransport with the clock and backoff off the real clock."""
    kwargs.setdefault("sleep", lambda _seconds: None)
    return ca.AddressBookTransport(runner=runner, now=clock or FakeClock(), **kwargs)


# --- 1. bounded retry: the host reach --------------------------------------

def test_host_command_retries_the_reach_ladder_after_a_failed_round():
    # Arrange: an entire first round fails (all 3 reaches), the retry lands.
    runner = FakeRunner(stdout="NAME  TYPE\n", fail_times=3)
    transport = rt.RealTransport(runner=runner, sleep=lambda _s: None)
    # Act
    out = transport.host_command(["kubectl", "get", "services", "-n", "default"])
    # Assert
    assert out == "NAME  TYPE\n"
    assert runner.count == 4        # 3 failed reaches + the retry that answered


def test_host_command_falls_through_the_ladder_within_one_round():
    # A single transient failure is absorbed by the NEXT reach, not by a retry.
    runner = FakeRunner(stdout="ok", fail_times=1)
    transport = rt.RealTransport(runner=runner, sleep=lambda _s: None)
    assert transport.host_command(["kubectl", "version"]) == "ok"
    assert runner.count == 2


def test_host_command_gives_up_after_bounded_retries_with_the_same_contract():
    runner = FakeRunner(fail_times=10_000)
    transport = rt.RealTransport(runner=runner, sleep=lambda _s: None)
    with pytest.raises(rt.HostBridgeError) as exc:
        transport.host_command(["kubectl", "get", "pods"])
    # every reach of every round was tried, and every attempt is reported
    assert runner.count == rt.DEFAULT_RETRIES * len(transport.bridge_commands(["x"]))
    assert len(exc.value.attempts) == runner.count


def test_host_command_backoff_is_bounded_and_off_the_clock():
    sleeps = []
    transport = rt.RealTransport(runner=FakeRunner(fail_times=10_000),
                                 sleep=sleeps.append)
    with pytest.raises(rt.HostBridgeError):
        transport.host_command(["kubectl", "get", "pods"])
    assert len(sleeps) == rt.DEFAULT_RETRIES - 1     # one short pause per retry
    assert sum(sleeps) <= 2.0                       # sane: a blip, not a hang


def test_host_command_retry_count_is_configurable():
    runner = FakeRunner(fail_times=10_000)
    transport = rt.RealTransport(runner=runner, sleep=lambda _s: None, retries=2)
    with pytest.raises(rt.HostBridgeError):
        transport.host_command(["kubectl", "get", "pods"])
    assert runner.count == 2 * len(transport.bridge_commands(["x"]))


def test_host_command_still_rejects_empty_argv_without_retrying():
    runner = FakeRunner()
    transport = rt.RealTransport(runner=runner, sleep=lambda _s: None)
    with pytest.raises(ValueError):
        transport.host_command([])
    assert runner.count == 0


# --- 1b. bounded retry: the HTTP GET and the MCP call ----------------------

def test_http_get_retries_a_connection_refused_then_succeeds(monkeypatch):
    door = FakeHttpDoor(body='{"ok": true}', fail_times=1)
    monkeypatch.setattr(rt.urllib.request, "urlopen", door)
    transport = rt.RealTransport(sleep=lambda _s: None)
    assert transport.http_get(WATCH_URL) == {"ok": True}
    assert door.count == 2


def test_http_get_raises_the_real_error_after_bounded_retries(monkeypatch):
    door = FakeHttpDoor(fail_times=10_000)
    monkeypatch.setattr(rt.urllib.request, "urlopen", door)
    transport = rt.RealTransport(sleep=lambda _s: None)
    with pytest.raises(ConnectionRefusedError):
        transport.http_get(WATCH_URL)
    assert door.count == rt.DEFAULT_RETRIES


def test_http_get_still_splits_a_non_json_body_into_lines(monkeypatch):
    door = FakeHttpDoor(body="not json at all\n")
    monkeypatch.setattr(rt.urllib.request, "urlopen", door)
    transport = rt.RealTransport(sleep=lambda _s: None)
    assert transport.http_get(WATCH_URL) == ["not json at all"]


def test_mcp_call_retries_a_failed_initialize_with_a_fresh_session(monkeypatch):
    door = FakeHttpDoor(body=MCP_TOOLS_CALL_REPLY, fail_times=1)
    monkeypatch.setattr(rt.urllib.request, "urlopen", door)
    transport = rt.RealTransport(sleep=lambda _s: None)
    result = transport.mcp_call(MCP_URL, "letta_prompt", {"prompt": "hi"})
    assert result == {"reply": "pong"}
    # 1 failed initialize, then initialize + notification + tools/call
    assert door.count == 4


def test_mcp_call_raises_after_bounded_retries(monkeypatch):
    door = FakeHttpDoor(fail_times=10_000)
    monkeypatch.setattr(rt.urllib.request, "urlopen", door)
    transport = rt.RealTransport(sleep=lambda _s: None)
    with pytest.raises(ConnectionRefusedError):
        transport.mcp_call(MCP_URL, "letta_prompt", {})
    assert door.count == rt.DEFAULT_RETRIES      # one initialize POST per round


# --- 2. the ClusterIP address book -----------------------------------------

def test_empty_cluster_ip_is_never_cached():
    # Arrange: the lookup answers with nothing (a failure, or no ClusterIP yet)
    runner = FakeRunner(stdout="")
    transport = address_book(runner)
    # Act + Assert: the URL is kept as given, and nothing is remembered
    assert transport._resolve_url(WATCH_URL) == WATCH_URL
    assert runner.count == 1
    transport._resolve_url(WATCH_URL)
    assert runner.count == 2                    # asked the cluster AGAIN
    assert transport._cluster_ips == {}


def test_cluster_ip_is_cached_until_the_ttl_then_re_resolved():
    runner = FakeRunner(stdout="10.43.0.7")
    clock = FakeClock()
    transport = address_book(runner, clock, cluster_ip_ttl=30.0)
    assert transport._resolve_url(WATCH_URL) == "http://10.43.0.7:8000/events"
    assert transport._resolve_url(WATCH_URL) == "http://10.43.0.7:8000/events"
    assert runner.count == 1                    # served from the address book
    # Act: the TTL expires AND the Service was recreated with a new ClusterIP
    clock.advance(31)
    runner.stdout = "10.43.0.99"
    # Assert: the new address is picked up instead of the dead one
    assert transport._resolve_url(WATCH_URL) == "http://10.43.0.99:8000/events"
    assert runner.count == 2


def test_stale_address_is_still_served_through_a_bridge_blip():
    runner = FakeRunner(stdout="10.43.0.7")
    clock = FakeClock()
    transport = address_book(runner, clock, cluster_ip_ttl=30.0)
    transport._resolve_url(WATCH_URL)
    # Act: the entry goes stale and the bridge is down while re-resolving
    clock.advance(31)
    runner.fail_times = 10_000
    # Assert: a bridge blip must not lose a working endpoint
    assert transport._resolve_url(WATCH_URL) == "http://10.43.0.7:8000/events"
    assert transport._cluster_ips["sudo-fa-glm-l-watch"][0] == "10.43.0.7"


def test_a_failed_get_drops_the_cached_ip_and_re_resolves(monkeypatch):
    # Arrange: the cached ClusterIP is dead, and the Service has a new one
    runner = ScriptedRunner(["10.43.0.7", "10.43.0.99"])
    door = FakeHttpDoor(body='{"ok": true}', fail_times=rt.DEFAULT_RETRIES)
    monkeypatch.setattr(rt.urllib.request, "urlopen", door)
    transport = ca.AddressBookTransport(runner=runner, sleep=lambda _s: None,
                                        now=FakeClock())
    # Act
    result = transport.http_get(WATCH_URL)
    # Assert: the dead address was retried, dropped, re-resolved, and used
    assert result == {"ok": True}
    assert door.urls == [WATCH_URL.replace("sudo-fa-glm-l-watch",
                                           "10.43.0.7")] * rt.DEFAULT_RETRIES + [
        WATCH_URL.replace("sudo-fa-glm-l-watch", "10.43.0.99")]
    assert transport._cluster_ips["sudo-fa-glm-l-watch"][0] == "10.43.0.99"


# --- 3. a down / non-ndjson sidecar ----------------------------------------

def test_a_sidecar_with_no_valid_events_reports_appears_down(env):
    env.watch["fa-glm-l"].events = [HTML_ERROR]
    with pytest.raises(ca.SidecarDown) as exc:
        ca.check_agent_live("fa-glm-l", n=10, fleet=env.fleet)
    assert "no valid events" in str(exc.value)
    assert "appears down" in str(exc.value)
    assert "503" in str(exc.value)              # the evidence is right there


def test_the_cli_reports_a_down_sidecar_clearly(env, capsys):
    env.watch["fa-glm-l"].events = [HTML_ERROR, ""]
    code = ca.main(["fa-glm-l", "--n", "10"], fleet_factory=lambda: env.fleet)
    captured = capsys.readouterr()
    assert code == 1
    assert "appears down" in captured.err
    assert "no valid events" in captured.err
    assert not captured.out.strip()             # no fake event table


def test_the_cli_reports_a_down_sidecar_as_json_when_asked(env, capsys):
    env.watch["fa-glm-l"].events = [HTML_ERROR]
    code = ca.main(["fa-glm-l", "--json"], fleet_factory=lambda: env.fleet)
    payload = json.loads(capsys.readouterr().out)
    assert code == 1
    assert payload["error"] == "sidecar_down"
    assert payload["sibling"] == "fa-glm-l"
    assert payload["raw_lines"] == 1


def test_a_mixed_stream_keeps_its_events_and_only_flags_the_stray_line(env):
    env.watch["fa-glm-l"].events = [
        event(1.0, "c1", "assistant", text="hi"), "trailing garbage"]
    trail = ca.check_agent_live("fa-glm-l", n=10, fleet=env.fleet)   # no raise
    assert [e["event"] for e in ca.normalize_events(trail)] == ["assistant", "raw"]


def test_an_empty_trail_is_not_a_down_sidecar(env):
    env.watch["fa-glm-l"].events = []
    assert ca.check_agent_live("fa-glm-l", n=10, fleet=env.fleet) == []
    assert not ca.sidecar_is_down([])


def test_the_cli_reports_an_unreachable_sidecar_without_a_traceback(env, capsys):
    def refuse(url, timeout=None):
        raise ConnectionRefusedError("connection refused")

    env.transport.http_get = refuse
    code = ca.main(["fa-glm-l", "--n", "5"], fleet_factory=lambda: env.fleet)
    captured = capsys.readouterr()
    assert code == 1
    assert "could not be reached" in captured.err
    assert "appears down" in captured.err
    assert not captured.out.strip()


def test_the_cli_reports_an_unreachable_sidecar_as_json_when_asked(env, capsys):
    def refuse(url, timeout=None):
        raise urllib.error.URLError("connection refused")

    env.transport.http_get = refuse
    code = ca.main(["fa-glm-l", "--json"], fleet_factory=lambda: env.fleet)
    payload = json.loads(capsys.readouterr().out)
    assert code == 1
    assert payload["error"] == "sidecar_unreachable"
    assert payload["sibling"] == "fa-glm-l"


def test_an_http_error_page_is_reported_as_down_with_its_status(env):
    def error_page(url, timeout=None):
        raise urllib.error.HTTPError(
            url, 503, "Service Unavailable", {},
            io.BytesIO(b"<html><body>503 Service Unavailable</body></html>\n"))

    env.transport.http_get = error_page
    with pytest.raises(ca.SidecarDown) as exc:
        ca.check_agent_live("fa-glm-l", n=5, fleet=env.fleet)
    assert "no valid events" in str(exc.value)
    assert "HTTP 503" in str(exc.value)
    assert exc.value.status == 503


def test_the_cli_reports_an_http_error_page_as_sidecar_down(env, capsys):
    def error_page(url, timeout=None):
        raise urllib.error.HTTPError(
            url, 404, "Not Found", {}, io.BytesIO(b"404 page not found\n"))

    env.transport.http_get = error_page
    code = ca.main(["fa-glm-l", "--json"], fleet_factory=lambda: env.fleet)
    payload = json.loads(capsys.readouterr().out)
    assert code == 1
    assert payload["error"] == "sidecar_down"
    assert payload["http_status"] == 404
    assert "404 page not found" in payload["sample"]


# --- 4. an empty trail is annotated, in BOTH modes --------------------------

def test_empty_full_trail_says_so(env, capsys):
    env.watch["fa-glm-l"].events = []
    code = ca.main(["fa-glm-l", "--n", "5"], fleet_factory=lambda: env.fleet)
    out = capsys.readouterr().out
    assert code == 0
    assert "0 events" in out
    assert "the trail is empty" in out


def test_empty_transcript_is_annotated_not_silent(env, capsys):
    env.host.set_file(TRANSCRIPT_PATH, "")
    code = ca.main(["fa-glm-l", "--mode", "compressed"],
                   fleet_factory=lambda: env.fleet)
    captured = capsys.readouterr()
    assert code == 0
    assert "0 transcript lines" in captured.out
    assert "no transcript" in captured.out
    assert "no transcript" in captured.err      # visible to a JSON consumer too


def test_empty_transcript_json_is_still_an_empty_list(env, capsys):
    env.host.set_file(TRANSCRIPT_PATH, "")
    code = ca.main(["fa-glm-l", "--mode", "compressed", "--json"],
                   fleet_factory=lambda: env.fleet)
    captured = capsys.readouterr()
    assert code == 0
    assert json.loads(captured.out) == []
    assert "no transcript" in captured.err
