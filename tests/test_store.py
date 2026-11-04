"""The DuckDB lane's store: inserts into both tables, the analytics window, trimming, the tap and
clearing."""

from __future__ import annotations

import numpy as np
import pytest

from bridge.store import COLS, METRICS, Store, _span

T0 = 10 * 3600 * 10**9  # tickerplant stamp, ns since midnight
S0 = np.datetime64("2026-11-03T15:00:00", "ns")
TNS, RNS = 20_000_000, 10_000_000  # telem every 20 ms (50 Hz), rotor every 10 ms (100 Hz)


def telem(k: int, drones: int = 4) -> dict[str, np.ndarray]:
    """Telem row k of every drone (one 20 ms block, as fh.q emits)."""
    uav = np.arange(1, drones + 1, dtype=np.int32)
    v = (uav * 1000 + k).astype(np.float32)
    return {
        "time": np.full(drones, T0 + k * TNS, dtype=np.int64),
        "stime": np.full(drones, S0 + np.timedelta64(k * TNS, "ns")),
        "uav": uav,
        "alt": v,
        "ias": v + 1,
        "imuz": v + 3,
    }


def rotor(k: int, drones: int = 4) -> dict[str, np.ndarray]:
    """Rotor samples 2k and 2k+1 of every drone (the same block)."""
    uav = np.tile(np.arange(1, drones + 1, dtype=np.int32), 2)
    j = np.repeat([2 * k, 2 * k + 1], drones)
    return {
        "time": np.full(2 * drones, T0 + k * TNS, dtype=np.int64),
        "stime": S0 + (j * RNS).astype("timedelta64[ns]"),
        "uav": uav,
        "rpm": (uav * 10000 + j).astype(np.float32),
    }


def fill(st: Store, blocks: int, skip=None) -> Store:
    for k in range(blocks):
        t, r = telem(k), rotor(k)
        if skip is not None:
            t, r = skip(k, t, r)
        st.insert("telem", t)
        st.insert("rotor", r)
    return st


@pytest.fixture
def store():
    return fill(Store(maxrows=100_000), 250)  # 5 s of 4 drones


def test_insert_counts_rows_and_values(store):
    assert store.counts == {"telem": 1000, "rotor": 2000} and store.held == store.total == 3000
    assert store.vtotal == 1000 * 3 + 2000 * 1 and METRICS == {"telem": 3, "rotor": 1}
    for t, n in store.counts.items():
        assert store.cursor().execute(f"SELECT count(*) FROM {t}").fetchone()[0] == n


def test_window_is_newest_seconds_newest_last(store):
    w = store.window(watch=3, secs=4, rn=256)
    assert w is not None and w.uav.tolist() == [1, 2, 3]  # watch limits the drones
    assert w.n == 200 and w.alt.shape == (3, 200)  # 4 s at 50 Hz
    assert w.alt[0, -1] == 1000 + 249 and w.alt[0, 0] == 1000 + 50  # newest last
    assert w.newest == S0 + np.timedelta64(249 * TNS, "ns")
    assert w.nr == 256 and w.rpm.shape == (3, 256)  # newest 256 rotor samples
    assert w.rpm[0, -1] == 10000 + 499 and w.rpm[2, 0] == 30000 + 499 - 255


def test_window_ends_where_every_drone_has_data(store):
    store.insert("telem", {c: v[:2] for c, v in telem(250).items()})  # drones 1, 2 a block ahead
    w = store.window(watch=4, secs=4, rn=256)
    # as when one feed handler shard publishes before another: the window must not shift drones
    # against each other, so every drone's ends at block 249, the newest all four have
    assert w is not None and w.n == 200
    assert w.alt[:, -1].tolist() == [1000 + 249, 2000 + 249, 3000 + 249, 4000 + 249]
    assert w.newest == S0 + np.timedelta64(249 * TNS, "ns")


def test_window_trims_every_drone_to_the_shortest():
    def drop4(k, t, r):  # drone 4 misses telem block 120
        return ({c: v[:3] for c, v in t.items()} if k == 120 else t), r

    w = fill(Store(), 250, drop4).window(watch=4, secs=4, rn=256)
    assert w is not None and w.n == 199
    assert w.alt[:, -1].tolist() == [1000 + 249, 2000 + 249, 3000 + 249, 4000 + 249]


def test_too_few_rotor_samples_leave_the_rotor_out():
    w = fill(Store(), 100).window(watch=4, secs=4, rn=256)  # 2 s: 200 rotor samples each
    assert w is not None and w.nr == 0 and w.rpm.shape == (4, 0)


def test_trim_keeps_each_tables_newest_two_thirds():
    st = fill(Store(maxrows=1200), 200)  # 800 telem + 1600 rotor rows
    st.trim()
    assert st.counts["telem"] <= 534 and st.counts["rotor"] <= 1067
    for t, n in st.counts.items():
        assert n == st.cursor().execute(f"SELECT count(*) FROM {t}").fetchone()[0]
    newest = st.cursor().execute("SELECT max(time) FROM telem").fetchone()[0]
    assert newest == T0 + 199 * TNS


def test_tap_has_both_tables_and_span(store):
    tap = store.tap(4)
    assert len(tap) == 8
    assert sum(r["rpm"] is None for r in tap) == 4 and sum(r["alt"] is None for r in tap) == 4
    assert all(r["time"].startswith("0D10:00:04.98") for r in tap)
    assert _span(3 * 3600 * 10**9 + 5) == "0D03:00:00.000000005"


def test_last_rows_newest_first(store):
    rows = store.last_rows("rotor", 3)
    assert rows[0]["rpm"] in (10000 + 499, 20000 + 499, 30000 + 499, 40000 + 499)
    assert list(rows[0]) == list(COLS["rotor"])


def test_clear(store):
    assert store.clear() == 3000
    assert store.held == store.total == store.vtotal == 0
    assert store.window(4, 4, 256) is None


def test_columns_match_schema():
    assert COLS == {
        "telem": ("time", "stime", "uav", "alt", "ias", "imuz"),
        "rotor": ("time", "stime", "uav", "rpm"),
    }
