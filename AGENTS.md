# AGENTS.md

## Build and test

`QuickCull.xcodeproj` is hand-maintained with synchronized file groups, so new
files under `QuickCull/`, `QuickCullCore/` and `QuickCullCoreTests/` join their
target automatically.

```bash
# Type-check / build the library and app
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build

xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Release \
  -derivedDataPath Build/Release build

# Full suite (227 tests at the time of writing, ~80s)
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest

# One class
xcrun xctest -XCTest QuickCullCoreTests.SessionTests \
  /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest

./start.sh   # Release build + launch
```

## Type checking

`xcodebuild` is the only authoritative type check. The Swift language server is
disabled in `.pi-lens.json` on purpose: with no `compile_commands.json` or
`buildServer.json` it type-checks one file at a time and reports "Cannot find
type …" for every type declared in another file (`SessionFile`, `FlagColor`,
`CullAction`, `XCTest`, …). Those reports are noise on every multi-file change.
Confirm anything suspect with `xcodebuild` before touching code.

## Conventions

- No third-party dependencies. LibRaw is vendored under `Scripts/` and built by
  `Scripts/build-libraw.sh`.
- `QuickCullCore` holds all logic and is unit-tested; the app target holds
  SwiftUI/AppKit views only.
- Comments explain a non-obvious *why*. Do not narrate what the code does.
