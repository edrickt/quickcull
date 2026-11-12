# QuickCull codebase map

Verified against `b523424` (2026-11-12). Native macOS 14+ photo-culling app: SwiftUI/AppKit views in `QuickCull/`, all logic and tests in `QuickCullCore/`; no third-party deps except LibRaw, which is built. Start at `QuickCull/QuickCullApp.swift:48`; learn `AppState` (`QuickCullCore/App/AppState.swift:28`) first.

Maintenance: after adding, moving, or deleting a source file, update the File index and bump `Verified against` to the commit you checked.

## Orientation

- What it does: import photos, decode full-resolution previews in the background, scrub with the keyboard, flag red/yellow/green, then Trash or Move the flagged files. User manual: `README.md` ("How it works", "For developers").
- Entry point: `QuickCull/QuickCullApp.swift:48` (`@main`). `QuickCull/RootView.swift:8` switches on `appState.phase` (`empty` / `decoding` / `scrubbing`).
- Central abstraction: `AppState` (`QuickCullCore/App/AppState.swift:28`), `@MainActor @Observable`. Owns the phase machine, the import `Task`, commit/move orchestration, and three `ImageWindow`s (filmstrip, grid, viewer). Views read it via `@Environment(AppState.self)`.
- Session abstraction: `Session` (`QuickCullCore/Session/Session.swift:10`) holds in-memory flags, the filter projection `files`, and the current index. Flags are never persisted; New Session discards them and wipes the cache.
- Residency abstraction: `ImageWindow` (`QuickCullCore/Window/ImageWindow.swift:26`) holds decoded `CGImage`s around a position; `retarget(ids:)` re-maps it after a filter or index change without re-decoding.
- Generated/derived: `Build/` (LibRaw dylib and Xcode products, git-ignored) and a git-ignored compile_commands.json (emitted by `Scripts/gen-compile-db.sh` when wanted). `QuickCull.xcodeproj` is hand-maintained with synchronized groups, so new files under the three source roots join their target automatically.
- Domain/rationale docs: no CONTEXT.md, GLOSSARY.md or ADR dir. Read `docs/audits/2026-11-08-code-quality-audit-round3.md` only to learn why an invariant is shaped as it is; its line numbers are a snapshot.
- Docs index: `docs/README.md`.

## Layers

| Layer | Path | Owns | Read when |
| --- | --- | --- | --- |
| App shell (not unit-tested) | `QuickCull/` | SwiftUI/AppKit views, key/mouse monitors, zoom/loupe rendering | UI, layout, focus, mouse behavior |
| Orchestration | `QuickCullCore/App/` | phase machine, import pipeline, commit/move dialogs, window wiring | change spanning decode to commit |
| Session | `QuickCullCore/Session/` | flags, filter projection, current index, flag revision | flag, filter, scrub-order changes |
| Decode | `QuickCullCore/Decoding/`, `QuickCullCore/Engine/` | format routing, LibRaw/ImageIO decoders, parallel scheduling | decoder bugs, format support, import speed |
| Storage | `QuickCullCore/Storage/` | decoded-JPEG and histogram cache, cache keys, wipe | cache, disk, preview lookup |
| Residency | `QuickCullCore/Window/` | preload policy, image windows, hit-test, dropdown policy | preloading, memory, mouse hit-test |
| Metadata | `QuickCullCore/Metadata/` | EXIF parsing, RAW and rendered histograms | HUD values, histogram math |
| Rules and file actions | `QuickCullCore/Keys/`, `QuickCullCore/Commit/`, `QuickCullCore/Models/` | key map and routing, trash/move, file identity and format allowlist | key handling, trash/move, dedupe |

## Where things live

