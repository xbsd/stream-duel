"""The DuckDB lane's real-time pattern matching, mirroring analytics.q (DESIGN.md).

DuckDB has no time-series search, so the window is extracted with SQL (store.Store.window) and the
features are computed here: NumPy for z-normalized shape search, discords, correlation and FFT;
dtaidistance (C) for DTW. Definitions, thresholds (config.json) and templates (templates.json) are
the kdb+ lane's, so both lanes answer the same questions about the same rows.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

from .store import Store, Window

ROOT = Path(__file__).resolve().parent.parent
CFG = json.loads((ROOT / "config.json").read_text())
TPL = json.loads((ROOT / "templates.json").read_text())
SIGS = list(TPL)
UNIX_MS_2000 = 946684800000.0


def to_ms(t: np.datetime64) -> float:
    """Sample time (datetime64 ns) as unix milliseconds, as analytics.q's toMs."""
    return float(np.asarray(t).astype("datetime64[ns]").astype(np.int64) // 10**6)


def zn(x: np.ndarray) -> np.ndarray:
    """Z-normalize along the last axis (population std); constant rows become zeros, as q's zn."""
    m = x.mean(axis=-1, keepdims=True)
    s = x.std(axis=-1, keepdims=True)
    with np.errstate(invalid="ignore", divide="ignore"):
        z = (x - m) / s
    return np.where(s > 1e-12, z, 0.0)


def down(x: np.ndarray, f: int) -> np.ndarray:
    """Block means of f samples along the last axis (q: avg each f cut x; a short last block is
    averaged on its own)."""
    n = x.shape[-1]
    full = n // f * f
    head = x[..., :full].reshape(*x.shape[:-1], n // f, f).mean(axis=-1)
    if full == n:
        return head
    return np.concatenate([head, x[..., full:].mean(axis=-1, keepdims=True)], axis=-1)


def zdist_profile(series: np.ndarray, q: np.ndarray) -> np.ndarray:
    """Z-normalized Euclidean distance between q and every length-m window of each series.

    series (rows, L) or (L,); q (m,). Returns (rows, L-m+1). Same quantity as .ai.tss.tssdist.
    """
    w = sliding_window_view(series, len(q), axis=-1)
    d = zn(w) - zn(q)
    return np.sqrt((d * d).sum(axis=-1))


def dtw_best(series: np.ndarray, q: np.ndarray, window: float) -> tuple[float, int]:
    """Best DTW match of q in series, as KDB-X's .ai.dtw.search defines it: every length-m window
    and q are each z-normalized, then compared with a Sakoe-Chiba band of window x m (in
    dtaidistance's terms window=round(window*m)+1). One call into dtaidistance's C library scores
    every window."""
    from dtaidistance import dtw

    qq = zn(np.asarray(q, dtype=np.float64))
    m = len(qq)
    wins = zn(sliding_window_view(np.asarray(series, dtype=np.float64), m))
    arr = np.ascontiguousarray(np.vstack([qq[None, :], wins]))
    d = dtw.distance_matrix_fast(
        arr, window=round(window * m) + 1, block=((0, 1), (1, len(arr))), compact=True
    )
    k = int(np.argmin(d))
    return float(d[k]), k


def sig_table(mode: str, w: Window, f: int) -> dict:
    """Per signature, every drone's mean normalized distance over the signature's channels and the
    match start (downsampled samples): (nsig, drones) arrays, before thresholds."""
    D = {c: down(getattr(w, c), f) for c in ("alt", "ias", "imuz")}
    dist, idx = [], []
    for s in SIGS:
        per_c = []
        for c, tp in TPL[s].items():
            tp = np.asarray(tp, dtype=np.float64)
            if mode == "dtw":
                r = [dtw_best(row, tp, CFG["dtw_window"]) for row in D[c]]
                d = np.array([x[0] for x in r]) / np.sqrt(len(tp))
                i = np.array([x[1] for x in r])
            else:
                prof = zdist_profile(D[c], tp)
                i = prof.argmin(axis=1)
                d = prof[np.arange(len(prof)), i] / np.sqrt(len(tp))
            per_c.append((d, i))
        dist.append(np.mean([d for d, _ in per_c], axis=0))
        idx.append(per_c[0][1])
    return {"dist": np.array(dist), "idx": np.array(idx), "n": D["alt"].shape[1]}


def signatures(mode: str, w: Window, f: int) -> list[dict]:
    st = sig_table(mode, w, f)
    dist, idx = st["dist"], st["idx"]
    b = dist.argmin(axis=0)
    cols = np.arange(dist.shape[1])
    bd = dist[b, cols]
    th = np.array([CFG["signatures"][s]["threshold"][mode] for s in SIGS])
    hit = np.flatnonzero(bd < th[b])
    t0 = to_ms(w.newest) - 1000 * st["n"] / CFG["ana_hz"]
    return [
        {
            "uav": int(w.uav[j]),
            "sig": SIGS[b[j]],
            "dist": float(bd[j]),
            "at": t0 + 1000 * float(idx[b[j], j]) / CFG["ana_hz"],
        }
        for j in hit
    ]


def discord(m: int, x: np.ndarray) -> float:
    """The newest m samples' z-normalized distance to their nearest match earlier in x (the left
    matrix-profile value), as analytics.q's discord."""
    k = len(x) - m
    return float(zdist_profile(x[:k], x[k:]).min())


def anomalies(w: Window, f: int) -> list[dict]:
    m = round(CFG["anomaly"]["window_s"] * CFG["ana_hz"])
    s = np.array([discord(m, row) for row in down(w.imuz, f)])
    hit = np.flatnonzero(s > CFG["anomaly"]["threshold"])
    return [{"uav": int(w.uav[j]), "score": float(s[j])} for j in hit]


def corr(w: Window, f: int, c: str) -> np.ndarray:
    X = zn(np.diff(down(getattr(w, c), f), axis=1))
    return X @ X.T / X.shape[1]


def swarms(w: Window, f: int) -> list[list[int]]:
    """Connected components of drones whose altitude and airspeed changes both correlate above
    min_r, as analytics.q's swarms (label propagation to the smallest index)."""
    C = np.minimum(*(corr(w, f, c) for c in CFG["swarm"]["channels"]))
    adj = C > CFG["swarm"]["min_r"]
    lab = np.arange(len(adj))
    while True:
        l2 = np.where(adj, lab[None, :], len(lab)).min(axis=1)
        if np.array_equal(l2, lab):
            break
        lab = l2
    groups: dict[int, list[int]] = {}
    for i, g in enumerate(lab):
        groups.setdefault(int(g), []).append(i)
    return [
        [int(w.uav[i]) for i in g] for g in groups.values() if len(g) >= CFG["swarm"]["min_size"]
    ]


def fft_peak(x: np.ndarray, fs: float, lo: float, hi: float) -> np.ndarray:
    """Per row, the dominant frequency between lo and hi Hz, refined by parabolic interpolation on
    the log magnitude: kx_fft.c's fftpeak, with numpy.fft."""
    n = x.shape[-1]
    mag = np.abs(np.fft.fft(x - x.mean(axis=-1, keepdims=True), axis=-1))
    df = fs / n
    k0, k1 = max(1, int(np.ceil(lo / df))), min(n // 2 - 1, int(np.floor(hi / df)))
    band = mag[:, k0 : k1 + 1]
    best = band.argmax(axis=1) + k0
    rows = np.arange(len(x))
    a, b, c = (np.log(mag[rows, best + d] + 1e-12) for d in (-1, 0, 1))
    den = a - 2 * b + c
    with np.errstate(invalid="ignore", divide="ignore"):
        shift = np.where(den != 0, 0.5 * (a - c) / den, 0.0)
    return (best + np.clip(shift, -0.5, 0.5)) * df


def rotor(w: Window) -> list[dict]:
    c = CFG["rotor"]
    n = int(c["n"])
    if n > w.n:
        return []
    pk = fft_peak(w.rpm[:, -n:], float(w.hz), float(c["lo"]), float(c["hi"]))
    classes = np.asarray(c["classes"], dtype=np.float64)
    cand = np.concatenate([classes, c["laden"] * classes])
    j = np.abs(pk[:, None] - cand[None, :]).argmin(axis=1)
    return [
        {"uav": int(u), "hz": float(h), "cls": "ABC"[k % 3], "laden": bool(k >= 3)}
        for u, h, k in zip(w.uav, pk, j)
    ]


def analyse(store: Store, watch: int, mode: str, hz: int) -> dict:
    """One pass of every feature, timed, in analytics.q's output format."""
    t0 = time.perf_counter()
    w = store.window(watch, CFG["window_s"], hz)
    tw = time.perf_counter()
    if w is None:
        return {"type": "analytics", "lane": "duckdb", "empty": True}
    f = max(1, w.hz // CFG["ana_hz"])
    took = {"window": round((tw - t0) * 1000)}
    out = {}
    for name, fn in (
        ("signatures", lambda: signatures(mode, w, f)),
        ("anomaly", lambda: anomalies(w, f)),
        ("swarm", lambda: swarms(w, f)),
        ("rotor", lambda: rotor(w)),
    ):
        a = time.perf_counter()
        out[name] = fn()
        took[name] = round((time.perf_counter() - a) * 1000)
    return {
        "type": "analytics",
        "lane": "duckdb",
        "mode": mode,
        "took": took,
        "newest": to_ms(w.newest),
        "rows": int(len(w.uav) * w.n),
        "watch": watch,
        "signatures": out["signatures"],
        "anomalies": out["anomaly"],
        "swarms": out["swarm"],
        "rotor": out["rotor"],
    }
