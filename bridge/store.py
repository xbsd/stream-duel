"""The DuckDB lane's store: two in-memory DuckDB tables with schema.q's columns (DESIGN.md).

`telem` holds altitude, airspeed and vertical acceleration at 50 Hz, `rotor` rotor speed at 100 Hz.
`time` is the tickerplant stamp as nanoseconds since midnight (q timespan), `stime` the sample time.
Rows arrive in tickerplant order, so `time` only grows and DuckDB's zone maps let the analytics
window skip everything older.
"""

from __future__ import annotations

import threading
from collections import deque
from dataclasses import dataclass

import duckdb
import numpy as np

SCHEMA = {
    "telem": "CREATE TABLE telem(time BIGINT, stime TIMESTAMP_NS, uav INTEGER, "
    "alt FLOAT, ias FLOAT, imuz FLOAT)",
    "rotor": "CREATE TABLE rotor(time BIGINT, stime TIMESTAMP_NS, uav INTEGER, rpm FLOAT)",
}
COLS = {
    "telem": ("time", "stime", "uav", "alt", "ias", "imuz"),
    "rotor": ("time", "stime", "uav", "rpm"),
}
METRICS = {t: len(c) - 3 for t, c in COLS.items()}  # measured values per row: telem 3, rotor 1


@dataclass
class Window:
    """The newest `secs` of every watched drone's telemetry and its newest `nr` rotor samples: one
    row per drone, newest sample last.

    alt, ias, imuz are (drones, n) float64 at 50 Hz; rpm is (drones, nr) at 100 Hz, or (drones, 0)
    when some drone has fewer rotor samples than asked for. `newest` is the newest telemetry
    sample time (datetime64 ns).
    """

    uav: np.ndarray
    newest: np.datetime64
    n: int
    alt: np.ndarray
    ias: np.ndarray
    imuz: np.ndarray
    nr: int
    rpm: np.ndarray


class Store:
    """In-memory DuckDB tables plus the bookkeeping the page's stats need.

    Thread-safe: every thread gets its own DuckDB cursor; the row counts and trim state are guarded
    by a lock.
    """

    def __init__(self, maxrows: int = 60_000_000) -> None:
        self.con = duckdb.connect()
        for ddl in SCHEMA.values():
            self.con.execute(ddl)
        self.maxrows = maxrows
        self.counts = {t: 0 for t in COLS}  # rows held per table
        self.total = 0  # rows stored since start or clear
        self.vtotal = 0  # measured values stored since start or clear
        self.batches: dict[str, deque[tuple[int, int]]] = {t: deque() for t in COLS}
        self.lock = threading.Lock()
        self.local = threading.local()

    @property
    def held(self) -> int:
        return sum(self.counts.values())

    def cursor(self) -> duckdb.DuckDBPyConnection:
        cur = getattr(self.local, "cur", None)
        if cur is None:
            cur = self.local.cur = self.con.cursor()
        return cur

    def insert(self, table: str, batch: dict[str, np.ndarray]) -> int:
        """Append one batch to `table` (columns as in COLS); returns its row count once committed."""
        n = len(batch["uav"])
        if n == 0:
            return 0
        self.cursor().execute(f"INSERT INTO {table} SELECT * FROM batch")
        with self.lock:
            self.counts[table] += n
            self.total += n
            self.vtotal += n * METRICS[table]
            self.batches[table].append((int(batch["time"][0]), n))
        return n

    def set_keep(self, maxrows: int) -> None:
        with self.lock:
            self.maxrows = maxrows
        self.trim()

    def trim(self) -> int:
        """Past maxrows, each table keeps its newest two thirds (as the RDB does); returns rows removed."""
        cuts = {}
        with self.lock:
            if self.held <= self.maxrows:
                return 0
            for t, q in self.batches.items():
                keep, drop = 2 * self.counts[t] // 3, 0
                while q and self.counts[t] - drop > keep:
                    drop += q.popleft()[1]
                if drop:
                    cuts[t] = (q[0][0] if q else None, drop)
        for t, (nxt, drop) in cuts.items():
            if nxt is None:
                self.cursor().execute(f"DELETE FROM {t}")
            else:
                self.cursor().execute(f"DELETE FROM {t} WHERE time < ?", [nxt])
            with self.lock:
                self.counts[t] -= drop
        return sum(d for _, d in cuts.values())

    def clear(self) -> int:
        with self.lock:
            n = self.held
            self.counts = {t: 0 for t in COLS}
            self.total = self.vtotal = 0
            for q in self.batches.values():
                q.clear()
        for t in COLS:
            self.cursor().execute(f"DELETE FROM {t}")
        return n

    def _newest(self, table: str, n: int) -> list[tuple]:
        with self.lock:
            if not self.batches[table]:
                return []
            since = self.batches[table][-1][0]
        cols = ", ".join(COLS[table])
        return (
            self.cursor()
            .execute(
                f"SELECT {cols} FROM {table} WHERE time >= ? ORDER BY time DESC, rowid DESC LIMIT ?",
                [since, n],
            )
            .fetchall()
        )

    def tap(self, n: int = 4) -> list[dict]:
        """The newest n rows of each table, oldest first (as the RDB's tap): a value a table
        doesn't carry is None."""
        rows = [
            {"time": t, "uav": u, "alt": a, "ias": i, "imuz": z, "rpm": None}
            for t, _, u, a, i, z in self._newest("telem", n)
        ] + [
            {"time": t, "uav": u, "alt": None, "ias": None, "imuz": None, "rpm": r}
            for t, _, u, r in self._newest("rotor", n)
        ]
        rows.sort(key=lambda r: r["time"])
        return [{**r, "time": _span(r["time"])} for r in rows]

    def last_rows(self, table: str, n: int) -> list[dict]:
        """The newest n rows (at most 500) of `table`, newest first."""
        cols = COLS[table]
        rows = (
            self.cursor()
            .execute(
                f"SELECT {', '.join(cols)} FROM {table} ORDER BY time DESC, rowid DESC LIMIT ?",
                [min(n, 500)],
            )
            .fetchall()
        )
        out = []
        for r in rows:
            d = dict(zip(cols, r, strict=True))
            d["time"], d["stime"] = _span(d["time"]), str(d["stime"])
            out.append(d)
        return out

    def mem(self) -> int:
        """Bytes DuckDB holds in memory."""
        return int(
            self.cursor()
            .execute("SELECT coalesce(sum(memory_usage_bytes), 0) FROM duckdb_memory()")
            .fetchone()[0]
        )

    def window(self, watch: int, secs: float, rn: int) -> Window | None:
        """The newest `secs` seconds of drones 1..watch and their newest rn rotor samples, extracted
        with SQL (the DuckDB way)."""
        with self.lock:
            if not self.batches["telem"]:
                return None
            last = self.batches["telem"][-1][0]
        since = last - int((secs + 0.5) * 1e9)
        q = "SELECT uav, stime, {} FROM {} WHERE time >= ? AND uav <= ? ORDER BY uav, stime"
        cur = self.cursor()
        t = cur.execute(q.format("alt, ias, imuz", "telem"), [since, watch]).fetchnumpy()
        r = cur.execute(q.format("rpm", "rotor"), [since, watch]).fetchnumpy()
        return window_from_rows(t, r, secs, rn)