| Concern | Files |
| --- | --- |
| App entry, menu commands, quit-time cache wipe | `QuickCull/QuickCullApp.swift:48`, `QuickCull/RootView.swift` |
| Phase machine, import pipeline, early-open threshold (50 previews) | `QuickCullCore/App/AppState.swift:28`, `importFiles` `:225`, threshold `:54`, `:277` |
| Keyboard hotkeys (arrows, Z/X/C, Space loupe, Cmd+A) | `QuickCullCore/Keys/CullKeyMap.swift:14`, `QuickCullCore/Keys/KeyRouter.swift:22`, `QuickCull/KeyboardMonitor.swift:10` |
| Flag mutation, flag revision, flag colors | `QuickCullCore/Session/FlagColor.swift:3`, `QuickCull/FlagColor+UI.swift`, `QuickCullCore/Session/Session.swift:10` (`toggleFlag` `:168`) |
| Filter / visible sequence projection | `QuickCullCore/Session/CullFilter.swift:7`, `QuickCullCore/Session/Session.swift:119` |
| Badge rule (flagged and image loaded) | `QuickCullCore/Models/FlagBadgeLogic.swift:6`, `QuickCull/FlagBadge.swift`, `QuickCull/BadgedThumbnailView.swift:10` |
| Trash commit | `QuickCullCore/Commit/TrashCommit.swift:30`, `QuickCullCore/App/AppState.swift:628` |
| Move commit and collision rename | `QuickCullCore/Commit/MoveCommit.swift:24`, `QuickCullCore/App/AppState.swift:697` |
| Decoder protocol and error taxonomy | `QuickCullCore/Decoding/RawDecoding.swift:51` (`RawDecoding`), `:37` (`DecodeError`) |
| Format routing, supported extensions, both decoders | `QuickCullCore/Models/RawFileIdentity.swift:10`, `QuickCullCore/Decoding/ImageIODecoder.swift:9`, `:44` (`RoutingDecoder`), `QuickCullCore/Decoding/LibRawDecoder.swift:6`, `Scripts/build-libraw.sh` |
| Parallel decode and concurrency limit | `QuickCullCore/Engine/DecodeEngine.swift:34`, `QuickCullCore/Engine/DecodeLimiter.swift:14` |
| Decode cache (q75 JPEGs and histogram sidecar) | `QuickCullCore/Storage/ImageCacheStore.swift:9` |
| Preload window policy and image residency | `QuickCullCore/Window/WindowPolicy.swift:8`, `QuickCullCore/Window/ImageWindow.swift:26` |
| Main viewer: single/split display, zoom, 100% loupe | `QuickCull/ImageDisplayView.swift:7`, `QuickCull/ZoomableImageView.swift:11` (`LoupeView` `:388`) |
| Scrub screen: control bar, commit/move dialogs | `QuickCull/ScrubView.swift:5` (`controlBar` `:170`) |
| Grid, filmstrip, batch flagging | `QuickCull/GridView.swift:8`, `QuickCull/FilmstripView.swift:18`, `QuickCullCore/App/AppState.swift:586` (select all) |
| Metadata HUD and histograms | `QuickCullCore/Metadata/ImageMetadataProvider.swift:21`, `QuickCullCore/Metadata/RawHistogram.swift:7`, `QuickCull/MetadataHUDView.swift:5`, `QuickCull/HistogramViews.swift:49` |
| Custom dropdowns and click-through policy | `QuickCull/DropdownMenu.swift:14`, `QuickCullCore/Window/DropdownClickPolicy.swift:13` |
| Screen/view coordinate hit-testing | `QuickCullCore/Window/WindowHitTest.swift:16` |
| Import failures and unsupported-format banner | `QuickCullCore/App/ImportFailureSummary.swift:11`, `QuickCull/ImportFailuresBanner.swift:8` |
| Build, install, fixture scripts | `Scripts/README.md`, `Scripts/build-libraw.sh`, `Scripts/fetch-fixtures.sh`, `Scripts/copy-test-fixtures.sh` |

## Task recipes

**Add a culling key action.** Read `QuickCullCore/Keys/CullKeyMap.swift:14` (keyCode/character map, layout-aware), `QuickCullCore/Keys/KeyRouter.swift:22` (modifier/sheet/text-field passthrough), `QuickCull/KeyboardMonitor.swift:10` (installs monitors). Change `CullAction` and the map, then dispatch it in `AppState.handle` (`QuickCullCore/App/AppState.swift:463`). Test with the Keys suites.

