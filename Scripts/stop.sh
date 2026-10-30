#!/usr/bin/env bash
# QuickCull stop script: gracefully quits the running app.
#
# Usage: ./stop.sh
set -euo pipefail
cd "$(dirname "$0")"

if ! pgrep -x QuickCull >/dev/null 2>&1; then
    echo "QuickCull is not running."
    exit 0
fi

echo "Quitting QuickCull…"
# Graceful quit (also runs the app's best-effort quit-time cache wipe).
osascript -e 'tell application "QuickCull" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
    pgrep -x QuickCull >/dev/null 2>&1 || { echo "QuickCull stopped."; exit 0; }
    sleep 0.3
done
pkill -x QuickCull >/dev/null 2>&1 || true
echo "QuickCull stopped."
