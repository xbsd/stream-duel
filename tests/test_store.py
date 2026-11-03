"""The DuckDB lane's store: inserts, the analytics window, trimming, the tap and clearing."""

from __future__ import annotations

import numpy as np
import pytest

from bridge.store import COLS, Store, _span

T0 = 10 * 3600 * 10**9  # tickerplant stamp, ns since midnight
S0 = np.datetime64("2026-11-03T15:00:00", "ns")


def batch(k: int, drones: int = 4, hz: int = 200) -> dict[str, np.ndarray]:
    """One tickerplant batch: sample k of every drone (sample-major, as fh.q emits)."""
    uav = np.arange(1, drones + 1, dtype=np.int32)
    t = np.full(drones, T0 + k * 10**9 // hz, dtype=np.int64)
    s = np.full(drones, S0 + np.timedelta64(k * 10**9 // hz, "ns"))
    v = (uav * 1000 + k).astype(np.float32)
    return {"time": t, "stime": s, "uav": uav, "alt": v, "ias": v + 1, "rpm": v + 2, "imuz": v + 3}


@pytest.fixture
def store():
    st = Store(maxrows=10_000)
    for k in range(1000):  # 5 s of 4 drones at 200 Hz
        st.insert(batch(k))
    return st


def test_insert_counts(store):
    assert store.held == store.total == 4000
    assert store.cursor().execute("SELECT count(*) FROM telem").fetchone()[0] == 4000


def test_window_is_newest_seconds_newest_last(store):
    w = store.window(watch=3, secs=4, hz=200)
    assert w is not None and w.uav.tolist() == [1, 2, 3]  # watch limits the drones
    assert w.n == 800  # 4 s at 200 Hz
    assert w.alt.shape == (3, 800)
    assert w.alt[0, -1] == 1000 + 999 and w.alt[0, 0] == 1000 + 200  # newest last
    assert w.newest == S0 + np.timedelta64(999 * 5_000_000, "ns")


def test_window_ends_where_every_drone_has_data(store):
    store.insert({c: v[:2] for c, v in batch(1000).items()})  # drones 1 and 2 are a sample ahead
    w = store.window(watch=4, secs=4, hz=200)
    # as when one feed handler shard publishes before another: the window must not shift drones
    # against each other, so every drone's ends at sample 999, the newest all four have
    assert w is not None and w.n == 800 and w.alt.shape == (4, 800)
    assert w.alt[:, -1].tolist() == [1000 + 999, 2000 + 999, 3000 + 999, 4000 + 999]
    assert w.newest == S0 + np.timedelta64(999 * 5_000_000, "ns")


def test_window_trims_every_drone_to_the_shortest():
    st = Store(maxrows=10_000)
    for k in range(1000):
        b = batch(k)
        st.insert({c: v[:3] for c, v in b.items()} if k == 500 else b)  # drone 4 misses one
    w = st.window(watch=4, secs=4, hz=200)
    assert w is not None and w.n == 799 and w.alt.shape == (4, 799)
    assert w.alt[:, -1].tolist() == [1000 + 999, 2000 + 999, 3000 + 999, 4000 + 999]


def test_trim_keeps_the_newest_two_thirds():
    st = Store(maxrows=1200)
    for k in range(400):  # 1600 rows
        st.insert(batch(k))
    st.trim()
    assert (
        st.held <= 800
        and st.held == st.cursor().execute("SELECT count(*) FROM telem").fetchone()[0]
    )
    newest = st.cursor().execute("SELECT max(time) FROM telem").fetchone()[0]
    assert newest == T0 + 399 * 10**9 // 200


def test_tap_and_span(store):
    tap = store.tap(8)
    assert len(tap) == 4  # the newest batch
    assert all(r["time"].startswith("0D10:00:04.99") for r in tap)
    assert _span(3 * 3600 * 10**9 + 5) == "0D03:00:00.000000005"


def test_clear(store):
    assert store.clear() == 4000
    assert store.held == 0 and store.window(4, 4, 200) is None


def test_columns_match_schema():
    assert COLS == ("time", "stime", "uav", "alt", "ias", "rpm", "imuz")
