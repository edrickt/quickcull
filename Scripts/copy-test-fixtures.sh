#!/usr/bin/env bash
# Installs QuickCullCoreTests/Fixtures into the test bundle with its folder
# structure intact. The synchronized-folder resource sync flattens subfolder
# structure, so fixture files would otherwise land directly in Resources/;
# remove those flat leftovers and install the structured Fixtures tree that
# tests look up via subdirectory: "Fixtures/raws".
set -euo pipefail
RES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
rm -rf "$RES/Fixtures"
for f in "$PROJECT_DIR"/QuickCullCoreTests/Fixtures/raws/*; do
  rm -f "$RES/$(basename "$f")"
done
ditto "$PROJECT_DIR/QuickCullCoreTests/Fixtures" "$RES/Fixtures"
