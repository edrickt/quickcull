#!/usr/bin/env bash
# Generates compile_commands.json for QuickCullCore so sourcekit-lsp type-checks
# the module with real cross-file context. Without it every file is checked in
# isolation and every type declared in another file reads as "cannot find type".
#
# One entry per Core source file, each naming the whole module, because that is
# what SwiftPM emits and what SourceKit expects. Requires the LibRaw headers
# that Scripts/build-libraw.sh installs into Build/libraw/include.
#
# Usage: ./Scripts/gen-compile-db.sh   (writes ./compile_commands.json, ignored by git)
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

SOURCES=()
while IFS= read -r file; do SOURCES+=("$PWD/$file"); done < <(find QuickCullCore -name '*.swift' | sort)

{
    printf '[\n'
    first=1
    for file in "${SOURCES[@]}"; do
        [ $first -eq 1 ] || printf ',\n'
        first=0
        printf '  {"directory": "%s", "file": "%s", "arguments": ["/usr/bin/swiftc", "-typecheck", "-sdk", "%s", "-target", "%s", "-module-name", "QuickCullCore", "-import-objc-header", "%s", "-I", "%s"' \
            "$PWD" "$file" "$SDK" "$TARGET" "$BRIDGING" "$INCLUDE"
        for source in "${SOURCES[@]}"; do printf ', "%s"' "$source"; done
        printf ']}\n'
    done
    printf ']\n'
} > compile_commands.json

echo "wrote compile_commands.json: ${#SOURCES[@]} entries"
