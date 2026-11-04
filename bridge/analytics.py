"""The DuckDB lane's real-time pattern matching, mirroring analytics.q (DESIGN.md).

DuckDB has no time-series search, so the window is extracted with SQL (store.Store.window) and the
features are computed here: NumPy for z-normalized shape search, discords, correlation and FFT;
dtaidistance (C) for DTW. Definitions, thresholds (config.json) and templates (templates.json) are
the kdb+ lane's, so both lanes answer the same questions about the same rows. Telemetry arrives at
the analysis rate (50 Hz), the rotor at 100 Hz.
"""

from __future__ import annotations

import json
import time
from concurrent.futures import Executor
from pathlib import Path

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

from .store import Store, Window

ROOT = Path(__file__).resolve().parent.parent
CFG = json.loads((ROOT / "config.json").read_text())
TPL = json.loads((ROOT / "templates.json").read_text())
SIGS = list(TPL)
NEED = max(len(tp) for s in TPL.values() for tp in s.values())  # samples the longest template needs
UNIX_MS_2000 = 946684800000.0
ROWS_PER_CALL = 16  # drones per dtaidistance call (see dtw_profile)
# Where DTW runs. The bridge sets a one-worker process pool (server.py): dtaidistance holds Python's
# GIL while it computes, and DuckDB's inserts need the GIL, so DTW in the bridge's own process would
# slow its ingest. None (tests, tools) computes in this process.
EXECUTOR: Executor | None = None


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


def zdist_profile(series: np.ndarray, q: np.ndarray) -> np.ndarray:
    """Z-normalized Euclidean distance between q and every length-m window of each series.

    series (rows, L) or (L,); q (m,). Returns (rows, L-m+1). Same quantity as .ai.tss.tssdist.
    """
    w = sliding_window_view(series, len(q), axis=-1)
    d = zn(w) - zn(q)
    return np.sqrt((d * d).sum(axis=-1))


def dtw_profile(series: np.ndarray, q: np.ndarray, window: float) -> np.ndarray:
    """DTW distance between q and every length-m window of each series, as KDB-X's
    .ai.dtw.search defines it: each window and q are z-normalized, then compared with a
    Sakoe-Chiba band of window x m (in dtaidistance's terms window=round(window*m)+1).

    series (rows, L) or (L,); q (m,). Returns (rows, L-m+1). Each call into dtaidistance's C
    library scores every window of ROWS_PER_CALL rows, with q last so its OpenMP threads split
    the windows between them (OMP_NUM_THREADS, set by start.sh to the kdb+ engine's thread count).
    Blocks of 16 drones run faster than one call over every drone, and each call holds the GIL
    for only about a millisecond.
    """
    from dtaidistance import dtw

    qq = zn(np.asarray(q, dtype=np.float64))
    m = len(qq)
    s = np.atleast_2d(np.asarray(series, dtype=np.float64))
    wins = zn(sliding_window_view(s, m, axis=-1))  # (rows, k, m)
    rows, k = wins.shape[:2]
    out = np.empty((rows, k))
    for r0 in range(0, rows, ROWS_PER_CALL):
        part = wins[r0 : r0 + ROWS_PER_CALL]
        arr = np.ascontiguousarray(np.vstack([part.reshape(-1, m), qq[None, :]]))
        n = len(arr)
        d = dtw.distance_matrix_fast(
            arr,
            window=round(window * m) + 1,
            block=((0, n - 1), (n - 1, n)),
            compact=True,
            parallel=True,
        )
        out[r0 : r0 + len(part)] = np.asarray(d, dtype=np.float64).reshape(len(part), k)
    return out if np.ndim(series) > 1 else out[0]


def dtw_best(series: np.ndarray, q: np.ndarray, window: float) -> tuple[float, int]:
    """Best DTW match of q in one series: (distance, window start)."""
    d = dtw_profile(series, q, window)
    k = int(np.argmin(d))
    return float(d[k]), k


def exit_with_parent(ppid: int) -> None:
    """Initializer for the DTW worker process: exit as soon as the bridge that started it is gone,
    however it ended."""
    import os
    import threading

    def watch() -> None:
        while os.getppid() == ppid:
            time.sleep(0.5)
        os._exit(0)

    threading.Thread(target=watch, name="exit-with-parent", daemon=True).start()


