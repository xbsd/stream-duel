# Drone telemetry wall, recorded in q

A local demo: q generates drone telemetry, a tickerplant stamps and publishes it, and an RDB records it. A browser page draws every drone on the GPU and shows what the RDB is holding, live.

## Quick start on a Mac

1. **Install q.** Install KDB-X (or kdb+) from kx.com. Check it works: open Terminal, type `q`, and you should get a `q)` prompt. Type `\\` to quit.
2. **Unzip the kit.** Double-click `telemetry-kit.zip`. You get a `telemetry-kit` folder.
3. **Start it.** In Terminal:
   ```bash
   cd ~/Downloads/telemetry-kit      # or wherever you unzipped it
   chmod 755 start.sh stop.sh        # once, so the scripts can run
   ./start.sh
   ```
4. **Open the page.**
   ```bash
   open telemetry-wall.html
   ```
   The green chip at the top says **Recording in q on :5011** once it's connected.
5. **Try it.** Press keys **1** to **7** to change the fleet size (1 drone up to 1M). Click **Live table** at the top to watch rows arrive, and **Wall** to go back.
6. **Stop it** when you're done: click **Shut down q** on the page (click twice to confirm), or run:
   ```bash
   ./stop.sh
   ```
   Either one stops the tickerplant, every feed handler and the RDB, which closes ports 5010, 5011 and 5020 upward.

If something goes wrong:

- **"Can't find 'q' on PATH"**: open a new Terminal window after installing q. If that doesn't help, point the kit at q directly, e.g. `Q=~/.kx/bin/q ./start.sh`.
- **The chip says "q not running on :5011"**: check `logs/rdb.log`. Another program may be using ports 5010, 5011 or 5020 upward; stop it, then run `./stop.sh` and `./start.sh` again.
- **The page is blank or has no graphs**: use a current Chrome or Safari.

## What runs where

| Process | Port | Job |
|---|---|---|
| `tp.q` | 5010 | Tickerplant. Stamps each batch, publishes to the RDB, and can log every row to disk. |
| `fh.q` | 5020, 5021, … | Feed handlers. Each one owns a slice of the fleet and publishes every sample that's due, every 10 ms. |
| `rdb.q` | 5011 | RDB. Records the `telem` table and serves the page over a websocket. |
| `telemetry-wall.html` | | The page. It draws on the GPU, sends fleet size and sample rate to q, and shows q's numbers. |
| `telemetry-table.html` | | Live table. The newest 25 to 100 rows of `telem`, newest first, up to 30 times a second, with rows and metrics per second. It only reads; it never changes the fleet. Open it from the wall's **Live table** button (or `telemetry-wall.html#table`), or on its own. |

The data is synthetic, but it is generated and recorded in q. The page doesn't stream 20M samples a second into the browser. Instead, the GPU runs the same seeded function the feed handlers use (`gen.q`), bit for bit on the hash, so each trace is the series q recorded for that drone. Three things on the page come straight from the RDB, so you can check that they agree:

- **The tiles above the wall and the "Recorded in q" panel**: rows recorded, rows and metrics per second (metrics = rows × columns), RDB memory, and the row limit (pick it from "Keep newest"; past it, the RDB drops the oldest third).
- **The tap**: the last rows in `telem`.
- **The hover readout**: the drone's latest row in the RDB.

## Run it

You need:

- **q**: KDB-X or kdb+ 4.x, with `q` on your PATH and your own licence. Each q process here is single-threaded.
- **A browser with WebGL2**: a current Chrome, Edge, Safari or Firefox.
- **Free ports** 5010, 5011 and 5020 upward (one per feed handler).
- **Python 3**, only if you serve the page over localhost (see below).

macOS or Linux:

```bash
cd telemetry-kit
./start.sh               # tickerplant, RDB, and one feed handler per spare CPU core
open telemetry-wall.html # or double-click it
./stop.sh                # when you're done
```

