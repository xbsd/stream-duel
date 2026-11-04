"""The launcher: who may use it, and what it reports while it runs start.sh and stop.sh.

Runs against stand-in scripts in a temporary folder, never the real start.sh.
"""

from __future__ import annotations

import asyncio
import json
import stat
from pathlib import Path

import pytest
import websockets

from launcher import Launcher, allowed, check_origin


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
        launcher.handler, "localhost", 0, process_request=check_origin
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


def test_stop_keeps_the_launcher(tmp_path):
    script(tmp_path, "stop.sh", 'echo "args: $*"')
    got = asyncio.run(session(tmp_path, None, "stop", 3))
    assert [m["state"] for m in got] == ["idle", "stopping", "idle"]
    assert got[-1]["detail"] == "args: --keep-launcher"


def test_a_failing_start_is_reported(tmp_path):
    script(tmp_path, "start.sh", 'echo "Can\'t find q" >&2\nexit 1')
    got = asyncio.run(session(tmp_path, "null", "start", 3))
    assert got[-1] == {"type": "launcher", "state": "failed", "detail": "Can't find q"}


def test_a_page_from_another_site_cannot_connect(tmp_path):
    with pytest.raises(websockets.exceptions.InvalidStatus) as e:
        asyncio.run(session(tmp_path, "https://example.com", None, 1))
    assert e.value.response.status_code == 403
