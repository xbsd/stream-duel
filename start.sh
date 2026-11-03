#!/usr/bin/env bash
# Starts Stream Duel (DESIGN.md): tickerplant, feed handler shard(s), the kdb+ lane (RDB and
# real-time engine) and the DuckDB lane (Python bridge), in the background.
#   ./start.sh                 one feed handler per spare core: CPU cores minus 6, between 1 and 8
#   SHARDS=4 ./start.sh        four feed handlers
#   THREADS=8 ./start.sh       analytics threads for each lane: the kdb+ real-time engine's
#                              secondary threads and the DuckDB lane's DTW threads (default 8)
#   MAXROWS=100000000 ./start.sh   rows each lane keeps in memory
set -euo pipefail
cd "$(dirname "$0")"
Q=${Q:-q}
command -v "$Q" >/dev/null || { [ -x "$HOME/.kx/bin/q" ] && Q="$HOME/.kx/bin/q"; }
command -v "$Q" >/dev/null || { echo "Can't find 'q'. Install KDB-X, or run Q=/path/to/q ./start.sh"; exit 1; }
command -v uv >/dev/null || { echo "Can't find 'uv' (https://docs.astral.sh/uv/), needed for the DuckDB lane."; exit 1; }
[ -f lib/kxfft.so ] && [ -f lib/kxblas.so ] || ./c/build.sh
uv sync -q
CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
AUTO=$((CORES-6)); ((AUTO<1)) && AUTO=1; ((AUTO>8)) && AUTO=8
SHARDS=${SHARDS:-$AUTO}
THREADS=${THREADS:-8}
MAXROWS=${MAXROWS:-60000000}
mkdir -p logs
[ -f logs/pids ] && ./stop.sh >/dev/null
: > logs/pids
nohup "$Q" tp.q -p 5110 < /dev/null > logs/tp.log 2>&1 &
echo $! >> logs/pids
sleep 1
for ((i=0; i<SHARDS; i++)); do
  nohup "$Q" fh.q -p $((5120+i)) -shard "$i" -of "$SHARDS" -tp 5110 < /dev/null > "logs/fh$i.log" 2>&1 &
  echo $! >> logs/pids
done
sleep 1
nohup "$Q" rdb.q -p 5111 -tp 5110 -fh 5120 -shards "$SHARDS" -maxrows "$MAXROWS" < /dev/null > logs/rdb.log 2>&1 &
echo $! >> logs/pids
sleep 1
nohup "$Q" rte.q -p 5112 -tp 5110 -rdb 5111 -s "$THREADS" < /dev/null > logs/rte.log 2>&1 &
echo $! >> logs/pids
OMP_NUM_THREADS="$THREADS" PYKX_UNLICENSED=true nohup uv run python -m bridge --port 5130 --tp 5110 --maxrows "$MAXROWS" < /dev/null > logs/bridge.log 2>&1 &
echo $! >> logs/pids
sleep 3
echo "Running: tickerplant :5110, kdb+ lane (RDB :5111, real-time engine :5112), DuckDB lane (bridge :5130), $SHARDS feed handler(s) from :5120."
echo "Open stream-duel.html in your browser. Logs are in ./logs. Stop with ./stop.sh"
