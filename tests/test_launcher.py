"""The launcher: the pages it serves, who may use it, and what it reports while it runs start.sh
and stop.sh.

Runs against stand-in scripts and pages in a temporary folder, never the real start.sh.
"""

from __future__ import annotations

import asyncio
import json
import stat
from pathlib import Path

import pytest
import websockets

from launcher import FILES, HOME, Launcher, allowed, local_host


@pytest.mark.parametrize(
    "origin", [None, "null", "http://localhost:8000", "http://127.0.0.1", "http://[::1]:5173"]
)
def test_pages_from_a_file_or_localhost_are_allowed(origin):
    assert allowed(origin)


@pytest.mark.parametrize(
    "origin", ["https://example.com", "http://localhost.example.com", "http://192.168.1.5"]
)
def test_other_sites_are_refused(origin):
    assert not allowed(origin)


def script(folder: Path, name: str, body: str) -> None:
    f = folder / name
    f.write_text(f"#!/bin/sh\n{body}\n")
    f.chmod(f.stat().st_mode | stat.S_IXUSR)


async def session(root: Path, origin: str | None, cmd: str | None, n: int) -> list[dict]:
    """Connect as a page would, optionally send a command, and return the first n messages."""
    launcher = Launcher(root)
    async with websockets.serve(
        launcher.handler, "localhost", 0, process_request=launcher.process_request
    ) as srv:
        port = srv.sockets[0].getsockname()[1]
        async with websockets.connect(f"ws://localhost:{port}", origin=origin) as ws:
            got = [json.loads(await ws.recv())]
            if cmd:
                await ws.send(json.dumps({"cmd": cmd}))
            while len(got) < n:
                got.append(json.loads(await asyncio.wait_for(ws.recv(), 10)))
            return got


def test_start_reports_starting_then_the_scripts_last_line(tmp_path):
    script(tmp_path, "start.sh", 'echo "building"\necho "Running: everything"')
    got = asyncio.run(session(tmp_path, "null", "start", 3))
    assert [m["state"] for m in got] == ["idle", "starting", "idle"]
    assert got[-1]["detail"] == "Running: everything"
    assert got[0]["root"] == str(tmp_path)  # a page served over http learns the folder


def test_stop_keeps_the_launcher(tmp_path):
    script(tmp_path, "stop.sh", 'echo "args: $*"')
    got = asyncio.run(session(tmp_path, None, "stop", 3))
    assert [m["state"] for m in got] == ["idle", "stopping", "idle"]
    assert got[-1]["detail"] == "args: --keep-launcher"


def test_a_failing_start_is_reported(tmp_path):
    script(tmp_path, "start.sh", 'echo "Can\'t find q" >&2\nexit 1')
    got = asyncio.run(session(tmp_path, "null", "start", 3))
    assert got[-1] == {
        "type": "launcher",
        "state": "failed",
        "detail": "Can't find q",
        "root": str(tmp_path),
    }


def test_a_page_from_another_site_cannot_connect(tmp_path):
    with pytest.raises(websockets.exceptions.InvalidStatus) as e:
        asyncio.run(session(tmp_path, "https://example.com", None, 1))
    assert e.value.response.status_code == 403


# ---- the site ----


async def fetch(root: Path, requests: list[tuple[str, str]]) -> list[tuple[int, dict, bytes]]:
    """GET each (path, Host) as a browser would; return (status, headers, body) for each."""
    launcher = Launcher(root)
    out = []
    async with websockets.serve(
        launcher.handler, "localhost", 0, process_request=launcher.process_request
    ) as srv:
        port = srv.sockets[0].getsockname()[1]
        for path, host in requests:
            r, w = await asyncio.open_connection("localhost", port)
            host = host.replace("PORT", str(port))
            w.write(f"GET {path} HTTP/1.1\r\nHost: {host}\r\nAccept: text/html\r\n\r\n".encode())
            await w.drain()
            raw = await asyncio.wait_for(r.read(), 10)  # the launcher closes after each reply
            w.close()
            head, _, body = raw.partition(b"\r\n\r\n")
            lines = head.decode().split("\r\n")
            headers = dict(line.split(": ", 1) for line in lines[1:])
            out.append((int(lines[0].split()[1]), headers, body))
    return out


@pytest.fixture
def site(tmp_path):
    for name in FILES:
        (tmp_path / name).write_text(f"<!-- {name} -->")
    for other in ("README.md", "config.json", "start.sh"):
        (tmp_path / other).write_text("not for the browser")
    (tmp_path / "logs").mkdir()
    (tmp_path / "logs" / "rdb.log").write_text("not for the browser")
    return tmp_path


def test_the_site_serves_the_pages(site):
    got = asyncio.run(fetch(site, [("/" + n, "localhost:PORT") for n in FILES]))
    for name, (status, headers, body) in zip(FILES, got, strict=True):
        assert status == 200 and body == f"<!-- {name} -->".encode()
        assert headers["Content-Type"] == FILES[name] and headers["Cache-Control"] == "no-cache"
    assert FILES["common.js"].startswith("text/javascript")


def test_the_root_goes_to_the_first_page(site):
    (status, headers, _), (s2, h2, _) = asyncio.run(
        fetch(site, [("/", "localhost:PORT"), ("/?fleet=1", "127.0.0.1:PORT")])
    )
    assert status == 302 and headers["Location"] == "/fleet-wall.html" == "/" + HOME
    assert s2 == 302 and h2["Location"] == "/" + HOME


def test_a_query_string_is_ignored(site):
    [(status, _, body)] = asyncio.run(fetch(site, [("/live-data.html?x=1#top", "[::1]:PORT")]))
    assert status == 200 and body == b"<!-- live-data.html -->"


@pytest.mark.parametrize(
    "path",
    [
        "/README.md",
        "/config.json",
        "/start.sh",
        "/logs/rdb.log",
        "/../stream-duel.html",
        "/%2e%2e/start.sh",
        "/launcher.py",
        "/favicon.ico",
        "//etc/passwd",
    ],
)
def test_nothing_else_in_the_folder_is_served(site, path):
    [(status, _, body)] = asyncio.run(fetch(site, [(path, "localhost:PORT")]))
    assert status == 404 and b"not for the browser" not in body


def test_a_missing_page_is_a_404(tmp_path):
    [(status, _, _)] = asyncio.run(fetch(tmp_path, [("/stream-duel.html", "localhost:PORT")]))
    assert status == 404


@pytest.mark.parametrize(
    "host", ["evil.example:PORT", "localhost.evil.example", "192.168.1.5:PORT", ""]
)
def test_a_request_for_another_host_is_refused(site, host):
    # a website that points its own name at 127.0.0.1 (DNS rebinding) still sends that name
    [(status, _, body)] = asyncio.run(fetch(site, [("/stream-duel.html", host)]))
    assert status == 403 and b"<!--" not in body


@pytest.mark.parametrize("host", ["localhost", "localhost:5100", "127.0.0.1:5100", "[::1]:5100"])
def test_local_hosts(host):
    assert local_host(host)
