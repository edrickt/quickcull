#!/usr/bin/env bash
# Install QuickCull.app to your Applications folder like a regular Mac app.
#
# Usage:
#   ./Scripts/install.sh              # build Release and install to /Applications (needs admin)
#   ./Scripts/install.sh --user       # build and install to ~/Applications
#   ./Scripts/install.sh --no-build   # just copy the already-built app
#   ./Scripts/install.sh --help
#
# The app is ad-hoc signed (Sign to Run Locally) with Hardened Runtime OFF,
# so Gatekeeper will show "unverified developer" on first launch. Right-click
# the app → Open → Open to approve once, then it launches normally afterwards.
# For distribution you'd re-enable Hardened Runtime and sign with a Developer ID.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Applications"
NO_BUILD=0

for arg in "$@"; do
  case "$arg" in
    --system) DEST="/Applications" ;; # kept for backwards compat
    --user) DEST="$HOME/Applications" ;;
    --no-build) NO_BUILD=1 ;;
    --help|-h)
      sed -n '2,/^set /p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done

SRC="Build/Release/Build/Products/Release/QuickCull.app"

if [ "$NO_BUILD" -eq 0 ]; then
  echo "Building QuickCull (Release)…"
  EXTRA_FLAGS=""
  if [ -n "${DSH_SESSION_ID:-}" ]; then
    EXTRA_FLAGS=" -Xfrontend -disable-sandbox"
  fi
  xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Release \
    -derivedDataPath Build/Release \
    OTHER_SWIFT_FLAGS='$(inherited)'"${EXTRA_FLAGS}" build
else
  if [ ! -d "$SRC" ]; then
    echo "No built app at $SRC — run without --no-build first." >&2
    exit 1
  fi
fi

# Sanity check the build before copying
if [ ! -d "$SRC" ]; then
  echo "Build did not produce $SRC" >&2
  exit 1
fi
echo "Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$SRC" 2>&1 | tail -n 5

# Quit running instance so the copy isn't busy
echo "Quitting running QuickCull (if any)…"
osascript -e 'tell application "QuickCull" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
  pgrep -x QuickCull >/dev/null 2>&1 || break
  sleep 0.3
done
pkill -x QuickCull >/dev/null 2>&1 || true

mkdir -p "$DEST"

# rsync preserves signing; use trailing slash to copy app contents correctly.
# --delete ensures stale Frameworks are removed.
echo "Installing to $DEST/QuickCull.app …"
# Need admin for /Applications — try without sudo first, then with if needed
if [ "$DEST" = "/Applications" ] && [ ! -w "$DEST" ]; then
  echo "(Need admin to write to $DEST — will use sudo)"
  sudo rm -rf "$DEST/QuickCull.app"
  sudo rsync -a --delete "$SRC/" "$DEST/QuickCull.app/"
  # Ensure ownership stays useful
  sudo chown -R "$(id -un):staff" "$DEST/QuickCull.app" 2>/dev/null || true
else
  rm -rf "$DEST/QuickCull.app"
  # rsync is more reliable than cp -R for bundles
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$SRC/" "$DEST/QuickCull.app/"
  else
    cp -R "$SRC" "$DEST/"
  fi
fi

# Clear quarantine / provenance that Finder or curl may have left
echo "Clearing quarantine attributes…"
xattr -cr "$DEST/QuickCull.app" 2>/dev/null || true

# Re-verify after copy
echo "Verifying installed copy…"
codesign --verify --deep --strict --verbose=2 "$DEST/QuickCull.app" 2>&1 | tail -n 5

# Register with Launch Services so it shows up in Spotlight / Open With
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/QuickCull.app" 2>/dev/null || true

echo ""
echo "Installed to $DEST/QuickCull.app"
echo "Size: $(du -sh "$DEST/QuickCull.app" | cut -f1)"
echo ""
echo "Run it like any Mac app:"
echo "  open \"$DEST/QuickCull.app\"     # or double-click in Finder"
echo ""
echo "First launch note (ad-hoc signed):"
echo "  Finder → Applications → right-click QuickCull → Open → Open"
echo "  After that it opens normally on double-click."
echo ""
read -p "Launch now? [Y/n] " ans
ans=${ans:-Y}
if [[ "$ans" =~ ^[Yy] ]]; then
  open "$DEST/QuickCull.app"
  echo "QuickCull is launching…"
fi