**Add a supported camera/raw format.** Read `QuickCullCore/Models/RawFileIdentity.swift:10` (extension allowlist and `DecoderKind`), `QuickCullCore/Decoding/ImageIODecoder.swift:44` (`RoutingDecoder`). Change the extension sets; add a fixture only if a decoder test must cover it. Test with the Decoding suites.

**Change preload or memory behavior.** Read `QuickCullCore/Window/WindowPolicy.swift:8` (pure index math), `QuickCullCore/Window/ImageWindow.swift:26` (loaders, reduced tier, `retarget` `:336`), then `AppState.installWindows` at `QuickCullCore/App/AppState.swift:430` and `syncWindows` `:594`. Test with the Window suites.

**Change the cache key, format or lifecycle.** Read `QuickCullCore/Storage/ImageCacheStore.swift:9`, callers in `QuickCullCore/Engine/DecodeEngine.swift:109`. Test with the Storage suite; the cache is wiped on launch and quit, so no migration is needed.

**Change Trash or Move semantics.** Read `QuickCullCore/Commit/TrashCommit.swift:30`, `QuickCullCore/Commit/MoveCommit.swift:24` (directory identity, collision rename), callers `AppState.confirmCommit` at `QuickCullCore/App/AppState.swift:628` and `confirmMove` `:697`. Add a regression test in `QuickCullCoreTests/Commit/`. Test with the Commit suites.

**Add a Metadata HUD field.** Read `QuickCullCore/Metadata/ImageMetadataProvider.swift:21` (EXIF parsing), `QuickCull/MetadataHUDView.swift:5` (rows and layout), `QuickCullCore/Storage/ImageCacheStore.swift:188` (cached histogram). Test with the Metadata suite; HUD layout itself has no unit test.

**Add a decode error or change failure wording.** Read `QuickCullCore/Decoding/RawDecoding.swift:37` (`DecodeError` taxonomy), `QuickCullCore/App/ImportFailureSummary.swift:11`, `QuickCull/ImportFailuresBanner.swift:8`. Test with `ImportFailureSummaryTests` and the Engine suites.

## Tests

All suites are XCTest in `QuickCullCoreTests/`, mirroring the `QuickCullCore/` directory names. None needs a GUI, a running app or a permission grant; the whole target is headless. The `xcodebuild` / `xcrun xctest` invocations live in `AGENTS.md`; pick one class with the `-XCTest` filter `QuickCullCoreTests.<Class>` (class name from the file).

- `QuickCullCoreTests/App/` covers `QuickCullCore/App/` (phase, import pipeline, early view, commit/move dialogs, loupe, tricolor). Nine classes; `QuickCullCoreTests/App/AppStateTests.swift` is the biggest.
- `QuickCullCoreTests/Commit/` covers trash/move outcomes including collision and failure paths.
- `QuickCullCoreTests/Concurrency/` covers `AsyncTimeout` deadline and single-resume behavior.
- `QuickCullCoreTests/Decoding/` covers ImageIO, LibRaw and `RoutingDecoder`; needs `QuickCullCoreTests/Fixtures/raws/`.
- `QuickCullCoreTests/Engine/` covers decode scheduling, progress ordering and `DecodeLimiter`; slower, it decodes real fixtures.
- `QuickCullCoreTests/Keys/` covers the key map, routing, and Space-loupe consumption.
- `QuickCullCoreTests/Metadata/` covers EXIF parsing, name joining and histogram math.
- `QuickCullCoreTests/Models/` covers file identity, format support and the badge rule.
- `QuickCullCoreTests/Scripts/` is `ScriptsContractTests`, which asserts script behavior and content. Edit scripts deliberately.
- `QuickCullCoreTests/Session/` covers flags, filter projection, revision counter and tricolor invariants.
- `QuickCullCoreTests/Storage/` covers cache keying, wipe, JSON sidecars and preview deletion; disk-heavy.
- `QuickCullCoreTests/Window/` covers window policy, `ImageWindow` residency/retarget, hit-test and dropdown policy; `QuickCullCoreTests/Window/ImageWindowTests.swift` is the largest. No suite needs a GUI or a grant; the full suite is about 2 minutes per `AGENTS.md`.
- `QuickCullCoreTests/Support/` holds `QuickCullCoreTests/Support/TestDoubles.swift` (`StubDecoder`, fake trasher/mover) and `QuickCullCoreTests/Support/TestFixtures.swift` (temp dirs, made-up `CGImage`s).

