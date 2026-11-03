# Stream Duel: design

One drone telemetry feed, two engines, side by side: **kdb+ (KDB-X)** and **DuckDB** ingest the
same rows from the same tickerplant and run the same real-time pattern matching on them. The page
shows, live and measured, how fast each one ingests, how fresh its data is, and what each one finds.
Built for an internal KX audience. Everything is synthetic.

## Processes and ports

| Process | Port | Lane | Job |
|---|---|---|---|
| `fh.q` (one or more) | 5120 + shard | both | Feed handlers: deterministic telemetry with planted events (`gen.q`) |
| `tp.q` | 5110 | both | Tickerplant: stamps each batch, publishes it to its subscribers; a subscriber that falls more than `-maxq` MB behind is skipped and its dropped rows are counted per lane. `.u.subw` subscribes to drones 1..w only, as kdb+tick's subscription to a sym list |
| `rdb.q` | 5111 | kdb+ | RDB: stores `telem`, measures lag, serves the page over a websocket and relays the real-time engine's results |
| `rte.q` | 5112 | kdb+ | Real-time engine: subscribes to the 1,024 watched drones only (`.u.subw`), keeps their last seconds, runs `analytics.q` every second |
| `bridge/` (Python) | 5130 | DuckDB | Subscribes to the tickerplant over kdb+ IPC (PyKX, unlicensed: no q runtime), appends to an in-memory DuckDB, measures lag, runs the analytics, serves the page over a websocket |
| `stream-duel.html` | | | The page: two lanes, opened as a file |

Ports are telemetry-kit's plus 100, so both kits can run at once.

## The data

`telem` is telemetry-kit's table, unchanged: `time` (tickerplant stamp, timespan), `stime` (sample
time, UTC), `uav` (int), `alt` (m), `ias` (m/s), `rpm`, `imuz` (vertical acceleration, m/s²). The
fleet runs at `hz` samples per second per drone (default 200).

**Watched drones** are `uav` 1 to `W` (`W` = min(fleet, 1024)). Events are planted on them and the
analytics run on them, so analytics cost stays bounded while ingest scales to a million drones.

### Planted events (`gen.q`, deterministic)

Sample time `ts` is wrapped to [0, 1024) s, as in telemetry-kit. It is cut into 16 s slots. For each
watched drone and slot a hash decides whether an event is planted (about one slot in four), which
type, and when it starts (2 to 12 s into the slot):

| Event | Duration | What changes | Found by |
|---|---|---|---|
| `dive` | 3 s | altitude drops about 45 m while airspeed rises about 8 m/s | signature |
| `payload` | 1 s | laden until release (rotor 8% slower), then a vertical-acceleration spike and the rotor speeds up | signature, rotor |
| `hover` | 5 s | airspeed falls to about 1 m/s, altitude holds | signature |
| `jink` | 3 s | 3 Hz vertical-acceleration oscillation with airspeed wobble | signature |
| `jam` | 2 s | broadband noise on every channel | anomaly |

**Coordinated groups:** watched drones form groups of six consecutive ids. In about one slot in
five a group flies coordinated: all six follow the group's altitude and airspeed waveform.

**Airframe class:** each drone's class (A, B or C) comes from a hash of its id and sets the rotor's
dominant frequency: 11, 17 or 23 Hz (8% lower while laden).

`planted[t0;t1]` (q, in `gen.q`) returns the planted events overlapping a time window. Only the
page's scoring uses it; neither lane's analytics does.

## The analytics (identical semantics in both lanes)

Every second, on a fixed schedule, each lane takes the newest **4 s** of every watched drone's
samples it holds and runs the features below. Every drone's window ends at the same instant: the
newest sample time all watched drones have reached (feed handler shards publish a few milliseconds
apart, and drones shifted against each other by a sample would break a swarm's correlation).

| Feature | Input | kdb+ lane | DuckDB lane | Output |
|---|---|---|---|---|
| **Signatures** | alt, ias, imuz, downsampled to 50 Hz | `.ai.tss.tss` (z-normalized) or `.ai.dtw.search`, per channel, built into KDB-X, `peach` over drones | NumPy z-normalized distance profile, or dtaidistance DTW with KDB-X's definition (in a worker process, OpenMP threads) | per drone, best signature and its distance (mean over the signature's channels) when below its threshold |
| **Anomaly** | imuz at 50 Hz | `.ai.tss.tssdist`: distance of the newest 0.5 s to its nearest match earlier in the window | NumPy, the same distance | drones whose score is above the threshold |
| **Swarm** | altitude and airspeed first differences at 50 Hz | z-normalize, all pairwise correlations as one matrix product: the platform BLAS via the KX C API (`lib/kxblas.so`, `gram`; Apple Accelerate on macOS), or `mmu` with `peach` without one | z-normalize, NumPy matrix product (Accelerate on macOS) | groups of three or more drones whose correlation on both channels is above 0.99 (connected components) |
| **Rotor** | rpm at full rate, newest 512 samples | **KissFFT via the KX C API** (`lib/kxfft.so`, `fftpeak`), one call per thread's share of the drones | `numpy.fft` | dominant 5 to 40 Hz frequency per drone, its class, and laden (8% low) |

Thresholds live in `config.json`, shared by both lanes. Each lane's analytics use the same number
of threads (`THREADS`, default 8): the kdb+ engine's secondary threads (`-s`; `peach` over drones
for signatures, anomaly, block means and FFTs), and the DuckDB lane's OpenMP threads for DTW
(elsewhere NumPy: its matrix product runs in Accelerate, the rest on one thread).

Each lane reports after every pass:
`{type:"analytics", lane, took:{signatures,anomaly,swarm,rotor} (ms), newest (stime of the newest
sample used), rows (samples analysed), signatures:[[uav,sig,dist]], anomalies:[[uav,score]],
swarms:[[uav...]], rotor:[[uav,hz,class,laden]]}`.

## Ingest metrics (both lanes, every 250 ms)

`{type:"stats", lane, rate (rows/s, smoothed), total, held, lag:{p50,p99} (ms, tickerplant stamp to
queryable, row-weighted over the last 5 s), mem (bytes), dropped (rows the tickerplant skipped for
this lane), tap:[8 newest rows]}`. kdb+: lag at insert in the RDB. DuckDB: lag after the insert
commits. Same machine, same clock.

## Scoring (on the page)

The real-time engine also sends, through the RDB, `{type:"planted", events:[[uav,type,start,end]...]}`
for the last 60 s. A lane **found** a planted event when it reported that drone, with a matching
feature, from 1 s before the event to 4.5 s after it ended (while a 4 s window can still hold it).
The page shows found / planted and false alarms for each lane and feature over the last 60 s.

## Honesty rules

- Both lanes get exactly the same rows, from the same tickerplant, on the same machine.
- The page names every implementation choice: the DuckDB lane is a Python bridge (DuckDB has no
  streaming server), its analytics extract with SQL and compute in NumPy and dtaidistance; the kdb+
  lane computes in a real-time engine next to the RDB with KDB-X's AI libraries and a C library.
- Every number on the page is measured; nothing is scripted.
