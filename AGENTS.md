# AGENTS.md

## Build and test

`QuickCull.xcodeproj` is hand-maintained with synchronized file groups (`PBXFileSystemSynchronizedRootGroup`), so new
files under `QuickCull/`, `QuickCullCore/` and `QuickCullCoreTests/` join their
target automatically.

```bash
# Type-check / build the library and app
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build

xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Release \
  -derivedDataPath Build/Release build

# Full suite (302 tests at the time of writing, ~2 min)
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest

# One class
xcrun xctest -XCTest QuickCullCoreTests.SessionTests \
  /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest

Scripts/start.sh   # Release build + launch
```

## Type checking

`xcodebuild` is the only authoritative type check. Do not rely on the editor's
Swift language server for this repo: with no checked-in `compile_commands.json` or
`buildServer.json` it type-checks one file at a time and reports "Cannot find
type …" for every type declared in another file (`SessionFile`, `FlagColor`,
`CullAction`, `XCTest`, …). Those reports are noise on every multi-file change.
Confirm anything suspect with `xcodebuild` before touching code.

## Conventions

- No third-party dependencies. LibRaw 0.22.1 is downloaded and built by
  `Scripts/build-libraw.sh` into `Build/libraw/` (universal arm64 + x86_64); no
  LibRaw sources are checked in. `Scripts/gen-compile-db.sh` can emit an
  (ignored) `compile_commands.json`, but `xcodebuild` below stays authoritative.
- `QuickCullCore` holds all logic and is unit-tested; the app target holds
  SwiftUI/AppKit views only.
- Comments explain a non-obvious *why*. Do not narrate what the code does.

## Codebase navigation

File routing for this repo is in `docs/agents/codebase-map.md`. Read it before
the first broad search (`ls`, tree-wide `grep`/`glob`, or reading whole
directories): it names the file to open for each concern and where a new file
belongs.

Layout, so the first `ls` is unnecessary:

- `QuickCull/` app target: SwiftUI/AppKit views only.
- `QuickCullCore/` all logic and state, unit-tested by `QuickCullCoreTests/`.
- `QuickCullCoreTests/` XCTest suites mirroring the core dirs, plus
  `Support/` and `Fixtures/`.
- `Scripts/` build, install, fixture and benchmark scripts.
- `docs/` docs index; `docs/archive/` is history.

Entry points for a change:

- `QuickCull/QuickCullApp.swift` (`@main`, menu commands) and
  `QuickCull/RootView.swift` (phase switch).
- `QuickCullCore/App/AppState.swift`: phase machine, import pipeline,
  commit/move orchestration; start here for any cross-cutting behavior.
- `QuickCullCore/Session/Session.swift`: flags, filters, current index.
- `QuickCullCore/Decoding/RawDecoding.swift`: decoder protocol and error
  taxonomy.
- `QuickCullCore/Window/ImageWindow.swift`: preloaded image residency.

Do not read `Build/`, `docs/archive/`, `.superpowers/`, the raw fixture samples
or `QuickCull.xcodeproj/project.pbxproj`; the map's "Don't read" section says
why.

`docs/audits/2026-11-08-code-quality-audit-round3.md` is worth reading only
when you need the reason behind an invariant, not for current line numbers.
