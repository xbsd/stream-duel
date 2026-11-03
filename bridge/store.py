"""The DuckDB lane's store: an in-memory DuckDB table with telemetry-kit's schema (DESIGN.md).

`time` is the tickerplant stamp as nanoseconds since midnight (q timespan), `stime` the sample
time. Rows arrive in tickerplant order, so `time` only grows and DuckDB's zone maps let the
analytics window skip everything older.
"""

from __future__ import annotations

import threading
from collections import deque
from dataclasses import dataclass

import duckdb
import numpy as np

SCHEMA = (
    "CREATE TABLE telem(time BIGINT, stime TIMESTAMP_NS, uav INTEGER, "
    "alt FLOAT, ias FLOAT, rpm FLOAT, imuz FLOAT)"
)
COLS = ("time", "stime", "uav", "alt", "ias", "rpm", "imuz")


@dataclass
class Window:
    """The newest `secs` of every watched drone: one row per drone, newest sample last.

    Each matrix is (drones, n) float64 at `hz`; `newest` is the newest sample time (datetime64 ns).
    """

    uav: np.ndarray
    newest: np.datetime64
    hz: int
    n: int
    alt: np.ndarray
    ias: np.ndarray
    rpm: np.ndarray
    imuz: np.ndarray


class Store:
    """In-memory DuckDB table plus the bookkeeping the page's stats need.

    Thread-safe: every thread gets its own DuckDB cursor; the row count and trim state are
    guarded by a lock.
    """

    def __init__(self, maxrows: int = 60_000_000) -> None:
        self.con = duckdb.connect()
        self.con.execute(SCHEMA)
        self.maxrows = maxrows
        self.keep = 2 * maxrows // 3
        self.held = 0
        self.total = 0
        self.batches: deque[tuple[int, int]] = deque()  # (first tickerplant time, rows)
        self.lock = threading.Lock()
        self.local = threading.local()

    def cursor(self) -> duckdb.DuckDBPyConnection:
        cur = getattr(self.local, "cur", None)
        if cur is None:
            cur = self.local.cur = self.con.cursor()
        return cur

    def insert(self, batch: dict[str, np.ndarray]) -> int:
        """Append one batch (columns as in COLS); returns its row count once committed."""
        n = len(batch["uav"])
        if n == 0:
            return 0
        self.cursor().execute("INSERT INTO telem SELECT * FROM batch")
        with self.lock:
            self.held += n
            self.total += n
            self.batches.append((int(batch["time"][0]), n))
        return n

    def set_keep(self, maxrows: int) -> None:
        with self.lock:
            self.maxrows, self.keep = maxrows, 2 * maxrows // 3
        self.trim()

    def trim(self) -> int:
        """Past maxrows, keep the newest two thirds (as the RDB does); returns rows removed."""
        with self.lock:
            if self.held <= self.maxrows:
                return 0
            drop, cutoff = 0, None
            while self.batches and self.held - drop > self.keep:
                t, n = self.batches.popleft()
                drop += n
                cutoff = t
            if cutoff is None:
                return 0
            nxt = self.batches[0][0] if self.batches else cutoff + 1
        self.cursor().execute("DELETE FROM telem WHERE time < ?", [nxt])
        with self.lock:
            self.held -= drop
        return drop

    def clear(self) -> int:
        with self.lock:
            n, self.held, self.total = self.held, 0, 0
            self.batches.clear()
        self.cursor().execute("DELETE FROM telem")
        return n

    def tap(self, n: int = 8) -> list[dict]:
        """The newest n rows, newest last (as the RDB's tap)."""
        with self.lock:
            if not self.batches:
                return []
            since = self.batches[-1][0]
        rows = (
            self.cursor()
            .execute(
                "SELECT time, uav, alt, ias, rpm, imuz FROM telem WHERE time >= ? "
                "ORDER BY time DESC, rowid DESC LIMIT ?",
                [since, n],
            )
            .fetchall()
        )
        return [
            {"time": _span(t), "uav": u, "alt": a, "ias": i, "rpm": r, "imuz": z}
            for t, u, a, i, r, z in reversed(rows)
        ]

    def last_rows(self, n: int) -> list[dict]:
        rows = (
            self.cursor()
            .execute(
                "SELECT time, stime, uav, alt, ias, rpm, imuz FROM telem "
                "ORDER BY time DESC, rowid DESC LIMIT ?",
                [min(n, 500)],
            )
            .fetchall()
        )
        return [
            {"time": _span(t), "stime": str(s), "uav": u, "alt": a, "ias": i, "rpm": r, "imuz": z}
            for t, s, u, a, i, r, z in rows
        ]

    def mem(self) -> int:
        """Bytes DuckDB holds in memory."""
        return int(
            self.cursor()
            .execute("SELECT coalesce(sum(memory_usage_bytes), 0) FROM duckdb_memory()")
            .fetchone()[0]
        )

    def window(self, watch: int, secs: float, hz: int) -> Window | None:
        """The newest `secs` seconds of drones 1..watch, extracted with SQL (the DuckDB way)."""
        with self.lock:
            if not self.batches:
                return None
            last = self.batches[-1][0]
        since = last - int((secs + 0.5) * 1e9)
        r = (
            self.cursor()
            .execute(
                "SELECT uav, stime, alt, ias, rpm, imuz FROM telem "
                "WHERE time >= ? AND uav <= ? ORDER BY uav, stime",
                [since, watch],
            )
            .fetchnumpy()
        )
        return window_from_rows(r, secs, hz)


def window_from_rows(r: dict[str, np.ndarray], secs: float, hz: int) -> Window | None:
    """Group rows (sorted by uav, stime) into per-drone matrices of the newest `secs`, trimmed to
    the shortest drone's length (as analytics.q's win does).

    Every drone's window ends at the newest sample time all drones have reached, so drones whose
    feed handler shard published a little later are not shifted against the others."""
    uav = np.asarray(r["uav"])
    if len(uav) == 0:
        return None
    stime = np.asarray(r["stime"]).astype("datetime64[ns]")
    _, first, count = np.unique(uav, return_index=True, return_counts=True)
    newest = stime[first + count - 1].min()  # rows are sorted by stime within each drone
    keep = (stime > newest - np.timedelta64(int(secs * 1e9), "ns")) & (stime <= newest)
    uav, stime = uav[keep], stime[keep]
    cols = {c: np.asarray(r[c])[keep] for c in ("alt", "ias", "rpm", "imuz")}
    ids, starts, counts = np.unique(uav, return_index=True, return_counts=True)
    n = int(counts.min())
    if n < 16:
        return None
    ends = starts + counts
    idx = np.concatenate([np.arange(e - n, e) for e in ends]).reshape(len(ids), n)
    mats = {c: v[idx].astype(np.float64) for c, v in cols.items()}
    return Window(uav=ids.astype(np.int64), newest=newest, hz=hz, n=n, **mats)


def _span(ns: int) -> str:
    """Nanoseconds since midnight as q prints a timespan: 0D12:34:56.789012345."""
    s, f = divmod(int(ns), 1_000_000_000)
    h, s = divmod(s, 3600)
    m, s = divmod(s, 60)
    return f"0D{h:02d}:{m:02d}:{s:02d}.{f:09d}"
