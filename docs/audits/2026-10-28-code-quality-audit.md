# QuickCull code-quality audit — 2026-10-28

- **Status:** executed, fixes landed in the working tree (uncommitted)
- **Baseline commit:** `a356d91` (v1.0.0 release docs)
- **Scope:** the major features at runtime weight — import/commit, the culling
  session model, decode scheduling, decoders/cache/metadata/histogram, the
  residency windows, the viewer surfaces, and the app shell/input layer
- **Method:** six read-only audit passes over disjoint feature lanes, run as
  fresh-context reviewer subagents (no session history), findings merged and
  every claim re-verified against the code by the parent, then each accepted
  finding fixed with a regression test whose failure was checked against the
  pre-fix code. Requirements were read from `README.md` and
  `docs/superpowers/specs/`; where those are silent, the standard was what a
  reasonable user of this app would expect.
- **Not re-reported:** the 31 findings of `docs/audits/2026-10-24-code-audit.md`
  and its "Accepted and deferred" table are treated as closed. This run audits
  the tree those fixes produced.

## 1. Baseline and final state

| | Baseline `a356d91` | Final (working tree) |
| --- | --- | --- |
| `QuickCullCore` Debug build | success | success |
| `QuickCull` Release build | success | success |
| Test suite | 227 tests, 0 failures, 88.1 s | 262 tests, 0 failures, 112.4 s |
| README claim | 227 tests | 262 tests |

Commands:

```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Release \
  -derivedDataPath Build/Release build
```

Each new regression test was checked against a deliberately reverted copy of its
fix — `QA-01`, `QA-02`, `QA-04` (by construction), `QA-05`, `QA-06`, `QA-07`
(the cap-truncation contract), `QA-08` (flag key and scrub key) and `QA-34` were
all observed red on the old code and green on the new. A final `build-for-testing`
plus `xcrun xctest` reported 262 tests, 0 failures, and both `QuickCullCore` Debug
and `QuickCull` Release build clean with no new warnings.

## 2. Ranked findings

Severity: P0 data loss or wrong files acted on; P1 user-visible correctness;
P2 memory/perf/honesty; P3 maintainability, tests, docs.