Fixtures: 11 pinned raw samples in `QuickCullCoreTests/Fixtures/raws/` are tracked in git; `Scripts/fetch-fixtures.sh` restores them. `Scripts/copy-test-fixtures.sh` is a build phase that installs the tree into the test bundle with its subdirectory intact (synchronized groups flatten resources).

## Don't read

- `Build/` - git-ignored LibRaw dylib and Xcode products (hundreds of MB).
- `docs/archive/` - executed plans, specs and past audits; history only.
- `docs/assets/` - PNG screenshots and icon options for the README.
- `QuickCullCoreTests/Fixtures/raws/` - binary raw files; use the tests, not the bytes.
- `.superpowers/` - git-ignored agent scratch (SDD state), not repo content.
- `QuickCull.xcodeproj/project.pbxproj` - hand-maintained and large; let the synchronized groups and Xcode edit it, never by hand.
- `Assets/AppIcon.icon` - Icon Composer package whose glyph comes from `Scripts/make-icon.swift`; touch only for an icon change.
- `README.md` - user manual; for code work read only "How it works" and "For developers".

## Gotchas

- `xcodebuild` is the only authoritative type check. The editor's Swift language server reports cross-file "Cannot find type" noise; see `AGENTS.md`.
- The Xcode project uses `PBXFileSystemSynchronizedRootGroup`: a new file under `QuickCull/`, `QuickCullCore/` or `QuickCullCoreTests/` joins its target automatically. Do not add file references by hand.
- `docs/audits/2026-11-08-code-quality-audit-round3.md` is a snapshot at baseline `bdbcb97` (it says 272 tests; the tree has 296). Treat its states, counts and line anchors as historical.
- Flags live only in memory. There is no flags file, no undo log and no persistence layer to change.
- Cache identity comes from `RawFileIdentity.fileID`, which resolves symlinks. A duplicate photo or a stale preview is usually an identity or cache-key bug, not a decode bug.
- `Scripts/verify-control-bar.swift` and `Scripts/verify-dropdown.swift` mirror the app UI by hand and are not built by Xcode; update them when `ScrubView` or `DropdownMenu` changes.
- `docs/superpowers/` is tracked in git (two README-rewrite docs); it is not generated.
- The test bundle needs the copied Fixtures tree, which the build phase writes. Running a stale `.xctest` directly can miss fixture-dependent tests.

## File index

`QuickCullCore/App/`

- `QuickCullCore/App/AppState.swift` - phase machine, import pipeline, commit/move orchestration, window wiring.
- `QuickCullCore/App/ImportFailureSummary.swift` - failure-banner sentence, unsupported-format message.

`QuickCullCore/Commit/`

- `QuickCullCore/Commit/MoveCommit.swift` - move files to a folder with collision rename and directory-identity check.
- `QuickCullCore/Commit/TrashCommit.swift` - per-file trash outcomes; never throws.

`QuickCullCore/Concurrency/`

- `QuickCullCore/Concurrency/AsyncTimeout.swift` - deadline around an unabortable async operation (cache wipe).

`QuickCullCore/Decoding/`