def _dtw_profiles(
    D: dict[str, np.ndarray], jobs: list[tuple[str, list[float]]], window: float
) -> list[np.ndarray]:
    return [dtw_profile(D[c], np.asarray(tp, dtype=np.float64), window) for c, tp in jobs]


def sig_table(mode: str, w: Window) -> dict:
    """Per signature, every drone's mean normalized distance over the signature's channels and the
    match start (50 Hz samples): (nsig, drones) arrays, before thresholds."""
    D = {c: getattr(w, c) for c in ("alt", "ias", "imuz")}
    jobs = [(c, tp) for s in SIGS for c, tp in TPL[s].items()]
    if mode == "dtw":
        args = (D, jobs, CFG["dtw_window"])
        profs = (
            _dtw_profiles(*args)
            if EXECUTOR is None
            else EXECUTOR.submit(_dtw_profiles, *args).result()
        )
    else:
        profs = [zdist_profile(D[c], np.asarray(tp, dtype=np.float64)) for c, tp in jobs]
    prof_of = iter(profs)
    dist, idx = [], []
    for s in SIGS:
        per_c = []
        for tp in TPL[s].values():
            prof = next(prof_of)
            i = prof.argmin(axis=1)
            d = prof[np.arange(len(prof)), i] / np.sqrt(len(tp))
            per_c.append((d, i))
        dist.append(np.mean([d for d, _ in per_c], axis=0))
        idx.append(per_c[0][1])
    return {"dist": np.array(dist), "idx": np.array(idx), "n": D["alt"].shape[1]}


def signatures(mode: str, w: Window) -> list[dict]:
    st = sig_table(mode, w)
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


def anomalies(w: Window) -> list[dict]:
    m = round(CFG["anomaly"]["window_s"] * CFG["ana_hz"])
    s = np.array([discord(m, row) for row in w.imuz])
    hit = np.flatnonzero(s > CFG["anomaly"]["threshold"])
    return [{"uav": int(w.uav[j]), "score": float(s[j])} for j in hit]


def corr(w: Window, c: str) -> np.ndarray:
    X = zn(np.diff(getattr(w, c), axis=1))
    return X @ X.T / X.shape[1]


def swarms(w: Window) -> list[list[int]]:
    """Connected components of drones whose altitude and airspeed changes both correlate above
    min_r, as analytics.q's swarms (label propagation to the smallest index)."""
    C = np.minimum(*(corr(w, c) for c in CFG["swarm"]["channels"]))
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
    if n > w.nr:
        return []
    pk = fft_peak(w.rpm[:, -n:], float(c["hz"]), float(c["lo"]), float(c["hi"]))
    classes = np.asarray(c["classes"], dtype=np.float64)
    cand = np.concatenate([classes, c["laden"] * classes])
    j = np.abs(pk[:, None] - cand[None, :]).argmin(axis=1)
    return [
        {"uav": int(u), "hz": float(h), "cls": "ABC"[k % 3], "laden": bool(k >= 3)}
        for u, h, k in zip(w.uav, pk, j)
    ]


def analyse(store: Store, watch: int, mode: str) -> dict:
    """One pass of every feature, timed, in analytics.q's output format. A window shorter than the
    longest template (the feed skipped samples) gives a "short" result instead, as analytics.q."""
    t0 = time.perf_counter()
    w = store.window(watch, CFG["window_s"], int(CFG["rotor"]["n"]))
    tw = time.perf_counter()
    if w is None:
        return {"type": "analytics", "lane": "duckdb", "empty": True}
    if w.n < NEED:
        return {
            "type": "analytics",
            "lane": "duckdb",
            "short": True,
            "have_s": w.n / CFG["ana_hz"],
            "need_s": NEED / CFG["ana_hz"],
            "newest": to_ms(w.newest),
        }
    took = {"window": round((tw - t0) * 1000)}
    out = {}
    for name, fn in (
        ("signatures", lambda: signatures(mode, w)),
        ("anomaly", lambda: anomalies(w)),
        ("swarm", lambda: swarms(w)),
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
        "rows": int(len(w.uav) * (w.n + w.nr)),
        "watch": watch,
        "signatures": out["signatures"],
        "anomalies": out["anomaly"],
        "swarms": out["swarm"],
        "rotor": out["rotor"],
    }
