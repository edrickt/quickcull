#!/usr/bin/env bash
# QuickCull start script: quits any running instance, builds (Release), launches.
#
# Usage: ./start.sh
#
# In sandboxed environments (e.g. the DSH harness) the Swift macro compiler
# needs the sandbox disabled; the script detects that case automatically.
# On a normal Mac it builds with plain xcodebuild.
set -euo pipefail
cd "$(dirname "$0")"

APP="Build/Release/Build/Products/Release/QuickCull.app"

echo "Quitting running QuickCull instances (if any)…"
osascript -e 'tell application "QuickCull" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
    pgrep -x QuickCull >/dev/null 2>&1 || break
    sleep 0.3
done
pkill -x QuickCull >/dev/null 2>&1 || true

echo "Building QuickCull (Release)…"
# Extra Swift frontend flags for sandboxed environments (e.g. the DSH
# harness, where swift-plugin-server's nested sandbox-exec is denied).
# Always expanded as a single quoted argument, so no bash-3.2 array traps.
EXTRA_FLAGS=""
if [ -n "${DSH_SESSION_ID:-}" ]; then
    EXTRA_FLAGS=" -Xfrontend -disable-sandbox"
fi
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Release \
    -derivedDataPath Build/Release \
    OTHER_SWIFT_FLAGS='$(inherited)'"${EXTRA_FLAGS}" build

echo "Launching QuickCull…"
open "$APP"
echo "QuickCull is running."
