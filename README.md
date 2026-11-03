# Stream Duel

One drone telemetry feed, two engines, side by side: **kdb+ (KDB-X)** and **DuckDB** ingest exactly
the same rows from the same tickerplant and run the same real-time pattern matching on them. A
single page shows, live and measured, how fast each one ingests, how fresh its data is, and what
each one finds in the drones. Built for an internal KX audience. All data is synthetic.

![Stream Duel at 1,024 drones](docs/stream-duel.png)

## Quick start (macOS or Linux)

You need KDB-X (q on your PATH, or at `~/.kx/bin/q`), [uv](https://docs.astral.sh/uv/) and a C
compiler. On macOS: `xcode-select --install` and `brew install libomp`.

```bash
./start.sh                 # builds lib/kxfft.so if needed, starts every process
open stream-duel.html      # the page; give it a minute to collect 60 s of scores
./stop.sh                  # or "Shut down" on the page (click twice)
```

Keys 1 to 7 on the page set the fleet: 64, 256, 1K, 4K, 16K, 64K or 256K drones at 200 samples per
second each (12.8K to 52M rows per second).

## What you see

- **Each lane** (kdb+ on the left, DuckDB on the right): rows ingested per second, lag (tickerplant
  stamp to queryable, median and 99th percentile over 5 s), rows held, memory, rows the tickerplant
  had to drop for it, the time one analytics pass takes, and how old the analysed data is.
- **The spine** between them: both lanes' 99th-percentile lag over the last 60 s on one log scale,
  and the live ratio ("kdb+ is 6.8× fresher").
- **What each engine sees**: the 1,024 watched drones as a grid, colored by what that engine found
  in its newest analysis: a signature, an anomaly, a hidden swarm, or the airframe class from the
  rotor. Outlines mark the events the generator planted.
- **Planted events found**: for each feature, events found out of those planted while the page
  was watching, false alarms, and the time each pass took.
- **Newest rows** in each engine.

## What the pattern matching looks for

The generator plants events on drones 1 to 1,024, deterministically, so each lane can be scored:

| Feature | Planted as | Found by |
|---|---|---|
| Dive | altitude drops ~45 m and recovers in 3 s while speed rises | shape search on altitude and speed |
| Payload release | rotor 8% slower while laden, then a jolt that rings down at 2.5 Hz | shape search on vertical acceleration |
| Hover and stare | speed falls to ~1 m/s and holds | shape search on speed |
| Evasive jinking | 3 Hz vertical oscillation | shape search on vertical acceleration |
| Jamming | 2 s of broadband noise on every channel | anomaly: the newest half second has no close match earlier in the window |
| Hidden swarm | groups of six fly one waveform for a 16 s slot | drones whose altitude and speed changes both correlate above 0.99 |
| Airframe class, laden rotor | rotor at 11, 17 or 23 Hz, 8% lower when laden | dominant rotor frequency (FFT) |

Shape search is z-normalized subsequence search by default; the page switches to dynamic time
warping (DTW), which also matches a manoeuvre flown faster or slower.

## How each lane works

```text
   feed handlers (q, gen.q: telemetry + planted events)
                 │
            tickerplant tp.q  (stamps each batch; per-subscriber queue limit, drops counted)
       ┌─────────┼──────────────────────────┐
  rdb.q (kdb+)  rte.q (kdb+)            bridge/ (Python, DuckDB)
  stores rows   real-time engine:       subscribes over kdb+ IPC (PyKX, no q runtime),
  lag, stats    keeps the watched       appends to in-memory DuckDB, lag after commit,
  websocket     drones' last seconds,   extracts the window with SQL, matches in
                matches in q            NumPy and dtaidistance; websocket
```

| | kdb+ lane | DuckDB lane |
|---|---|---|
| Shape search | `.ai.tss.tss` (KDB-X AI libraries) | NumPy (z-normalized distance profile) |
| DTW | `.ai.dtw.search` (KDB-X) | dtaidistance (C, OpenMP) with KDB-X's definition, in a worker process |
| Anomaly | `.ai.tss.tssdist` | NumPy |
| Swarm | q matrix multiply (`mmu`) | NumPy matrix multiply |
| Rotor FFT | **KissFFT through the KX C interface** (`c/kx_fft.c`, loaded with `2:`) | `numpy.fft` |

Both lanes use the same definitions, templates (`templates.json`) and thresholds (`config.json`).
`tests/test_crosscheck.py` runs the DuckDB lane's code on the rows the kdb+ lane analysed and
checks every distance, score, correlation, group and frequency is identical.

## Measured on an Apple M4 Max (16 cores, 128 GB), 8 feed handlers

| Fleet (rows/s) | kdb+ lag p50 / p99 | DuckDB lag p50 / p99 | Both keep up? |
|---|---|---|---|
| 1K drones (0.2M) | 0.1 / 0.5 ms | 1.2 / 2.3 ms | yes |
| 4K (0.8M) | 0.1 / 0.8 ms | 1.5 / 2.7 ms | yes |
| 16K (3.3M) | 0.4 / 3.9 ms | 2.4 / 8.6 ms | yes |
| 64K (13.1M) | 1.1 / 16.6 ms | 16.6 / 86.7 ms | yes |
| 256K (52M) | | | no: the feed and the shared tickerplant saturate first and drop rows for both lanes |

One analytics pass over 1,024 drones (819,200 samples): kdb+ about 90 ms, DuckDB about 195 ms.
With DTW shape search: kdb+ about 340 ms, DuckDB about 430 ms, and DuckDB's p99 lag rises to about
3.5 ms while kdb+'s stays under 0.5 ms.

At 1,024 drones both lanes find the planted events at the same rates: every dive, payload release,
hidden swarm and laden rotor; 93-99% of hovers and jinks; about 90% of jamming bursts. False
alarms per minute: 5-20 for dives and for payload releases, 0-5 for hovers and jinks, 20-80 for
jamming, none for swarms and at most one for rotors.

Keep 256K for showing the system's ceiling, not as an engine comparison: there both lanes lose
rows because the shared pipeline can't produce or forward 52M rows a second on one laptop.

## Being fair

- Same rows, same tickerplant, same machine, same definitions; every number is measured live.
- DuckDB has no streaming server, so the bridge is what a DuckDB deployment has to build; the page
  says so. Its analytics run on their own thread, so they don't hold up its ingest.
- kdb+ runs its analytics in a separate real-time engine, as kdb+tick does, so they never block
  the RDB's ingest either. The DuckDB lane runs DTW in a worker process for the same reason:
  dtaidistance holds Python's GIL while it computes, and DuckDB's inserts need the GIL (in the
  bridge's own process DTW raised its p99 lag from 2 ms to 16 ms).
- Both lanes' analytics get the same threads (`THREADS=8`): the kdb+ engine's secondary threads,
  and dtaidistance's OpenMP threads.
- Both lanes analyse once a second on a fixed schedule, and both end every drone's window at the
  same instant (feed handler shards publish a few milliseconds apart; drones shifted by even one
  sample against each other no longer correlate as a swarm).
- If the DuckDB bridge falls behind it stops reading, and the tickerplant drops and counts rows for
  it instead of letting its queue grow; the page shows those drops.

## Files

| Path | What it is |
|---|---|
| `gen.q` | telemetry-kit's signal generator plus planted events, classes and groups; `planted[]` lists them |
| `fh.q`, `tp.q` | feed handlers and the tickerplant (ports 5120+, 5110) |
| `rdb.q`, `rte.q`, `analytics.q` | the kdb+ lane: storage and stats (5111), real-time engine (5112), the pattern matching |
| `c/kx_fft.c`, `c/build.sh` | KissFFT exposed to q through the KX C API (`lib/kxfft.so`) |
| `bridge/` | the DuckDB lane (5130): `store.py`, `analytics.py`, `server.py` |
| `config.json`, `templates.json` | shared thresholds and signature templates |
| `tools/templates.q`, `tools/calibrate.q`, `tools/fixture.q` | write templates, choose thresholds against planted truth, write the cross-check fixture |
| `stream-duel.html` | the page |
| `DESIGN.md` | the contract both lanes and the page follow |

## Tests

```bash
q tests/test_fft.q && q tests/test_gen.q   # the C FFT and the generator, against known answers
uv run pytest                              # the cross-check and the DuckDB store
q tools/calibrate.q -s 8                   # precision and recall of every feature against planted events
```

After changing `analytics.q`, `config.json` or `templates.json`, regenerate the cross-check fixture
with `q tools/fixture.q -s 4`.

## Credits

Built on telemetry-kit (the q generator, tickerplant and RDB). KissFFT by Mark Borgerding (BSD-3,
`c/vendor/kissfft`). `k.h` from KxSystems/kdb (Apache-2.0, `c/vendor`).
