# Stream Duel: design

One drone telemetry feed through one kdb+ tickerplant, and three pages on it: the fleet wall (every
drone drawn on the GPU), live data (the newest rows), and the duel, where **kdb+ (KDB-X)** and
**DuckDB** ingest the same rows and run the same real-time pattern matching, measured live. Built
for an internal KX audience. Everything is synthetic.

## Processes and ports

| Process | Port | Lane | Job |
|---|---|---|---|
| `fh.q` (one or more) | 5120 + shard | both | Feed handlers: deterministic telemetry with planted events, sent as two tables at two rates (`gen.q`'s `blockRows`) |
| `tp.q` | 5110 | both | Tickerplant: stamps each batch, publishes it to its subscribers; a subscriber that falls more than `-maxq` MB behind is skipped and its dropped rows are counted per lane. `.u.subw` subscribes to drones 1..w only, as kdb+tick's subscription to a sym list |
| `rdb.q` | 5111 | kdb+ | RDB: stores `telem` and `rotor`, measures lag, serves every page over a websocket (stats, newest rows, a drone's latest rows, save, clear, fleet) and relays the real-time engine's results |
| `rte.q` | 5112 | kdb+ | Real-time engine: subscribes to the 1,024 watched drones only (`.u.subw`), keeps their last seconds, runs `analytics.q` every second |
| `bridge/` (Python) | 5130 | DuckDB | Subscribes to the tickerplant over kdb+ IPC (PyKX, unlicensed: no q runtime), appends to an in-memory DuckDB, measures lag, runs the analytics, serves the page over a websocket |
| `launcher.py` (Python) | 5100 | | Serves the pages over http (`/` goes to `fleet-wall.html`; only the three pages and `common.js`, only for requests addressed to localhost). Runs `start.sh` or `stop.sh --keep-launcher` when a page asks over a websocket on the same port, only for a page opened from localhost or from a file. The pages' **Shut down** and **Start** go through it, and it keeps running after **Shut down**, so the site stays up. |
| `fleet-wall.html`, `live-data.html`, `stream-duel.html` | | | The three pages, served at http://localhost:5100 (or opened as files). `common.js` gives them the bar of page links, the About the data popup and the launcher client. |

Ports are telemetry-kit's plus 100, so both kits can run at once.

## The data

Each drone senses at 200 Hz (`SENSORHZ`) and sends two tables (`schema.q`), built by `gen.q`'s
`blockRows` from 20 ms blocks of 4 sensor samples:

- `telem`, 50 rows a second per drone (`TELEHZ`), 32 bytes: `time` (tickerplant stamp, timespan),
  `stime` (the block's start, UTC timestamp), `uav` (int), and the means of the block's samples of
  `alt` (m), `ias` (m/s) and `imuz` (vertical acceleration, m/s²), all real;
- `rotor`, 100 rows a second per drone (`ROTORHZ`), 24 bytes: `time`, `stime`, `uav`, and `rpm` at
  sensor samples 0 and 2 of each block.

That is what the analytics need: telemetry at 50 Hz, the rotor's 5 to 40 Hz band at more than
80 Hz. 150 rows, 250 measured values and 4,000 bytes per drone per second, against 200 rows, 800
values and 7,200 bytes for all four metrics at 200 Hz.

**Watched drones** are `uav` 1 to `W` (`W` = min(fleet, 1024)). Events are planted on them and the
analytics run on them, so analytics cost stays bounded while ingest scales to a million drones.

The wall draws the same rows on the GPU: its shader and JavaScript implement `sigDuel` and
`blockRows` line for line, so its traces are the series q records (checked against q to within
q's 32-bit float storage).

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
telemetry (200 rows at 50 Hz) and its newest **256 rotor samples** (2.56 s at 100 Hz), and runs the
features below. Every drone's telemetry window ends at the same instant: the newest sample time all
watched drones have reached (feed handler shards publish a few milliseconds apart, and drones
shifted against each other by a row would break a swarm's correlation). A window shorter than the
longest template (150 rows: the feed skipped samples) is reported as `short` instead.

| Feature | Input | kdb+ lane | DuckDB lane | Output |
|---|---|---|---|---|
| **Signatures** | alt, ias, imuz at 50 Hz | `.ai.tss.tss` (z-normalized) or `.ai.dtw.search`, per channel, built into KDB-X, `peach` over drones | NumPy z-normalized distance profile, or dtaidistance DTW with KDB-X's definition (in a worker process, OpenMP threads) | per drone, best signature and its distance (mean over the signature's channels) when below its threshold |
| **Anomaly** | imuz at 50 Hz | `.ai.tss.tssdist`: distance of the newest 0.5 s to its nearest match earlier in the window | NumPy, the same distance | drones whose score is above the threshold |
| **Swarm** | altitude and airspeed first differences at 50 Hz | z-normalize, all pairwise correlations as one matrix product: the platform BLAS via the KX C API (`lib/kxblas.so`, `gram`; Apple Accelerate on macOS), or `mmu` with `peach` without one | z-normalize, NumPy matrix product (Accelerate on macOS) | groups of three or more drones whose correlation on both channels is above 0.99 (connected components) |
| **Rotor** | rpm at 100 Hz, newest 256 samples | **KissFFT via the KX C API** (`lib/kxfft.so`, `fftpeak`, in `rotorFind`), one call per thread's share of the drones | `numpy.fft` | dominant 5 to 40 Hz frequency per drone, its class, and laden (8% low) |

Thresholds live in `config.json`, shared by both lanes. Each lane's analytics use the same number
of threads (`THREADS`, default 8): the kdb+ engine's secondary threads (`-s`; `peach` over drones
for signatures, anomaly and FFTs), and the DuckDB lane's OpenMP threads for DTW (elsewhere NumPy:
its matrix product runs in Accelerate, the rest on one thread).

Each lane reports after every pass:
`{type:"analytics", lane, mode, took:{window,signatures,anomaly,swarm,rotor} (ms), newest (unix ms
of the newest telemetry sample used), rows (telemetry and rotor samples analysed),
signatures:[{uav,sig,dist,at}], anomalies:[{uav,score}], swarms:[[uav...]],
rotor:[{uav,hz,cls,laden}]}`, or `{type:"analytics", lane, short:true, have_s, need_s, newest}`.

## Ingest metrics (both lanes, every 250 ms)

`{type:"stats", lane, n (fleet), mode, demand (rows/s the fleet sends), rate (rows/s stored,
smoothed), vrate (measured values/s stored), total, vtotal, held, tables:{telem,rotor}, lag:{p50,p99}
(ms, tickerplant stamp to queryable, row-weighted over the last 5 s), mem (bytes), dropped (rows the
tickerplant skipped for this lane), maxrows, tap:[newest rows of both tables, a value the table
doesn't carry is null]}`. The RDB also sends `shards`, `telem_hz`, `rotor_hz` and `vdemand` for the
wall. kdb+: lag at insert in the RDB. DuckDB: lag after the insert commits. Same machine, same clock.

## Requests the pages send (JSON over the websockets)

| To | Request | Answer |
|---|---|---|
| both lanes | `{cmd:"fleet", n}` | none: the next stats carry the new fleet (the RDB passes it to the feed handlers and the real-time engine) |
| both lanes | `{cmd:"mode", mode:"tss"\|"dtw"}` | `{type:"mode", lane, mode}` to every page |
| both lanes | `{cmd:"clear"}` | `{type:"cleared", lane, rows, ms}` to every page |
| both lanes | `{cmd:"keep", n}` | none: the row limit changes |
| both lanes | `{cmd:"last", n}` | `{type:"last", lane, total, held, telem:[rows], rotor:[rows]}`, newest first, at most 500 each |
| RDB | `{cmd:"hover", id}` | `{type:"hover", id, telem:row\|null, rotor:row\|null}`: the drone's latest row in each table |
| RDB | `{cmd:"save"}` | `{type:"saved", rows, path, ms}`: both tables to `hdb/<date>/` |
| both lanes | `{cmd:"shutdown"}` | `{type:"shutdown", lane}`; the pages use the launcher's `{cmd:"stop"}` when it runs |
| launcher | `{cmd:"start"}`, `{cmd:"stop"}`, `{cmd:"status"}` | `{type:"launcher", state:"idle"\|"starting"\|"stopping"\|"failed", detail, root}`; `root` is the folder, for the start command a page shows |

A page sends `fleet` and `mode` only when someone clicks, or after it started the system; otherwise
it follows the RDB's fleet and mode from the stats, and keeps the DuckDB lane in step with them.

## Scoring (on the page)

The real-time engine also sends, through the RDB, `{type:"planted", events:[[uav,type,start,end]...]}`
for the last 60 s. A lane **found** a planted event when it reported that drone, with a matching
feature, from 1 s before the event to 4.5 s after it ended (while a 4 s window can still hold it).
The page shows found / planted and false alarms for each lane and feature over the last 60 s.

## Honesty rules

- Both lanes get exactly the same rows, from the same tickerplant, on the same machine.
- The wall draws what q records: the same formulas, the same hash, the same two rates.
- The page names every implementation choice: the DuckDB lane is a Python bridge (DuckDB has no
  streaming server), its analytics extract with SQL and compute in NumPy and dtaidistance; the kdb+
  lane computes in a real-time engine next to the RDB with KDB-X's AI libraries and a C library.
- Every number on the page is measured; nothing is scripted.
