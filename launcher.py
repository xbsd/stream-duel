"""The launcher: lets the page start Stream Duel again after "Shut down" (DESIGN.md).

    uv run python launcher.py [--port 5100]

./start.sh starts it and ./stop.sh stops it. The page's "Shut down" stops everything else and
leaves this running, so the page can start everything again. It listens on localhost only, runs
nothing but start.sh and stop.sh, and accepts the page when it's opened from a file or from
localhost (a website elsewhere can't use it).

Messages, as JSON over a websocket:
    page -> launcher   {"cmd": "start"} | {"cmd": "stop"} | {"cmd": "status"}
    launcher -> page   {"type": "launcher", "state": "idle" | "starting" | "stopping" | "failed",
                        "detail": last line the script printed}
"""

from __future__ import annotations

import argparse
import asyncio
import http
import json
import logging
import re
from pathlib import Path

import websockets

ROOT = Path(__file__).resolve().parent
log = logging.getLogger("launcher")
# a page opened as a file sends Origin "null"; scripts on this machine send none
LOCAL = re.compile(r"^https?://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$")


def allowed(origin: str | None) -> bool:
    return origin is None or origin == "null" or bool(LOCAL.match(origin))


class Launcher:
    """Runs start.sh or stop.sh (one at a time) and tells every connected page how it went."""

    def __init__(self, root: Path = ROOT) -> None:
        self.root = root
        self.state, self.detail = "idle", ""
        self.clients: set = set()
        self.busy = asyncio.Lock()

    def status(self) -> str:
        return json.dumps({"type": "launcher", "state": self.state, "detail": self.detail})

    def tell(self) -> None:
        websockets.broadcast(self.clients, self.status())

    async def run(self, state: str, *args: str) -> None:
        if self.busy.locked():  # already starting or stopping
            return
        async with self.busy:
            self.state, self.detail = state, ""
            self.tell()
            log.info("%s: %s", state, " ".join(args))
            p = await asyncio.create_subprocess_exec(
                *args,
                cwd=self.root,
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            out, _ = await p.communicate()
            lines = out.decode(errors="replace").strip().splitlines()
            self.state = "idle" if p.returncode == 0 else "failed"
            self.detail = lines[-1] if lines else ""
            log.info("%s (exit %s): %s", self.state, p.returncode, self.detail)
            self.tell()

    async def handler(self, ws) -> None:
        self.clients.add(ws)
        try:
            await ws.send(self.status())
            async for raw in ws:
                try:
                    cmd = json.loads(raw).get("cmd")
                except (ValueError, AttributeError):
                    continue
                if cmd == "start":
                    asyncio.create_task(self.run("starting", "./start.sh"))
                elif cmd == "stop":
                    asyncio.create_task(self.run("stopping", "./stop.sh", "--keep-launcher"))
                elif cmd == "status":
                    await ws.send(self.status())
        finally:
            self.clients.discard(ws)


def check_origin(connection, request):
    """Refuse the websocket handshake to any page not opened from a file or from localhost."""
    origin = request.headers.get("Origin")
    if not allowed(origin):
        log.warning("refused a page from %s", origin)
        return connection.respond(
            http.HTTPStatus.FORBIDDEN, "Stream Duel's launcher is local only\n"
        )
    return None


async def serve(port: int, root: Path = ROOT) -> None:
    launcher = Launcher(root)
    async with websockets.serve(
        launcher.handler, "localhost", port, process_request=check_origin
    ) as server:
        print(f"launcher on {port}: the page can start and stop Stream Duel", flush=True)
        await server.serve_forever()


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    p.add_argument("--port", type=int, default=5100)
    args = p.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    try:
        asyncio.run(serve(args.port))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
