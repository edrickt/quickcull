#!/usr/bin/env bash
# Builds libraw.dylib (universal arm64 + x86_64) into Build/libraw/.
set -euo pipefail

VERSION="0.22.1"
SHA256="e676248284075605aa2697a66eeed7dc258820bd1d4988c724d29edffd726726"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Build/libraw"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Idempotent: the Xcode build phase runs this script on every build, so the
# pinned VERSION is checked here rather than by the phase. Without the marker a
# version bump would silently keep the previous dylib (the phase used to skip
# the script whenever the file existed).
MARKER="$DEST/.version"
if [ -f "$DEST/libraw.dylib" ] && [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$VERSION" ]; then
    exit 0
fi

echo "Downloading LibRaw ${VERSION}…"
curl -fsSL -o "$WORK/libraw.tar.gz" "https://github.com/LibRaw/LibRaw/archive/refs/tags/${VERSION}.tar.gz"
echo "$SHA256  $WORK/libraw.tar.gz" | shasum -a 256 -c -
tar xzf "$WORK/libraw.tar.gz" -C "$WORK"
SRC="$WORK/LibRaw-${VERSION}"

SOURCES=$(find "$SRC/src" -name '*.cpp' ! -name '*_ph.cpp' | sort | tr '\n' ' ')
SDK=$(xcrun --sdk macosx --show-sdk-path)

mkdir -p "$DEST/include"
clang++ -std=c++11 -O2 -fPIC -DLIBRAW_NODLL -DNO_JPEG -DNO_JASPER -DNO_LCMS \
  -I "$SRC" -I "$SRC/src" \
  -shared -arch arm64 -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=14.0 \
  -Wl,-install_name,@rpath/libraw.dylib \
  $SOURCES -o "$DEST/libraw.dylib"

cp -R "$SRC/libraw" "$DEST/include/"
printf '%s\n' "$VERSION" > "$MARKER"
echo "Built $DEST/libraw.dylib"
lipo -info "$DEST/libraw.dylib"
