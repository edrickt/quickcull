#!/usr/bin/env bash
# Generates compile_commands.json for QuickCullCore so a language server
# type-checks the module with real cross-file context. Without it every file is
# checked in isolation and every type declared in another file reads as
# "cannot find type" — which is what the editor's Swift diagnostics report on
# this project by default.
#
# Each entry is the frontend invocation sourcekit-lsp expects: one PRIMARY file
# plus the rest of the module as context. The driver's `-primary-file` spelling
# is rejected by this toolchain ("save unknown driver flag"), which is why this
# uses `swift-frontend` directly.
#
# Requires the LibRaw headers that Scripts/build-libraw.sh installs into
# Build/libraw/include. Restart the language server after generating, or it
# keeps using the workspace snapshot it loaded at startup.
#
# Usage: ./Scripts/gen-compile-db.sh   (writes ./compile_commands.json, git-ignored)
set -euo pipefail
cd "$(dirname "$0")/.."

INCLUDE="$PWD/Build/libraw/include"
if [ ! -f "$INCLUDE/libraw/libraw.h" ]; then
    echo "error: $INCLUDE/libraw/libraw.h missing — run Scripts/build-libraw.sh first" >&2
    exit 1
fi

SDK=$(xcrun --sdk macosx --show-sdk-path)
TARGET=$(uname -m)-apple-macos14.0
BRIDGING="$PWD/QuickCullCore/QuickCullCore-Bridging-Header.h"
FRONTEND=$(xcrun -f swift-frontend)
# @Observable and friends are macros: without the plugin path the frontend cannot
# load ObservationMacros and every @Observable file fails to type-check.
PLUGINS="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins"

SOURCES=()
while IFS= read -r file; do SOURCES+=("$PWD/$file"); done < <(find QuickCullCore -name '*.swift' | sort)

{
    printf '[\n'
    first=1
    for primary in "${SOURCES[@]}"; do
        [ $first -eq 1 ] || printf ',\n'
        first=0
        printf '  {"directory": "%s", "file": "%s", "arguments": ["%s", "-typecheck", "-sdk", "%s", "-target", "%s", "-module-name", "QuickCullCore", "-plugin-path", "%s", "-import-objc-header", "%s", "-I", "%s", "-primary-file", "%s"' \
            "$PWD" "$primary" "$FRONTEND" "$SDK" "$TARGET" "$PLUGINS" "$BRIDGING" "$INCLUDE" "$primary"
        for source in "${SOURCES[@]}"; do
            [ "$source" = "$primary" ] && continue
            printf ', "%s"' "$source"
        done
        printf ']}\n'
    done
    printf ']\n'
} > compile_commands.json

echo "wrote compile_commands.json: ${#SOURCES[@]} entries"
