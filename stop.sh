#!/usr/bin/env bash
# Stops every Stream Duel process started by start.sh, the launcher (:5100) included:
#   ./stop.sh                  everything
#   ./stop.sh --keep-launcher  everything but the launcher, so the page can start it again
# SIGTERM first, then SIGKILL for any still running after 5 s (an overloaded process may never get
# round to handling SIGTERM).
cd "$(dirname "$0")"
ours() {  # pids from $@ that are still running and are Stream Duel's (never a recycled pid)
  for p in "$@"; do
    ps -o command= -p "$p" 2>/dev/null | grep -qE "(tp|fh|rdb|rte)\.q|-m bridge|multiprocessing|launcher\.py" && echo "$p"
  done
}
launcher=
[ "${1:-}" = "--keep-launcher" ] || launcher=$(pgrep -f "launcher.py --port 5100")
pids="$( [ -f logs/pids ] && cat logs/pids) $(pgrep -f "python -m bridge --port 5130") $(pgrep -f "$PWD/.venv/bin/python -c from multiprocessing") $launcher"
live=$(ours $pids | sort -u)
[ -n "$live" ] && kill $live 2>/dev/null
for _ in $(seq 50); do
  live=$(ours $live)
  [ -z "$live" ] && break
  sleep 0.1
done
[ -n "$live" ] && kill -9 $live 2>/dev/null && echo "Forced: $(echo $live)"
rm -f logs/pids
echo "Stopped."