def _groups(uav: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    return np.unique(uav, return_index=True, return_counts=True)


def window_from_rows(
    t: dict[str, np.ndarray], r: dict[str, np.ndarray], secs: float, rn: int
) -> Window | None:
    """Group telemetry rows t and rotor rows r (each sorted by uav, stime) into per-drone matrices,
    as analytics.q's win does: the newest `secs` of telemetry, trimmed to the shortest drone's
    length, and each drone's newest rn rotor samples.

    Every drone's telemetry window ends at the newest sample time all drones have reached, so
    drones whose feed handler shard published a little later are not shifted against the others."""
    uav = np.asarray(t["uav"])
    if len(uav) == 0:
        return None
    stime = np.asarray(t["stime"]).astype("datetime64[ns]")
    _, first, count = _groups(uav)
    newest = stime[first + count - 1].min()  # rows are sorted by stime within each drone
    keep = (stime > newest - np.timedelta64(int(secs * 1e9), "ns")) & (stime <= newest)
    uav = uav[keep]
    cols = {c: np.asarray(t[c])[keep] for c in ("alt", "ias", "imuz")}
    ids, starts, counts = _groups(uav)
    n = int(counts.min())
    if n < 16:
        return None
    idx = np.concatenate([np.arange(e - n, e) for e in starts + counts]).reshape(len(ids), n)
    mats = {c: v[idx].astype(np.float64) for c, v in cols.items()}
    ruav = np.asarray(r["uav"])
    rpm = np.zeros((len(ids), 0))
    nr = 0
    rmask = np.isin(ruav, ids)
    rids, rstarts, rcounts = _groups(ruav[rmask])
    if len(rids) == len(ids) and rcounts.min() >= rn:
        rv = np.asarray(r["rpm"])[rmask]
        ridx = np.concatenate([np.arange(e - rn, e) for e in rstarts + rcounts])
        rpm, nr = rv[ridx].reshape(len(ids), rn).astype(np.float64), rn
    return Window(uav=ids.astype(np.int64), newest=newest, n=n, nr=nr, rpm=rpm, **mats)


def _span(ns: int) -> str:
    """Nanoseconds since midnight as q prints a timespan: 0D12:34:56.789012345."""
    s, f = divmod(int(ns), 1_000_000_000)
    h, s = divmod(s, 3600)
    m, s = divmod(s, 60)
    return f"0D{h:02d}:{m:02d}:{s:02d}.{f:09d}"
