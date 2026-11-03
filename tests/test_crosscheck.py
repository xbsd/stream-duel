"""Both lanes compute the same thing: the DuckDB lane's code (bridge/analytics.py) on the rows the
kdb+ lane's code (analytics.q) analysed in tools/fixture.q must give the same numbers.

Regenerate the fixture after changing analytics.q, config.json or templates.json:
    q tools/fixture.q -s 4
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from bridge import analytics as an
from bridge.store import window_from_rows

FIX = json.loads((Path(__file__).parent / "fixtures" / "crosscheck.json").read_text())
KDB = FIX["kdb"]
UNIX_NS_2000 = 946684800 * 10**9


@pytest.fixture(scope="module")
def w():
    r = FIX["rows"]
    if isinstance(r, list):  # q's .j.j writes a table as a list of row objects
        r = {k: [row[k] for row in r] for k in r[0]}
    rows = {
        "uav": np.array(r["uav"], dtype=np.int32),
        "stime": (np.array(r["stime"], dtype=np.int64) + UNIX_NS_2000).astype("datetime64[ns]"),
        **{c: np.array(r[c], dtype=np.float32) for c in ("alt", "ias", "rpm", "imuz")},
    }
    order = np.lexsort((rows["stime"], rows["uav"]))  # the SQL's ORDER BY uav, stime
    rows = {k: v[order] for k, v in rows.items()}
    win = window_from_rows(rows, an.CFG["window_s"], FIX["hz"])
    assert win is not None
    return win


@pytest.fixture(scope="module")
def f(w):
    return w.hz // an.CFG["ana_hz"]


def test_same_window(w):
    assert w.uav.tolist() == KDB["uav"] and w.n == KDB["n"]


def test_tss_distances_and_positions_match(w, f):
    st = an.sig_table("tss", w, f)
    np.testing.assert_allclose(st["dist"], np.array(KDB["tss"]["dist"]), rtol=1e-6, atol=1e-7)
    assert np.array_equal(st["idx"], np.array(KDB["tss"]["idx"]))


def test_dtw_distances_match(w, f):
    st = an.sig_table("dtw", w, f)
    np.testing.assert_allclose(st["dist"], np.array(KDB["dtw"]["dist"]), rtol=1e-4, atol=1e-5)


def test_discord_scores_match(w, f):
    m = round(an.CFG["anomaly"]["window_s"] * an.CFG["ana_hz"])
    py = [an.discord(m, row) for row in an.down(w.imuz, f)]
    np.testing.assert_allclose(py, KDB["discord"], rtol=1e-6, atol=1e-7)


@pytest.mark.parametrize("c", ["alt", "ias"])
def test_correlations_match(w, f, c):
    np.testing.assert_allclose(an.corr(w, f, c), np.array(KDB[f"corr_{c}"]), atol=1e-9)


def test_swarm_groups_match(w, f):
    assert an.swarms(w, f) == KDB["swarms"]


def test_rotor_matches(w):
    py = an.rotor(w)
    kdb = KDB["rotor"]
    np.testing.assert_allclose([r["hz"] for r in py], [r["hz"] for r in kdb], atol=1e-6)
    assert [r["cls"] for r in py] == [r["cls"] for r in kdb]
    assert [r["laden"] for r in py] == [r["laden"] for r in kdb]
