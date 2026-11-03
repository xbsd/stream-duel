#!/usr/bin/env bash
cd "$(dirname "$0")"
[ -f logs/pids ] && kill $(cat logs/pids) 2>/dev/null || true
rm -f logs/pids
echo "Stopped."