- `QuickCullCore/Decoding/ImageIODecoder.swift` - ImageIO decode with EXIF orientation baked in; `RoutingDecoder` chooses a pipeline.
- `QuickCullCore/Decoding/LibRawDecoder.swift` - LibRaw C API full-resolution demosaic; stateless and thread-safe.
- `QuickCullCore/Decoding/RawDecoding.swift` - `RawDecoding` protocol, `DecodeOptions`, `RawBitmap`, `DecodeError`.

`QuickCullCore/Engine/`

- `QuickCullCore/Engine/DecodeEngine.swift` - parallel import decode emitting an `AsyncStream` of per-file events.
- `QuickCullCore/Engine/DecodeLimiter.swift` - suspendable FIFO concurrency slots that do not park threads.

`QuickCullCore/Keys/`

- `QuickCullCore/Keys/CullKeyMap.swift` - keyCode and character to `CullAction` mapping.
- `QuickCullCore/Keys/KeyRouter.swift` - passthrough rules for modifiers, sheets, text fields; loupe Space.

`QuickCullCore/Metadata/`

- `QuickCullCore/Metadata/ImageMetadataProvider.swift` - EXIF camera, lens, exposure and date parsing.
- `QuickCullCore/Metadata/RawHistogram.swift` - linear raw and rendered histogram model, accessors, `DisplayHistogram`.

`QuickCullCore/Models/`

- `QuickCullCore/Models/FlagBadgeLogic.swift` - single badge-visibility rule.
- `QuickCullCore/Models/RawFileIdentity.swift` - format allowlist, `DecoderKind`, stable file identity.
- `QuickCullCore/Models/SessionFile.swift` - one session file (URL plus identity id).

`QuickCullCore/Session/`

- `QuickCullCore/Session/CullFilter.swift` - option-set filter over flags and keepers.
- `QuickCullCore/Session/FlagColor.swift` - red/yellow/green, key letter.
- `QuickCullCore/Session/Session.swift` - flags, filter projection, current index, flag revision.

`QuickCullCore/Storage/`

- `QuickCullCore/Storage/ImageCacheStore.swift` - decoded-JPEG and histogram cache: keys, load, delete, wipe.

`QuickCullCore/Window/`

- `QuickCullCore/Window/DropdownClickPolicy.swift` - classify outside clicks for custom dropdown panels.
- `QuickCullCore/Window/ImageWindow.swift` - observable async image residency and retargeting.
- `QuickCullCore/Window/WindowHitTest.swift` - screen to window coordinate conversion for hit-testing.
- `QuickCullCore/Window/WindowPolicy.swift` - pure preload window index math.

`QuickCull/`

- `QuickCull/BadgedThumbnailView.swift` - thumbnail with badge on the image, never on the placeholder.
- `QuickCull/DecodingView.swift` - pre-scrub decoding progress screen.
- `QuickCull/DropdownMenu.swift` - custom pull-down panel with click-through dismissal.
- `QuickCull/EmptyStateView.swift` - importer screen and failures banner.
- `QuickCull/FilmstripView.swift` - bottom strip with revision-keyed cells and auto-scroll.
- `QuickCull/FlagBadge.swift` - flag badge and corner triangle.
- `QuickCull/FlagColor+UI.swift` - `FlagColor` to SwiftUI color and name.
- `QuickCull/GridView.swift` - all-thumbnail grid with selection and batch flagging.
- `QuickCull/HistogramViews.swift` - RGB and luminance histogram canvases.
- `QuickCull/ImageDisplayView.swift` - single and split viewer, HUD toggle.
- `QuickCull/ImportFailuresBanner.swift` - dismissible decode-failure banner.
- `QuickCull/KeyboardMonitor.swift` - app-wide keyDown monitor for culling and Space loupe.
- `QuickCull/MetadataHUDView.swift` - metadata sidebar and histogram stat rows.
- `QuickCull/QuickCullApp.swift` - `@main` App, menu commands, quit-time cache wipe.
- `QuickCull/RootView.swift` - phase to root view switch.
- `QuickCull/ScrubView.swift` - main culling screen, control bar, dialogs.
- `QuickCull/ZoomableImageView.swift` - pan/zoom container and 100% loupe lens.
