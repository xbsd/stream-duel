#!/usr/bin/env bash
# Starts tickerplant, feed handler shard(s) and RDB in the background.
#   ./start.sh                 one feed handler per spare core: CPU cores minus 4, between 1 and 12
#   SHARDS=6 ./start.sh        six feed handlers
#   LOG=1 ./start.sh           tickerplant also writes every row to disk
#   MAXROWS=100000000 ./start.sh   rows the RDB keeps in memory
set -euo pipefail
cd "$(dirname "$0")"
Q=${Q:-q}
# leave 4 cores for the tickerplant, the RDB, the browser and the OS
CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
AUTO=$((CORES-4)); ((AUTO<1)) && AUTO=1; ((AUTO>12)) && AUTO=12
SHARDS=${SHARDS:-$AUTO}
LOG=${LOG:-0}
MAXROWS=${MAXROWS:-60000000}
command -v "$Q" >/dev/null || { echo "Can't find '$Q' on PATH. Install KDB-X or kdb+, or run Q=/path/to/q ./start.sh"; exit 1; }
mkdir -p logs
: > logs/pids
nohup "$Q" tp.q -p 5010 -log "$LOG" < /dev/null > logs/tp.log 2>&1 &
echo $! >> logs/pids
sleep 1
for ((i=0; i<SHARDS; i++)); do
  nohup "$Q" fh.q -p $((5020+i)) -shard "$i" -of "$SHARDS" -tp 5010 < /dev/null > "logs/fh$i.log" 2>&1 &
  echo $! >> logs/pids
done
sleep 1
nohup "$Q" rdb.q -p 5011 -tp 5010 -fh 5020 -shards "$SHARDS" -maxrows "$MAXROWS" < /dev/null > logs/rdb.log 2>&1 &
echo $! >> logs/pids
sleep 1
echo "Running: tickerplant :5010, RDB :5011, $SHARDS feed handler(s) from :5020."
echo "Open telemetry-wall.html in your browser. Logs are in ./logs. Stop with ./stop.sh"