Windows: run `start.bat`, then open `telemetry-wall.html`. To stop, close the q windows.

When the page finds q, the chip at the top says **Recording in q on :5011**. From then on, the fleet toggle (keys 1–7) and the sample-rate menu drive the feed handlers. The **Wall | Live table** switch in the header shows the newest rows of `telem` as they arrive.

Some browsers built into other apps (terminal and editor panes, for example) won't open a page from a file. Serve the folder over localhost instead:

```bash
python3 -m http.server 8765
# then open http://localhost:8765/telemetry-wall.html
```

Every open copy of the wall drives the same q: the last one to change the fleet size or sample rate wins. The live table only reads.

## Knobs

```bash
SHARDS=6 ./start.sh            # feed handlers, one CPU core each (default: cores minus 4, between 1 and 12)
LOG=1 ./start.sh               # tickerplant writes every row to telem_<date>.log
MAXROWS=100000000 ./start.sh   # rows the RDB keeps in memory (default 60M, about 2 GB)
Q=/path/to/q ./start.sh        # if q isn't on PATH
```

Here's how memory and disk behave:

- **The RDB keeps the newest MAXROWS rows.** When it passes that, it trims back to two thirds. The page's "Keep newest" menu changes the limit while q runs; a restart goes back to MAXROWS.
- **"Rows recorded" counts everything.** That includes rows the RDB has since trimmed.
- **LOG=1 puts every row on disk.** At 36 bytes a row, 2M rows a second is about 72 MB a second, so watch the disk.

## What to expect on one desktop

Generating the data costs more than ingesting it. Each feed handler is one q process doing about 20 sin/exp evaluations per row. Measured on an Apple M4 Max:

| What | Rate |
|---|---|
| One feed handler generating rows, one core | about 4.9M rows a second (plan on about 4M once it also sends them) |
| RDB inserting 10,000-row batches, one core | about 165M rows a second |
| 6 feed handlers, 1 tickerplant, 1 RDB, end to end | kept up with 10M rows a second (1M drones at 10 Hz) |

So you need about one feed handler per 4M rows a second. Past 10–20M rows a second, the single tickerplant and RDB become the limit, and more feed handlers stop helping. The "Rows per second" tile shows the configured rate with the measured rate under it; the measured line turns amber when q falls behind.

The 20M rows a second case (100,000 drones at 200 Hz) needs several feed-handler cores. It also needs a lot of RAM: at that rate the RDB grows by about 0.7 GB a second. Production deployments shard the tickerplant and RDB the way the "Production sizing" panel shows.

## Query it from q

```q
h:hopen 5011
h"count telem"
h"select n:count i, avg alt, max imuz by uav from telem where uav<6"
h"select from telem where uav=42i, stime>.z.p-0D00:00:01"
h"saveHdb[]"      / same as the page's Save button: writes hdb/<date>/telem, sorted and `p# on uav
h"clearRdb[]"     / same as the page's Clear button: empties telem and resets the rows-recorded count
neg[h]"shutdown[]" / same as the page's Shut down button: stops the feed handlers, tickerplant and RDB
```

Then open the HDB in a fresh session:

```bash
q hdb
```
```q
select count i by date from telem
select from telem where date=.z.D, uav=42i
```

## Files

- `schema.q`: the `telem` table (36-byte rows).
- `gen.q`: the hash and the signal model, shared with the page's shader.
- `tp.q`, `fh.q`, `rdb.q`: tickerplant, feed handler, RDB.
- `telemetry-wall.html`: the wall, with the q tiles, the sizing panel and the Wall | Live table switch.
- `telemetry-table.html`: the live table, on its own page or inside the wall.
- `start.sh`, `stop.sh`, `start.bat`: launchers. Process output goes to `logs/`.

All the data is synthetic. The pages load two Google Fonts and fall back to system fonts offline; nothing else leaves your machine.
