"""The DuckDB lane's process (DESIGN.md): tickerplant subscriber, DuckDB ingest, analytics, and the
page's websocket.

    uv run python -m bridge [--port 5130] [--tp 5110] [--maxrows 60000000]

DuckDB has no streaming server, so this bridge is the part a DuckDB deployment has to build:
it subscribes to the tickerplant over kdb+ IPC (PyKX, unlicensed: no q runtime here), appends
each batch to an in-memory DuckDB on an ingest thread, measures lag after the insert commits,
runs the analytics every second on a worker thread (DTW in a worker process, which keeps
dtaidistance off the GIL that DuckDB's inserts need), and serves stats and results to the page.
When ingest falls behind it stops reading, so the tickerplant's queue limit drops rows for this
lane and counts them (tp.q), instead of memory here growing without bound.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import multiprocessing
import os
import queue
import signal
import sys
import threading
import time
from concurrent.futures import ProcessPoolExecutor

os.environ.setdefault("PYKX_UNLICENSED", "true")
import numpy as np
import pykx as kx
import websockets

from . import analytics as an
from .store import COLS, Store

log = logging.getLogger("bridge")
NS_DAY = 86_400 * 10**9
PENDING_MAX = 4_000_000  # rows queued for insert before the bridge stops reading


def ns_of_day() -> int:
    """Local nanoseconds since midnight: the tickerplant stamps "n"$.z.P on the same clock."""
    return (time.time_ns() + time.localtime().tm_gmtoff * 10**9) % NS_DAY


def columns(msg: object) -> dict[str, np.ndarray] | None:
    """A tickerplant upd message ((`upd;`telem;columns) as NumPy) to named columns, else None."""
    try:
        a = msg.np()
    except Exception:  # noqa: BLE001 - not a message we understand
        return None
    if len(a) != 3 or str(a[0]) != "upd":
        return None
    cols = list(a[2])
    if len(cols) != len(COLS):
        return None
    out = dict(zip(COLS, cols, strict=True))
    out["time"] = np.asarray(out["time"]).astype("timedelta64[ns]").astype(np.int64)
    out["stime"] = np.asarray(out["stime"]).astype("datetime64[ns]")
    out["uav"] = np.asarray(out["uav"], dtype=np.int32)
    for c in ("alt", "ias", "rpm", "imuz"):
        out[c] = np.asarray(out[c], dtype=np.float32)
    return out


class Lane:
    """State shared by the ingest thread, the analytics worker and the websocket handlers."""

    def __init__(self, store: Store) -> None:
        self.store = store
        self.n, self.hz = 1024, 200
        self.mode = an.CFG.get("mode", "tss")
        self.q: queue.Queue[dict[str, np.ndarray]] = queue.Queue()
        self.pending = 0
        self.lag: list[tuple[float, float, int]] = []  # (arrival s, lag ms, rows), last 5 s
        self.lag_lock = threading.Lock()
        self.rate, self.last_total, self.last_t = 0.0, 0, time.monotonic()
        self.dropped = 0
        self.stop = threading.Event()

    # --- ingest thread -------------------------------------------------------------------------
    def ingest_loop(self) -> None:
        while not self.stop.is_set():
            try:
                first = self.q.get(timeout=0.1)
            except queue.Empty:
                continue
            batch = [first]
            while True:  # drain everything waiting into one insert
                try:
                    batch.append(self.q.get_nowait())
                except queue.Empty:
                    break
            merged = {c: np.concatenate([b[c] for b in batch]) for c in COLS}
            n = self.store.insert(merged)
            now = ns_of_day()
            with self.lag_lock:
                t = time.monotonic()
                for b in batch:
                    self.lag.append((t, ((now - int(b["time"][0])) % NS_DAY) / 1e6, len(b["uav"])))
            self.pending -= n
            self.store.trim()

    def lag_stats(self) -> dict[str, float | None]:
        with self.lag_lock:
            cut = time.monotonic() - 5
            self.lag = [x for x in self.lag if x[0] > cut]
            if not self.lag:
                return {"p50": None, "p99": None}
            v = np.array([x[1] for x in self.lag])
            w = np.array([x[2] for x in self.lag], dtype=np.float64)
        o = np.argsort(v)
        c = np.cumsum(w[o])
        return {f"p{int(p * 100)}": float(v[o][np.searchsorted(c, p * c[-1])]) for p in (0.5, 0.99)}

    def stats(self) -> dict:
        now = time.monotonic()
        total = self.store.total
        r = (total - self.last_total) / max(now - self.last_t, 1e-3)
        self.rate, self.last_total, self.last_t = 0.6 * self.rate + 0.4 * r, total, now
        return {
            "type": "stats",
            "lane": "duckdb",
            "n": self.n,
            "hz": self.hz,
            "demand": self.n * self.hz,
            "rate": self.rate,
            "total": total,
            "held": self.store.held,
            "mem": self.store.mem(),
            "lag": self.lag_stats(),
            "dropped": self.dropped,
            "pending": self.pending,
            "maxrows": self.store.maxrows,
            "tap": self.store.tap(),
        }


async def run(args: argparse.Namespace) -> None:
    # DTW runs in a worker process (analytics.EXECUTOR); start it now so the first pass doesn't wait
    an.EXECUTOR = ProcessPoolExecutor(
        1,
        mp_context=multiprocessing.get_context("spawn"),
        initializer=an.exit_with_parent,
        initargs=(os.getpid(),),
    )
    an.EXECUTOR.submit(int).result()
    store = Store(args.maxrows)
    lane = Lane(store)
    asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, lane.stop.set)  # stop.sh
    clients: set = set()

    async def send(msg: dict) -> None:
        if clients:
            data = json.dumps(msg, default=float)
            websockets.broadcast(clients, data)

    async def handler(ws) -> None:
        clients.add(ws)
        try:
            async for raw in ws:
                try:
                    d = json.loads(raw)
                except ValueError:
                    continue
                c = d.get("cmd")
                if c == "fleet":
                    lane.n, lane.hz = int(d["n"]), int(d["hz"])
                    lane.rate = 0.0
                elif c == "mode" and d.get("mode") in ("tss", "dtw"):
                    lane.mode = d["mode"]
                    await send({"type": "mode", "lane": "duckdb", "mode": lane.mode})
                elif c == "clear":
                    t = time.perf_counter()
                    n = await asyncio.to_thread(store.clear)
                    await send(
                        {
                            "type": "cleared",
                            "lane": "duckdb",
                            "rows": n,
                            "ms": round((time.perf_counter() - t) * 1000),
                        }
                    )
                elif c == "keep":
                    await asyncio.to_thread(store.set_keep, int(d["n"]))
                elif c == "last":
                    rows = await asyncio.to_thread(store.last_rows, int(d["n"]))
                    await ws.send(
                        json.dumps(
                            {
                                "type": "last",
                                "lane": "duckdb",
                                "total": store.total,
                                "held": store.held,
                                "rows": rows,
                            }
                        )
                    )
                elif c == "shutdown":
                    await send({"type": "shutdown", "lane": "duckdb"})
                    lane.stop.set()
        finally:
            clients.discard(ws)

    server = await websockets.serve(handler, "localhost", args.port, max_size=2**24)
    con = await kx.RawQConnection(host="localhost", port=args.tp, no_ctx=True)
    con(".u.sub", "telem", "duckdb")
    con.poll_send()
    tp = kx.SyncQConnection(host="localhost", port=args.tp, no_ctx=True)
    threading.Thread(target=lane.ingest_loop, name="ingest", daemon=True).start()
    log.info("DuckDB lane: bridge on :%d, subscribed to tickerplant :%d", args.port, args.tp)
    print(f"DuckDB lane: bridge on {args.port}, subscribed to tickerplant {args.tp}", flush=True)

    async def feed() -> None:
        while not lane.stop.is_set():
            if lane.pending > PENDING_MAX:  # ingest is behind: stop reading, let tp.q drop
                await asyncio.sleep(0.005)
                continue
            got = con.poll_recv()
            if got is None:
                await asyncio.sleep(0.001)
                continue
            cols = columns(got)
            if cols is not None:
                lane.pending += len(cols["uav"])
                lane.q.put(cols)
            # yield after every batch: when the tickerplant always has data waiting, a loop that
            # only yields on an empty socket starves the stats, analytics and the page's socket
            await asyncio.sleep(0)

    async def stats_loop() -> None:
        while not lane.stop.is_set():
            try:  # off the event loop: a busy tickerplant can take a while to answer
                d = await asyncio.to_thread(lambda: tp(".u.drops[]").py())
                lane.dropped = int(d.get("duckdb", 0))
            except Exception as e:  # noqa: BLE001 - the tickerplant may be gone at shutdown
                log.debug("drop count unavailable: %s", e)
            await send(await asyncio.to_thread(lane.stats))
            await asyncio.sleep(0.25)

    async def analytics_loop() -> None:
        while not lane.stop.is_set():
            t = time.monotonic()
            try:
                r = await asyncio.to_thread(
                    an.analyse, store, min(lane.n, an.CFG["watch"]), lane.mode, lane.hz
                )
            except Exception as e:  # noqa: BLE001 - report, keep serving
                r = {"type": "analytics", "lane": "duckdb", "error": str(e)}
            await send(r)
            await asyncio.sleep(max(0.0, an.CFG["every_ms"] / 1000 - (time.monotonic() - t)))

    async def watch_stop() -> None:
        while not lane.stop.is_set():
            await asyncio.sleep(0.2)
        await asyncio.sleep(0.2)
        server.close()

    try:
        await asyncio.gather(feed(), stats_loop(), analytics_loop(), watch_stop())
    finally:
        an.EXECUTOR.shutdown(cancel_futures=True)


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--port", type=int, default=5130)
    p.add_argument("--tp", type=int, default=5110)
    p.add_argument("--maxrows", type=int, default=60_000_000)
    args = p.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        pass
    sys.exit(0)