| ID | Sev | Finding | Evidence | Status |
| --- | --- | --- | --- | --- |
| QA-01 | P0 | The pending Trash/Move dialog's target was app-wide mutable state that a second window could overwrite: window A's "Move 2 red files to Trash?" could commit window B's green set. `AppState` is one instance shared by the `WindowGroup`, and `requestCommit`/`requestMove` did not test the pending slot. | `App/AppState.swift:request*/confirm*`, `QuickCull/ScrubView.swift` | Fixed: the slot is exclusive, both request methods return whether they took it, the alert only appears then, and the menus disable on pending counts in every window. `testASecondRequestCannotReplaceThePendingSet` |
| QA-02 | P1 | Committing from an empty-filter placeholder dropped the whole session. `session.isEmpty` is the *projection*; a commit made while the filter matched nothing leaves it empty with files remaining, and both commit paths read that as "session finished". | `App/AppState.swift:confirmCommit/confirmMove`, `Session/Session.swift:isEmpty` | Fixed: both paths use `totalCount == 0`. `testCommittingFromAnEmptyPlaceholderKeepsTheSession`, `testMovingFromAnEmptyPlaceholderKeepsTheSession` |
| QA-03 | P1 | The only failure surface said "could not be decoded" for a full disk and for unsupported formats — the misdiagnosis AUD-08 fixed inside the engine died at the banner, which ignored `DecodeOutcome.error` entirely. | `QuickCull/ImportFailuresBanner.swift`, `Decoding/RawDecoding.swift:cannotStorePreview` | Fixed: `ImportFailureSummary` (core) groups the failures into unsupported / could not be decoded / could not be cached (check free disk space), and the banner renders it. `ImportFailureSummaryTests` (7 cases) |
| QA-04 | P0 | The same-folder move guard compared path *spelling*. `standardizedFileURL` resolves neither symlinks nor case, so a source imported through an alias and a destination picked in its target folder missed the guard and fell into `autoRenamedDestination`, which found the file itself and renamed every original in place — AUD-01 reopened through a path shape the fix did not cover. | `Commit/MoveCommit.swift:commit` | Fixed: same folder is decided by directory identity (device + inode after resolving symlinks), with exact spelling as the cheap first test. `testMoveIntoTheSourceFolderThroughASymlinkIsANoOp`, `testMoveIntoTheSourceFolderWithAnotherSpellingIsANoOp` |
| QA-05 | P1 | The loupe claimed `100%` over a half-size placeholder for the length of the upgrade decode: `degradedIDs` was cleared when the load was *queued*, while the resident bitmap stayed reduced (AUD-09's failure, now transient). | `Window/ImageWindow.swift:startLoad` | Fixed: the tier flag changes with the bitmap store. `testLoupeDoesNotClaimSourcePixelsWhileTheUpgradeIsInFlight` |
| QA-06 | P1 | A filmstrip cell the user scrolled to beyond ±30 could never load: the ensured-set budget is `cap - window`, the strip's cap equalled its window, so the budget was 0 and `ensureLoaded` was silently dropped — permanent grey cells. | `Window/ImageWindow.swift:pruneEnsuredIndices`, `FilmstripView.swift` | Fixed: the strip keeps its 61-slot preload window plus 20 slots of scroll slack (cap 81). `testStripLoadsACellScrolledBeyondItsPolicyWindow` |
| QA-07 | P1 | The grid evicted visible tiles on any window showing more than 60 of them (a maximized 1920×1080 window shows ~77), and the cell's task had already run, so the tile stayed blank until it was scrolled out and back. | `Window/ImageWindow.swift:gridThumbnails/pruneEnsuredIndices`, `GridView.swift` | Fixed: the grid reports its viewport (`setViewport(ids:)`, identity-keyed) and residency is exactly that viewport plus the policy window — bounded by a screen, not a count. `testGridViewportKeepsEveryVisibleTileAndEvictsTheRest`, `testSetViewportIsNotTruncatedByTheResidentCap` |
| QA-08 | P1 | In grid, `Z`/`X`/`C` with no selection flagged the photo scrub left off — unmarked and possibly off-screen — and a later `Trash R` removed it. Scrub keys likewise moved that invisible index, so Single reopened on a different photo. | `App/AppState.swift:handle` | Fixed: grid flag keys without a selection are a no-op, and scrub keys do nothing in grid. `testGridFlagKeyWithNoSelectionIsIgnored`, `testGridScrubKeysDoNotMoveTheInvisibleCurrentIndex` |
| QA-09 | P1 | A monochrome raw (`filters == 0`, LibRaw's "no CFA") had every photosite read as channel 0 by the 2×2 LUT, drawing a 100% red histogram that reads as a sensor defect. | `Decoding/LibRawDecoder.swift:rawHistogram` | Fixed: the Bayer path bails out for `filters == 0` and `idata.colors < 3` and falls back to the rendered histogram. No fixture is monochrome, so this is a guarded defensive branch rather than a test (see §3) |
| QA-10 | P2 | `storeHistogram` re-derived the cache key (a second `stat` at a later instant) and ignored the wipe generation, so a sidecar could split from its JPEG or land in a freshly wiped cache after AUD-31 rejected its JPEG. | `Storage/ImageCacheStore.swift:storeHistogram` | Fixed: it takes the JPEG URL and honours the generation. `testHistogramBegunBeforeAWipeDoesNotLand` |
| QA-11 | P2 | Two concurrent stores of the same identity shared one `.tmp` path: the second truncated the first's encode and the loser failed with a misleading "could not be decoded". | `Storage/ImageCacheStore.swift:storeJPEG` | Fixed: unique temp names, plus `moveIntoPlace` falls back to replace when another store won the create race. `testConcurrentStoresOfTheSameFileAllSucceed` |
| QA-12 | P2 | The HUD camera row repeated the make (`Canon Canon EOS 30D`) and kept PENTAX's padding (`PENTAX              PENTAX K-01`); the lens row kept padding too. | `Metadata/ImageMetadataProvider.swift:metadata` | Fixed: values are trimmed and a model that starts with the make is not prefixed. `testCameraNameDoesNotRepeatTheMakeOrKeepPadding`, `testRawFixtureExposesCameraAndExposure` |
| QA-13 | P1 | `NSApp.modalWindow` covers the folder picker's `runModal` but not SwiftUI's `.fileImporter` sheet, so the import panel's arrows scrubbed the session behind it and Space never reached Quick Look. | `QuickCull/KeyboardMonitor.swift`, `Keys/KeyRouter.swift` | Fixed: a sheet counts as system-owned, in both key paths. `testSheetKeysReachThePanel`. The live keystroke repro (Open panel → ↓ → Space) was not run (no GUI session); the fix is safe either way because the scrub window is never a sheet |
| QA-14 | P2 | The quit-time cache wipe never ran: `willTerminate` is posted on the way to `exit()`, and the async wipe it scheduled had no run loop left, so every normal quit kept the whole cache until the next launch's wipe. | `QuickCull/QuickCullApp.swift` | Fixed: `applicationShouldTerminate` returns `.terminateLater`, awaits the wipe, then replies. Launch wipe stays authoritative for force-quits |
| QA-15 | P2 | The dropdown's mouse monitor classified every app-window click against rects measured in *its own* window, so a second window could lose a press to `.consume` and the first window's panel stayed open. | `QuickCull/DropdownMenu.swift` | Fixed: the host window is captured at open and other windows' clicks close the panel and pass through |
| QA-16 | P2 | First-run copy said "Select raw files" and "Choose RAW Files…" although JPEG/PNG/HEIC are headline features; a JPEG shooter could conclude their files are unsupported and never press the button. | `QuickCull/EmptyStateView.swift` | Fixed: "Select photos to start culling." / "Choose Files…", with the format list in the caption |
| QA-17 | P3 | Documentation drift: README promised a filter bar with visible live counts (`R (n)`) that the shipped dots do not show and did not describe the multi-select combinations; it claimed "adaptive 160 to 200pt thumbnails" while cells are a fixed 160; its memory figure was the cold-start state, not the post-scrub peak (~1.7 GB at 20 MP, ~3.6 GB at 45 MP). | `README.md` | Fixed: counts described where they actually are, combination rule documented, 160pt cells, strip 81 / grid viewport bounds, both memory numbers, and the quit-wipe claim now true |
| QA-18 | P2 | Flag keys matched ANSI *positions*, not printed letters: on AZERTY the key labelled `Z` did nothing while the key labelled `W` flagged red, contradicting the README and the legend. | `Session/FlagColor.swift`, `Keys/CullKeyMap.swift`, `Keys/KeyRouter.swift` | Fixed: the printed (ASCII) letter wins for flag keys, a non-flag ASCII letter passes through instead of falling back to the position, a non-Latin input source keeps the position fallback, arrows still use key codes, and Cmd+A is select-all by letter as well. `testFlagKeysFollowThePrintedLetterNotTheKeyPosition`, `testNonLatinInputSourceStillFlagsByPosition`, `testSelectAllFollowsTheLetterOnOtherLayouts`, `testArrowKeysStillRouteByKeyCode` |
| QA-19 | P3 | `os_signpost("file=%s", file.id)` passed a Swift `String` to a C-string format: garbage ids in Instruments and a read past the object while profiling. | `Engine/DecodeEngine.swift` | Fixed: `%{public}@` |
| QA-20 | P3 | Decode outcomes were emitted in completion order, so the failure banner named the same files in a different order on every run of the same import. | `Engine/DecodeEngine.swift:decodeAll` | Fixed: outcomes are sorted into import order. `testOutcomesAreReportedInImportOrder` |
| QA-21 | P3 | `Session.init` trapped on duplicate identities (`Dictionary(uniqueKeysWithValues:)`), and `Session` is public. | `Session/Session.swift:init` | Fixed: duplicates are dropped in one pass. `testDuplicateFileIdentitiesAreDropped` |
| QA-22 | P3 | `toggleFlag`'s doc claimed a flip "always" drops the photo out of the sequence; with combinable filters it can stay visible, so the comment invited a "fix" of correct index math. | `Session/Session.swift:toggleFlag` | Fixed: comment describes the real rule |
| QA-23 | P3 | `WindowPolicy.loadOrder` did not clamp `current` although `window(around:)` does, so the two halves of the same policy disagreed about an out-of-range input. | `Window/WindowPolicy.swift` | Fixed + `testLoadOrderClampsAnOutOfRangeCurrent` |
| QA-24 | P3 | The `upgradePolicy` parameter returned "outside the full tier" — the opposite of what the name reads — inviting an inverted call site. | `Window/ImageWindow.swift` | Renamed to `isOutsideFullTier` with the predicate stated in the doc |
| QA-25 | P3 | Hit-test/policy tests missed the edges the (correct) code handles: negative-origin window frames, zero-size panes, zero-size panel before the first layout report, and the 8pt split gap. | `WindowHitTestTests`, `DropdownClickPolicyTests` | Fixed: 4 cases added |
| QA-26 | P2 | A rendered histogram (X-Trans, Fovea, or a missing sidecar) was indistinguishable in-app from a true RAW histogram, so sRGB pixel clipping read as sensor clipping. | `MetadataHUDView.swift`, `HistogramViews.swift` | Fixed: `RawHistogram.isRendered` drives a "Rendered ·" stat-row prefix and honest accessibility labels |
| QA-27 | P3 | The histogram suite could not detect the two most likely regressions: R and B have identical *counts* on a Bayer sensor, and every rendered-histogram test used a grey image, so a channel swap was invisible; `sensorMax` was only asserted `> 255`, so the 16383 fallback on a 12-bit body passed. | `LibRawDecoderTests`, `RawHistogramTests` | Fixed: `testSensorMaxIsTheCamerasOwnBitDepth` pins 4095 for two 12-bit fixtures and 16383 for the 14-bit one; `testDisplayHistogramKeepsRedInTheRedChannel` puts a pure-red image in `bins[0]` |
| QA-28 | P3 | Two cache tests could not fail as named (the "mtime" test also changed the size; the "quality" test only checked that a file existed), and a LibRaw test named "zero copy" asserted nothing about copies. | `ImageCacheStoreTests`, `LibRawDecoderTests` | Fixed: mtime-only change, encoded sizes compared across q0.70/q0.95 and the clamp, and the LibRaw test renamed to what it verifies |
| QA-29 | P3 | The metadata path for raws was untested (every metadata test wrote a JPEG), so a regression that blanked camera/lens/ISO for every raw would pass. | `ImageMetadataProviderTests` | Fixed: `testRawFixtureExposesCameraAndExposure` reads the CR2 fixture through ImageIO |
| QA-30 | P3 | `RawBitmap.histogram`'s doc said "rendered sRGB histogram (nil only if decode failed)" — it is linear Bayer data and legitimately nil for X-Trans/Fovea/monochrome. | `Decoding/RawDecoding.swift` | Fixed |
| QA-31 | P2 | A long import could not be aborted: `DecodingView` had no cancel, and New Session is disabled during decoding, so the only exit was quitting the app. | `QuickCull/DecodingView.swift`, `App/AppState.swift` | Fixed: `AppState.cancelImport()` + a Cancel Import button. `testCancelImportReturnsToTheImporterAndStaysThere` |
| QA-32 | P3 | Two tests claimed more than they asserted: one ended with `requestCommit()` and a comment that the commit guard was "not testable here"; the move test's name said `...AndHandle...` but never called `handle`. | `AppStateTests`, `AppStateMoveTests` | Fixed: both assert the guard with a gated trasher (`viewMode` and `currentIndex` unchanged) |
| QA-33 | P3 | The filmstrip was not scrolled to the current photo when it was rebuilt (Grid → Single), so the highlighted cell was off-screen. | `QuickCull/FilmstripView.swift` | Fixed: a post-layout `scrollTo` on appearance |
| QA-34 | P3 | Shift-click ranges could only grow: `selectRange` unioned, so anchoring 0 → 10 → 5 left 6–10 selected (Finder replaces). | `App/AppState.swift:selectRange` | Fixed. `testShiftRangeShrinksWhenTheTargetMovesBack` |
| QA-35 | P2 | The flag badge was drawn on the scaled image frame, so at 2x its corner was outside the clipped viewport (and, after the grid moved to filled tiles, a portrait tile put its badge outside the clipped cell): the only flag indicator vanished exactly while inspecting detail. | `QuickCull/ZoomableImageView.swift`, `BadgedThumbnailView.swift` | Fixed: the viewer pins it to the pane's corner and the thumbnail pins the layout to the tile before overlaying the badge |
| QA-36 | P3 | Grid tiles were `scaledToFit` in a fixed 160×108 window while the spec asked for uniform filled tiles, so a portrait shoot left ragged cells. | `QuickCull/BadgedThumbnailView.swift`, `GridView.swift` | Fixed: the grid fills, the strip still fits whole frames |
| QA-37 | P2 | The grid, filmstrip and filter segments were mouse-only to VoiceOver: no button trait, no action, no selected state. | `GridView.swift`, `FilmstripView.swift`, `ScrubView.swift` | Fixed: button trait + default action (select) + named "Open in Single" action for cells, selected traits for cells and filter segments |
| QA-38 | P3 | `HistogramStatRow` stored a `histogram` it never read; its call sites passed it. | `QuickCull/MetadataHUDView.swift` | Fixed |
| QA-39 | P3 | Three `FlagBadgeLogic` tests restated `shouldShow(isFlagged: true, hasImage: false)` with local constants and claimed to cover the grid/filmstrip/viewer call sites; none called a view, and deleting the type would have left them green. | `FlagBadgeLogicTests` | Fixed: the duplicates are gone and a comment records why |
| QA-40 | P3 | Entering grid opens at the first photo with no mark for where the user was; there is no scroll-to-current. | `QuickCull/GridView.swift` | **Deferred** — see §3 |

## 3. Accepted and deferred

| Item | Why not now |
| --- | --- |
| Grid opens at the shoot's first photo, with no scroll-to-current and no marker (QA-40) | The safe half landed: grid flag and scrub keys no longer act on an unmarked photo. Whether entering grid should jump to the current photo, mark it, or open at the top is a product/UX decision, and a scroll-position change needs visual verification on a running build that this pass could not give it. |
| Display/thumbnail decode limiters still park cooperative-pool threads (`DecodeLimiter.withSlot` runs its body on a `Task.detached` executor) | Same class as AUD-16, but a measured-symptom-free one: the bodies are 100–400 ms JPEG decodes at a limit of 3 + 4 threads. Moving them off the pool needs a dispatch hop that preserves `Task.isCancelled` (the current bodies use it to skip superseded decodes), which is a concurrency change, not a line move. Report-only. |
| Monochrome-raw guard (QA-09) has no test | The fixture set has no mono DNG, and synthesizing a CFA-less raw needs LibRaw internals. The guard is a defensive branch; the rendered-histogram fallback it selects is already covered. |
| Live repro of the sheet key fix (QA-13) | No GUI session in this pass. The change only widens the existing "the system owns these keys" condition, and the scrub window is never a sheet. |
| `DecodeEngine.benchmarks()` accumulator is never cleared and has no caller | Diagnostic weight (one 56-byte record per file per import), superseded by the signpost interval. Left as-is rather than deleting a measurement hook the import-speed work may still want. |
| Prior audit's deferred rows (cache size cap / free-space preflight, Swift 6 strict concurrency, keyboard-only commit menus, filmstrip re-keying, raw-histogram black pedestal, `fileID` not resolving symlinks) | Still open by the same reasoning recorded in `2026-10-24-code-audit.decisions.tsv`. QA-04 now protects the move path against the symlink identity gap regardless. |

## 3.1 Review of the fix set

A seventh fresh-context reviewer audited the working-tree diff. It confirmed all
18 fix groups are implemented and found two real defects in the fix set itself,
both fixed before this report was written:

- The grid's filled tiles anchored the badge to the aspect-fill image frame, which
  is larger than the tile for a portrait or panoramic photo, so the badge was
  clipped away. The image layout is now pinned to the tile before the overlay.
- The character-first key rule used Unicode alphanumerics, which disabled Z/X/C
  entirely on a Cyrillic/Greek/Hebrew input source. It is now ASCII-only, so a
  non-Latin layout keeps the position fallback.

It also found: New Session could dismiss a pending Trash/Move alert without
clearing the app-wide slot (the guard now includes the pending counts), the
request methods emitted unused-result warnings (~20 test call sites) and could
leave the slot half-set when nothing was flagged, the grid's viewport set
invalidated its body on every cell appear (now a reference box), one dead
constant, and a twice-computed banner string.

## 4. Notes for the next pass

- The two window caps and the grid viewport are now different mechanisms on
  purpose: the strip preloads a fixed window plus scroll slack, the grid is
  bounded by what is on screen. Any future surface that scrolls lazily should
  report its viewport through `setViewport(ids:)` rather than call
  `ensureLoaded` per cell, or it will inherit QA-06/QA-07.
- `AppState`'s pending-dialog slot is app-wide by design. Any new destructive
  flow must take it through `request*` (which returns `false` when the slot is
  taken) and include the pending counts in its disabled state.
- `KeyRouter` now has three inputs it did not have: the printed character, the
  sheet flag, and the chorded-Space rule. Any new key must decide what it does
  on a non-QWERTY layout.
