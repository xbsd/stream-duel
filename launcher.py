"""The launcher: serves the pages and lets them start Stream Duel again after "Shut down" (DESIGN.md).

    uv run python launcher.py [--port 5100]

./start.sh starts it and ./stop.sh stops it. The pages' "Shut down" stops everything else and
leaves this running, so the pages stay up and can start everything again.

On one port it does two things:
    http://localhost:5100/    the pages: / goes to the first, fleet-wall.html. It serves the three
                              pages and common.js and nothing else from the folder.
    ws://localhost:5100       the pages' Start and Shut down
It listens on localhost only and answers only requests addressed to localhost. It runs nothing
but start.sh and stop.sh, and takes commands only from a page opened from a file or from
localhost (a website elsewhere can't use it).

Messages, as JSON over the websocket:
    page -> launcher   {"cmd": "start"} | {"cmd": "stop"} | {"cmd": "status"}
    launcher -> page   {"type": "launcher", "state": "idle" | "starting" | "stopping" | "failed",
                        "detail": last line the script printed, "root": this folder}
"""

from __future__ import annotations

import argparse
import asyncio
import email.utils
import http
import json
import logging
import re
from pathlib import Path

import websockets
from websockets.datastructures import Headers
from websockets.http11 import Request, Response

ROOT = Path(__file__).resolve().parent
log = logging.getLogger("launcher")
# a page opened as a file sends Origin "null"; scripts on this machine send none
LOCAL = re.compile(r"^https?://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$")
HOST = re.compile(r"^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$")
# what the site serves, in the order of the pages' bar; anything else in the folder is a 404
FILES = {
    "fleet-wall.html": "text/html; charset=utf-8",
    "live-data.html": "text/html; charset=utf-8",
    "stream-duel.html": "text/html; charset=utf-8",
    "common.js": "text/javascript; charset=utf-8",
}
HOME = "fleet-wall.html"


def allowed(origin: str | None) -> bool:
    return origin is None or origin == "null" or bool(LOCAL.match(origin))


def local_host(host: str | None) -> bool:
    """True if a request names this machine. A website that points its own name at 127.0.0.1 (DNS
    rebinding) still sends that name, so it is refused."""
    return bool(host and HOST.match(host))


def reply(
    status: int, body: bytes | str, ctype: str = "text/plain; charset=utf-8", **more: str
) -> Response:
    """A plain HTTP response; the browser opens a new connection for the next file."""
    s = http.HTTPStatus(status)
    data = body.encode() if isinstance(body, str) else body
    headers = Headers(
        [
            ("Date", email.utils.formatdate(usegmt=True)),
            ("Connection", "close"),
            ("Content-Length", str(len(data))),
            ("Content-Type", ctype),
            ("Cache-Control", "no-cache"),  # an edited page shows on the next reload
            ("X-Content-Type-Options", "nosniff"),
        ]
    )
    for k, v in more.items():
        headers[k] = v
    return Response(s.value, s.phrase, headers, data)


class Launcher:
    """Runs start.sh or stop.sh (one at a time) and tells every connected page how it went."""

    def __init__(self, root: Path = ROOT) -> None:
        self.root = root
        self.state, self.detail = "idle", ""
        self.clients: set = set()
        self.busy = asyncio.Lock()

    def status(self) -> str:
        return json.dumps(
            {"type": "launcher", "state": self.state, "detail": self.detail, "root": str(self.root)}
        )

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

    def page(self, path: str) -> Response:
        """A page of the site, by URL path."""
        name = path.split("?", 1)[0].split("#", 1)[0].lstrip("/")
        if name == "":
            return reply(302, "", Location="/" + HOME)
        if name not in FILES:  # an exact name, so nothing else in the folder can be reached
            return reply(404, "Not a Stream Duel page\n")
        try:
            data = (self.root / name).read_bytes()
        except OSError:
            return reply(404, "Not a Stream Duel page\n")
        return reply(200, data, FILES[name])

    def process_request(self, connection, request: Request) -> Response | None:
        """Pages for a browser, the handshake for a websocket; nothing for another site."""
        if not local_host(request.headers.get("Host")):
            log.warning("refused a request for %s", request.headers.get("Host"))
            return reply(403, "Stream Duel is local only\n")
        if request.headers.get("Upgrade", "").lower() != "websocket":
            return self.page(request.path)
        origin = request.headers.get("Origin")
        if not allowed(origin):
            log.warning("refused a page from %s", origin)
            return reply(403, "Stream Duel's launcher is local only\n")
        return None


async def serve(port: int, root: Path = ROOT) -> None:
    launcher = Launcher(root)
    async with websockets.serve(
        launcher.handler, "localhost", port, process_request=launcher.process_request
    ) as server:
        print(f"launcher on {port}: the pages are at http://localhost:{port}/", flush=True)
        await server.serve_forever()


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    p.add_argument("--port", type=int, default=5100)
    args = p.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    logging.getLogger("websockets").setLevel(logging.WARNING)  # not a line per file served
    try:
        asyncio.run(serve(args.port))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
