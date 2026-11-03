#!/usr/bin/env bash
# Stops every Stream Duel process started by start.sh.
cd "$(dirname "$0")"
[ -f logs/pids ] && kill $(cat logs/pids) 2>/dev/null || true
pkill -f "python -m bridge --port 5130" 2>/dev/null || true
rm -f logs/pids
echo "Stopped."
