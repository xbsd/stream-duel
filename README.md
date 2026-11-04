# Stream Duel

One drone telemetry feed, two engines, side by side. **kdb+ (KDB-X)** and **DuckDB** ingest exactly
the same rows from the same tickerplant and run the same real-time pattern matching on them. One
page shows, live and measured, how fast each engine ingests, how fresh its data is, how long its
analysis takes, and what it finds in the drones. Built for an internal KX audience. All data is
synthetic.

![Stream Duel at 1,024 drones](docs/stream-duel.png)

## Contents

- [The short version](#the-short-version)
- [Quick start](#quick-start)
- [A tour of the page](#a-tour-of-the-page)
- [What happens behind the page](#what-happens-behind-the-page)
- [The drones and the planted events](#the-drones-and-the-planted-events)
- [The pattern matching](#the-pattern-matching)
- [Measured results](#measured-results)
- [Pushing the fleet: what overload looks like](#pushing-the-fleet-what-overload-looks-like)
- [Being fair](#being-fair)
- [Configuration](#configuration)
- [Tests](#tests)
- [Troubleshooting](#troubleshooting)
- [Files](#files)
- [Glossary](#glossary)

## The short version

A feed of up to 262,144 synthetic drones, each sending 200 samples a second, goes through one kdb+
tickerplant to two lanes:

- **kdb+**: an RDB stores every row, and a real-time engine runs the pattern matching in q.
- **DuckDB**: a Python bridge appends every batch to an in-memory DuckDB, extracts the analysis
  window with SQL, and runs the same pattern matching in NumPy and dtaidistance.

At 1,024 drones (205,000 rows a second) on an Apple M4 Max:

| | kdb+ | DuckDB |
|---|---|---|
| Lag, tickerplant to queryable, 99th percentile | 0.4 ms | 2.1 ms |
| One analysis pass over all 1,024 drones | 41 ms | 201 ms |
| Planted events found | the same | the same |

Both lanes find the same events because they compute the same thing: a test runs both lanes' code
on the same rows and checks that every distance, score, correlation, group and frequency matches.
kdb+ is faster because of where and how the work runs, not because it does less.

## Quick start

You need:
- KDB-X: `q` on your PATH, or at `~/.kx/bin/q`;
- [uv](https://docs.astral.sh/uv/) for the DuckDB lane's Python;
- a C compiler. On macOS, run `xcode-select --install`, and `brew install libomp` for
  dtaidistance's parallel DTW.

```bash
./start.sh                 # builds the C libraries in lib/ if needed, starts every process
open stream-duel.html      # the page; give it a minute to collect 60 s of scores
./stop.sh                  # stops everything, the launcher too
```

The page is a plain HTML file. It needs no web server and no build, and it connects to the two
lanes by itself. A page can't start processes, so `./start.sh` also starts a small **launcher**
(`launcher.py`, port 5100). It lets the page run `start.sh` and `stop.sh`, and nothing else. It
listens on this machine only and accepts only a page opened from a file or from localhost.

| To | Do |
|---|---|
| Stop the drones but keep everything running | click **OFF** (red, key `0`) |
| Start the drones again | click a fleet size, or press keys `1`-`7` |
| Stop every process but the launcher | **Shut down** on the page (click twice). It turns into a green **Start** button. |
| Start everything again from the page | **Start**, or any fleet size (that size is flown) |
| Stop every process, the launcher too | `./stop.sh`. The page then shows the command to start again. |
| Start every process from a terminal | `./start.sh` |

## A tour of the page

The page has three columns. The **kdb+ lane** is on the left and the **DuckDB lane** on the right;
both are laid out the same way. **How fresh is each engine?** sits between them.

### The header

| Control | What it does |
|---|---|
| **Fleet** | **OFF** stops the drones: no rows are generated, both lanes keep running and keep what they stored. **64** to **256K** set how many drones fly, each at 200 samples a second: 12,800 to 52.4 million rows a second. Keys `0` to `7` do the same. Drones 1 to 1,024 are the *watched* drones: they carry the planted events and are analysed. |
| **Shape search** | How both lanes search for the four signature manoeuvres. **Z-normalized** compares shapes point by point after scaling (time series search). **Time-warped (DTW)** also matches a manoeuvre flown faster or slower, and costs more. Each mode has its own thresholds. |
| **Outline planted events** | Draws an outline on every drone in the grids that has a planted event in progress (see below). |
| **Clear both lanes** | Deletes every stored row in both lanes and restarts the page's scoring. Click twice within 3 s: the first click arms it. |
| **Shut down** / **Start** | **Shut down** stops every process (feed handlers, tickerplant, both lanes) through the launcher, which force-stops anything stuck. Click twice within 3 s. The button then turns into a green **Start**, which starts everything again; picking a fleet size does the same and flies that size. If the launcher isn't running either (after `./stop.sh`), the button is greyed out and the page shows the command to run. |

### Each lane

**Name and connection.** "connected on :5111" (kdb+) or ":5130" (DuckDB) while the page's websocket
to that lane is open. If the lane isn't running it says "not running on :5111" in red, its last
figures are greyed out (they're no longer live), and the page retries every 2 s.

**The big number: rows ingested per second.** Rows the lane stored in the last 250 ms, as a rate,
smoothed: each update moves 40% of the way to the new value. With the feed keeping up, it matches
the fleet: 1,024 drones × 200 Hz ≈ 205,000.

**The eight figures**, updated every 250 ms (ingest) and every second (analysis):

| Figure | What it means | How it's measured |
|---|---|---|
| **lag, median** and **lag, 99th pct** | How long a row takes from the tickerplant stamping it to being queryable in this engine | Each batch's lag is the time from its tickerplant stamp to the moment it's in the store: in the kdb+ RDB, right after the insert; in DuckDB, after the insert commits. Median and 99th percentile are weighted by rows, over the batches of the last 5 s. Both lanes use the same clock (same machine). |
| **rows held** | Rows in memory now | When a lane passes 60 million rows, it keeps the newest two thirds (40 million). At 1,024 drones that first happens after 5 minutes, then every 100 s. |
| **memory** | Memory the store uses | kdb+: the RDB's heap in use (`.Q.w[]`). DuckDB: DuckDB's own memory (`duckdb_memory()`). q grows vectors in power-of-two blocks, so its figure can run up to about a quarter above the raw column size (36 bytes a row in both lanes). |
| **rows since clear** | Rows stored since the lane started, or since **Clear both lanes** | A counter in each lane. |
| **rows dropped** | Rows the tickerplant had to skip for this lane | When more than 256 MB is already waiting to be sent to a lane, the tickerplant skips that lane for the batch and counts the rows. The count runs from the tickerplant's start; Clear doesn't reset it. Red when above 0. |
| **analytics pass** | How long the newest analysis pass took | Window extraction plus the four features (signatures, anomaly, swarm, rotor), in ms. |
| **analysed data age** | How old the newest analysed sample was when the result was shown | Now, minus the sample time of the newest sample in the latest pass's window. It adds up lag, the wait for the next pass (passes run every second) and the pass itself. Red above 3 s. |

### What this engine sees in the watched drones

A 32 × 32 grid: one cell per watched drone, drone 1 at the top left, read left to right. Each lane
colours the cells from its own latest analysis pass. If a drone has several findings, the first
colour in this list wins:

| Colour | Meaning |
|---|---|
| Red | **Anomaly**: the drone's newest half second of vertical acceleration has no close match anywhere earlier in its window (planted as jamming). |
| Lane colour (blue for kdb+, amber for DuckDB) | **Signature match**: the drone flew one of the four manoeuvres (dive, payload release, hover and stare, evasive jinking). |
| Black | **Hidden swarm**: the drone belongs to a group of three or more whose altitude and airspeed changes move in lockstep. |
| Three greys | **Airframe class A, B or C**, from the lane's rotor analysis (dominant rotor frequency 11, 17 or 23 Hz). Before a lane's first pass, the generator's class. |
| Outline | **Planted**: an event is in progress on this drone (or ended less than 1 s ago) at the time of the lane's newest analysed sample. Laden rotors aren't outlined. Toggle with **Outline planted events**. |

The two grids should look nearly the same. Small differences come from timing: each lane analyses
a slightly different instant.

### Planted events found, last 60 s of watching

The generator plants events on a deterministic schedule (see
[The drones and the planted events](#the-drones-and-the-planted-events)). The real-time engine lists
the events of the last 60 s for the page, and the page scores each lane's reports against them.
Neither lane's analysis ever sees this list.

| Column | Rule |
|---|---|
| **Planted** | Events of that kind that ended more than 2 s before the lane's newest analysed sample and started in the last 60 s, since the page began watching (or since Clear). They must also last long enough for the feature to see: a laden period at least 2.56 s (the rotor analysis uses 512 samples), a swarm slot at least 4 s (the window). For swarms, each member drone counts as one event. |
| **Found** | Planted events the lane reported: the same drone and feature, at a time from 1 s before the event started to 4.5 s after it ended. A signature report's time is where the match starts in the window; other reports use the pass's newest sample time. |
| **False alarms** | Reports from the last 60 s with no planted event of that feature on that drone from 1.5 s before it started to 4.5 s after it ended. An anomaly is a false alarm only if nothing at all was planted on that drone at the time. Repeats of the same drone and feature within about 4 s count once. |
| **Time per pass** | The feature's time in the latest pass. The four signature rows share one time: one search covers all four. The bars use one scale across both lanes. |

### Newest rows

The last 8 rows each lane stored, newest first: the tickerplant's stamp (time of day), drone id,
altitude (m), airspeed (m/s), rotor speed (rpm), vertical acceleration (m/s²). They show both lanes
are receiving the same live feed.

### How fresh is each engine?

The middle column plots both lanes' 99th-percentile lag for the last 60 s, on one log scale from
0.1 ms to 10 s. Below it, the verdict divides the two current 99th percentiles ("kdb+ is 5.4×
fresher") and shows both. Otherwise it says what state the system is in:

| Verdict | When |
|---|---|
| Connecting… | the first 2.5 s after the page opens |
| Starting… / Stopping… | the launcher is running `start.sh` or `stop.sh` |
| Stopped | no lane is running, and the launcher is: press **Start** or pick a fleet size |
| Not running | neither the lanes nor the launcher are running: the page shows the `./start.sh` command |
| Start failed | `start.sh` failed; the page shows its last line, and `logs/` has the rest |
| Feed off | the fleet is OFF |
| Waiting for both lanes | the lanes are up but haven't both reported lag yet |

**Several pages at once.** Every open page shows the fleet and mode the lanes are running, whoever
set them. A page sends its own fleet and mode only when you click, or when it started the system.
The RDB's fleet is the one flying, because it drives the feed handlers. If the DuckDB lane ever
disagrees with it, the page brings it into line.

### The footer

Two paragraphs on the page say how each lane is built and that every figure is measured live. A
viewer can check the comparison's terms without leaving the page.

## What happens behind the page

```text
   feed handlers fh.q × 8      (gen.q: telemetry, planted events; 10 ms timer)
                 │  async, then one sync call per tick (never runs ahead of the tickerplant)
            tickerplant tp.q   (stamps each batch; per-subscriber queue limit 256 MB, drops counted)
       ┌─────────┼──────────────────────────────┐
  rdb.q :5111   rte.q :5112                 bridge/ :5130 (Python)
  kdb+ RDB      kdb+ real-time engine       PyKX subscription → queue → ingest thread → DuckDB
  stores rows,  watched drones only,        lag after commit; analysis thread: SQL window,
  lag, stats    analysis every second       NumPy, dtaidistance (DTW in a worker process)
       │  websocket   │ results via the RDB         │  websocket
       └──────────────┴──── stream-duel.html ───────┘
```

The life of one row:

1. **Generated.** Each feed handler owns the drones whose id modulo the number of feed handlers is
   its shard (8 by default). Every 10 ms it generates every sample due since its last tick, on a
   5 ms grid shared by all drones (200 Hz), and sends them to the tickerplant. It then makes one
   synchronous call, so it can never run ahead of what the tickerplant has taken. If it falls more
   than 0.5 s behind, it skips the oldest samples to stay current; those rows are never generated
   and no lane sees them.
2. **Stamped and published.** The tickerplant adds a `time` column (time of day) to the batch and
   publishes it. The kdb+ RDB and the DuckDB bridge each get every row. The real-time engine gets
   only drones 1 to 1,024 (`.u.subw`, kdb+tick's filtered subscription). If more than 256 MB is
   already queued for a subscriber, the tickerplant skips it for this batch and counts the dropped
   rows for that lane.
3. **Stored, kdb+ lane.** The RDB inserts the batch into the in-memory table `telem` and records
   its lag. Every 250 ms it sends the page its stats: rate, lag, rows, memory, drops and the newest
   rows.
4. **Stored, DuckDB lane.** The bridge reads the batch over kdb+ IPC with PyKX (no q runtime in the
   bridge), turns it into NumPy columns and queues it. An ingest thread drains the queue into one
   `INSERT` into an in-memory DuckDB table with the same schema, then records the lag. The bridge
   sends the page the same stats every 250 ms. If more than 4 million rows are waiting for the
   ingest thread, the bridge stops reading, and the tickerplant drops and counts rows for it.
5. **Analysed.** Once a second, on a fixed schedule:
   - The kdb+ real-time engine runs `analytics.q` on the watched drones' newest seconds, using 8
     secondary threads. It sends the result to the RDB, which forwards it to the page.
   - The bridge runs `bridge/analytics.py` on a worker thread. A SQL query extracts the newest 4.5 s
     of the watched drones from DuckDB. DTW runs in a separate worker process (see
     [Being fair](#being-fair)).
6. **Shown.** The page receives stats, results and the planted list as JSON over two websockets
   and draws everything on canvas.

The message formats are in [DESIGN.md](DESIGN.md).

### Processes and ports

| Process | Port | Lane | Job |
|---|---|---|---|
| `fh.q` × 8 | 5120-5127 | both | Feed handlers |
| `tp.q` | 5110 | both | Tickerplant |
| `rdb.q` | 5111 | kdb+ | RDB; the page's websocket for the kdb+ lane |
| `rte.q` | 5112 | kdb+ | Real-time engine |
| `bridge/` | 5130 | DuckDB | Bridge and DuckDB; the page's websocket for the DuckDB lane |
| `launcher.py` | 5100 | | Lets the page run `start.sh` and `stop.sh` (localhost only) |

## The drones and the planted events

Each row is one sample of one drone: `time` (tickerplant stamp), `stime` (sample time), `uav` (drone
id), `alt` (altitude, m), `ias` (airspeed, m/s), `rpm` (rotor speed) and `imuz` (vertical
acceleration, m/s²): 36 bytes. The signals come from telemetry-kit's generator, `gen.q`. They are
smooth, with per-drone randomness, and deterministic: the same drone at the same time always has
the same values.

Everything planted is a hash of the drone id and the time slot, so the feed handlers (which plant
the events) and the scoring list (which reports them) always agree. Sample time wraps every
1,024 s and is cut into 16 s slots. In each slot, each watched drone has about a 1 in 4 chance of
one event, starting 2 to 12 s into the slot:

| Event | Lasts | What the drone does | Found by |
|---|---|---|---|
| Dive | 3 s | altitude drops about 45 m and recovers while airspeed rises | signature, on altitude and airspeed |
| Payload release | 1 s | flies laden (rotor 8% slower) until release, then a jolt that rings down at 2.5 Hz while the rotor speeds up | signature, on vertical acceleration; the laden period by the rotor |
| Hover and stare | 5 s | airspeed falls to about 1 m/s and holds; altitude steadies | signature, on airspeed |
| Evasive jinking | 3 s | 3 Hz vertical oscillation with an airspeed wobble | signature, on vertical acceleration |
| Jamming | 2 s | broadband noise on every channel | anomaly |
| Hidden swarm | 16 s | watched drones form groups of six consecutive ids; in about 1 slot in 5 a group flies coordinated, with all six following one altitude and airspeed waveform | swarm |
| Airframe class | always | each drone's class (A, B or C, from its id) sets its rotor frequency: 11, 17 or 23 Hz | rotor |

## The pattern matching

Both lanes do exactly this, with the same definitions (`analytics.q` and `bridge/analytics.py`),
the same templates (`templates.json`) and the same thresholds (`config.json`).

**The window.** Each pass takes the newest 4 s of every watched drone. Every drone's window ends at
the same instant: the newest sample time all watched drones have reached. Feed handlers publish a
few milliseconds apart, and drones shifted against each other by even one sample would no longer
correlate as a swarm. Signatures, anomaly and swarm work on 50 Hz data (block means of 4 samples).
The rotor uses full-rate rpm.

| Feature | What it computes | Threshold | kdb+ lane | DuckDB lane |
|---|---|---|---|---|
| **Signatures** | For each drone and each of the 4 templates, the best match anywhere in the window, per channel, z-normalized; the distance is averaged over the template's channels and divided by √(template length). The drone's best signature is reported if under its threshold. | per signature and mode (`config.json`) | `.ai.tss.tss` or `.ai.dtw.search` (KDB-X AI libraries), `peach` over drones | NumPy sliding z-normalized distance, or dtaidistance DTW with KDB-X's definition (C, OpenMP), in a worker process |
| **Anomaly** | Distance from the newest 0.5 s of vertical acceleration to its nearest match earlier in the window (a discord score) | 4.54 | `.ai.tss.tssdist`, `peach` over drones | NumPy, the same distance |
| **Swarm** | Correlation of every pair of drones' altitude changes, and of their airspeed changes; pairs above 0.99 on both are linked, and connected groups of 3 or more are reported | 0.99, at least 3 drones | one matrix product (the Gram matrix) through the platform BLAS, called from q with the KX C API (`lib/kxblas.so`; Apple Accelerate on macOS) | NumPy matrix product (Accelerate on macOS) |
| **Rotor** | Dominant rotor frequency between 5 and 40 Hz over the newest 512 samples, refined between FFT bins; nearest of 11, 17, 23 Hz or the same × 0.92 (laden) | nearest frequency | KissFFT called from q with the KX C API (`lib/kxfft.so`), one call per thread's share of the drones | `numpy.fft` |

The templates come from the same formulas the generator uses to plant the events (`tools/templates.q`).
The thresholds come from `tools/calibrate.q`. It generates 96 s of 256 drones, slides the window
along them every second, and labels every drone-window from the planted schedule. For each
signature it picks the threshold with the best F1 score; for the anomaly, the best recall with
precision of at least 0.97. The swarm and rotor rules are fixed. The results:

| | Precision | Recall |
|---|---|---|
| Dive / payload / hover / jink (z-normalized) | 0.98 / 1 / 1 / 1 | 0.99 / 0.96 / 1 / 1 |
| Dive / payload / hover / jink (DTW) | 0.98 / 1 / 1 / 1 | 1 / 0.96 / 1 / 1 |
| Anomaly, per drone-window | 0.98 | 0.69 |
| Swarm members | 1 | 0.9 |
| Rotor class | accuracy 1 on drones without events | |

## Measured results

Apple M4 Max (16 cores, 128 GB), 8 feed handlers, `THREADS=8`, the commit this README ships with.

**Lag by fleet size** (medians of 16 one-second samples after 12 s at each size):

| Fleet | Rows a second | kdb+ lag p50 / p99 | DuckDB lag p50 / p99 | Rows dropped |
|---|---|---|---|---|
| 1K | 0.2M | 0.08 / 0.33 ms | 1.0 / 2.0 ms | none |
| 4K | 0.8M | 0.12 / 0.56 ms | 1.2 / 2.4 ms | none |
| 16K | 3.3M | 0.34 / 2.2 ms | 2.0 / 18.6 ms | none |
| 64K | 13.1M | 0.50 / 10.8 ms | 15.0 / 60.9 ms | none |
| 256K | 52.4M asked, 24.7M produced | 782 / 937 ms | 825 / 987 ms | 14.4M a second for each lane |

Up to 64K drones both lanes keep up with every row. kdb+'s 99th-percentile lag stays 4 to 9 times
lower, and its median 6 to 30 times lower. At 256K the shared pipeline is the limit, not either
engine (see [Pushing the fleet](#pushing-the-fleet-what-overload-looks-like)).

**One analysis pass over 1,024 drones** (819,200 samples):

| | kdb+ | DuckDB |
|---|---|---|
| Whole pass, z-normalized | 41 ms | 201 ms |
| Window extraction | about 12 ms | about 23 ms |
| Signatures | 18 ms | 110 ms |
| Anomaly | 3 ms | 55 ms |
| Swarm | 7 ms | 10 ms |
| Rotor | 1 ms | 3 ms |
| Whole pass, DTW | about 265 ms | about 360 ms |
| Signatures, DTW | 242 ms | 269 ms |

DTW is close because both lanes run compiled DTW on the same 8 threads; nearly all the time is
inside the DTW search itself. With DTW on, DuckDB's p99 lag rises to 2-3.5 ms; kdb+'s stays under
0.5 ms.

**Events found over 60 s at 1,024 drones** (both lanes, from the page):

| Feature | Found | False alarms a minute |
|---|---|---|
| Dive | 99-100% | 15-19 |
| Payload release | 100% | 0-4 |
| Hover and stare | 98-99% | 0 |
| Evasive jinking | 97-99% | 0 |
| Jamming (anomaly) | 94-96% | 25-75, out of about 61,000 drone analyses a minute |
| Hidden swarm | 100% | 0-3 |
| Laden rotor | 100% | 0-7 |

The two lanes' figures differ by a few events: each lane analyses a slightly different instant,
and an event at the edge of a window can fall either way.

## Pushing the fleet: what overload looks like

Everything runs on one laptop: 8 feed handlers generating the data, one tickerplant fanning it out,
and both lanes.

- **Up to 64K drones (13.1M rows a second)** everything keeps up. No rows are dropped, and the lag
  figures are the engines' own.
- **From about 96K drones** the one tickerplant can't send rows fast enough to two full
  subscribers. Their queues reach the 256 MB limit and the tickerplant drops rows for both lanes at
  about the same rate. The kdb+ RDB uses well under one core (10-30% CPU) while this happens: the
  limit is upstream of both engines.
- **At 256K drones (52.4M rows a second asked)** the feed handlers produce only about 25M rows a
  second and skip the rest to stay current. The tickerplant drops about 14M rows a second for each
  lane. Both lanes ingest about 10M rows a second with about 1 s of lag.

What the page shows then:
- **rows dropped** turns red and climbs in both lanes;
- **lag** reaches about 1 s in both;
- **analysed data age** climbs in both.

The last one is a known limitation. The skipped samples leave gaps, so a 4 s window holds less than
the 3 s the longest signature template needs, and both lanes' passes fail. A clearer page would say
"not enough data" instead.

Use 64K to compare the engines, and 256K to show the ceiling of the pipeline on one machine.
**OFF** stops the drones at once, and the queues drain within seconds.

kdb+'s real-time engine subscribes to the watched drones only, so the tickerplant never drops its
rows even when the stores lose rows. The DuckDB lane analyses its own store, so it loses whatever
the tickerplant drops for it.

## Being fair

The comparison is only worth showing if it's fair. Everything below is deliberate.

- **Same input.** Same rows, from the same tickerplant, on the same machine, with the same
  definitions, templates and thresholds. A test (`tests/test_crosscheck.py`) runs the DuckDB lane's
  code on the rows the kdb+ lane analysed and checks every number matches.
- **A real bridge.** DuckDB has no streaming server, so the bridge is what a DuckDB deployment has
  to build. The page says so in each lane's description and in the footer.
- **Neither lane's analysis blocks its ingest.** kdb+ runs its analysis in a separate real-time
  engine, as kdb+tick does. The DuckDB lane runs its analysis on its own thread, and DTW in a
  separate worker process: dtaidistance holds Python's GIL while it computes, and DuckDB's inserts
  need the GIL. In the bridge's own process, DTW raised the bridge's p99 lag from 2 ms to 16 ms.
- **Same threads.** Each lane's analysis gets 8 threads (`THREADS`): the kdb+ engine's secondary
  threads, and dtaidistance's OpenMP threads. kdb+ also spreads block means and FFTs over its
  threads with `peach`. NumPy has no built-in parallelism for those, so it runs them on one thread.
- **Same matrix library.** Both lanes compute the swarm correlations with Apple Accelerate's BLAS:
  NumPy links it on macOS, and the kdb+ lane calls it through the KX C API. q's own `mmu` took
  24 ms for that product, against 2 ms in Accelerate. On Linux the build uses OpenBLAS or another
  CBLAS; without one, q falls back to `mmu` spread over threads.
- **Same schedule and windows.** Both lanes analyse once a second on a fixed schedule, and both end
  every drone's window at the same instant.
- **Overload is counted, not hidden.** A lane that falls behind gets its rows dropped and counted
  by the tickerplant; the page shows the count. The bridge yields after every batch, so it keeps
  reporting even when the tickerplant always has data waiting for it. An earlier version didn't:
  under overload it went silent, and the page showed DuckDB's last numbers as if they were live.

## Configuration

`./start.sh` reads these environment variables:

| Variable | Default | What it sets |
|---|---|---|
| `SHARDS` | CPU cores − 6, between 1 and 8 | number of feed handlers |
| `THREADS` | 8 | analysis threads for each lane: the kdb+ engine's secondary threads and the DuckDB lane's OpenMP threads |
| `MAXROWS` | 60,000,000 | rows each lane keeps before trimming to the newest two thirds |
| `Q` | `q`, else `~/.kx/bin/q` | the q binary |

`config.json` holds what both lanes share: watched drones (1,024), window (4 s), analysis rate
(50 Hz), pass interval (1,000 ms), default shape search, DTW warping window (10%), every threshold,
the anomaly window (0.5 s), the swarm channels and minimum group size, and the rotor's FFT length,
band, class frequencies and laden factor. After changing it, regenerate the cross-check fixture
(see [Tests](#tests)).

The tickerplant's queue limit is `-maxq` in MB (default 256). With `-log 1` it also writes a log
you can replay with `-11!`.

## Tests

```bash
q tests/test_fft.q && q tests/test_blas.q && q tests/test_gen.q   # the C libraries and the generator
uv run pytest                              # the cross-check, the DuckDB store and the launcher
q tools/calibrate.q -s 8                   # precision and recall of every feature against planted events
```

After changing `analytics.q`, `config.json` or `templates.json`, regenerate the cross-check fixture
with `q tools/fixture.q -s 4`.

## Troubleshooting

| You see | Do this |
|---|---|
| "not running on :5111" or ":5130" | Press **Start** on the page; if it's greyed out, run `./start.sh`. |
| Picking a fleet size after **Shut down** does nothing | The launcher isn't running (you ran `./stop.sh`, or started with an older `start.sh`). Run `./start.sh` once; from then on the page can start everything. |
| The fleet changes by itself | Another tab has an older copy of the page, which sets its own fleet whenever it reconnects. Reload or close it. |
| `./start.sh` fails with "address already in use" | Run `./stop.sh` first. It stops anything left from a previous run, and force-stops any process that hasn't exited after 5 s. |
| No OFF button on the page | Reload the page: the tab has an old copy. |
| **rows dropped** stays high after you lower the fleet | It counts from the tickerplant's start. Restart (`./stop.sh`, `./start.sh`) to reset it. |
| **analysed data age** red at 256K | The feed handlers are skipping samples and windows are too short to analyse (see [Pushing the fleet](#pushing-the-fleet-what-overload-looks-like)). Lower the fleet. |

Each process logs to `logs/` (`tp.log`, `fh0.log` …, `rdb.log`, `rte.log`, `bridge.log`).

## Files

| Path | What it is |
|---|---|
| `stream-duel.html` | the page |
| `gen.q` | telemetry-kit's signal generator plus planted events, airframe classes and groups; `planted[]` lists the events for scoring |
| `fh.q`, `tp.q` | feed handlers and the tickerplant (ports 5120+, 5110) |
| `rdb.q`, `rte.q`, `analytics.q` | the kdb+ lane: storage and stats (5111), real-time engine (5112), the pattern matching |
| `c/kx_fft.c`, `c/kx_blas.c`, `c/build.sh` | KissFFT and the platform BLAS exposed to q through the KX C API (`lib/kxfft.so`, `lib/kxblas.so`) |
| `bridge/` | the DuckDB lane (5130): `server.py` (subscription, websocket), `store.py` (DuckDB), `analytics.py` (the pattern matching) |
| `config.json`, `templates.json` | shared settings, thresholds and signature templates |
| `tools/templates.q`, `tools/calibrate.q`, `tools/fixture.q` | write the templates, choose thresholds against planted truth, write the cross-check fixture |
| `start.sh`, `stop.sh` | start and stop every process (`stop.sh --keep-launcher` leaves the launcher running) |
| `launcher.py` | lets the page start and stop everything (port 5100, localhost only) |
| `tests/` | the cross-check, the DuckDB store, the launcher, the C libraries, the generator |
| `DESIGN.md` | the contract both lanes and the page follow, including message formats |

## Glossary

| Term | Meaning |
|---|---|
| Feed handler | A process that produces data and sends it to the tickerplant. Here it generates synthetic drones. |
| Tickerplant | The kdb+ process every update goes through: it stamps each batch and publishes it to subscribers. |
| RDB | Real-time database: a kdb+ process that holds today's rows in memory. |
| Real-time engine (RTE) | A kdb+ subscriber that computes on the stream next to the data, so analysis never blocks the RDB. |
| Lag p50 / p99 | Median and 99th-percentile time from tickerplant stamp to queryable. p99 is the delay 99% of rows beat. |
| Z-normalization | Rescaling a series to mean 0 and standard deviation 1, so shapes compare regardless of level or size. |
| TSS | Time series (subsequence) search: find where a short shape best matches inside a longer series. |
| DTW | Dynamic time warping: a distance that lets one series stretch or compress in time to match another. |
| Discord | The part of a series least like anything else in it: the anomaly score here. |
| Gram matrix, BLAS | The matrix of all pairwise dot products; BLAS is the standard library interface for computing such products fast. |
| KX C API | The C interface for extending q: `2:` loads a C function into q. |
| `peach` | q's parallel each: spreads work over the secondary threads (`-s`). |
| PyKX | KX's Python interface; here only its IPC client, with no q runtime. |
| GIL | Python's global interpreter lock: one thread at a time runs Python code. |

## Credits

Built on telemetry-kit (the q generator, tickerplant and RDB). KissFFT by Mark Borgerding (BSD-3,
`c/vendor/kissfft`). `k.h` from KxSystems/kdb (Apache-2.0, `c/vendor`).
