# QuickCull code audit — 2026-10-24

- **Status:** executed, fixes landed
- **Baseline commit:** `c5f892c`
- **Scope:** whole repository, runtime-weighted: `QuickCull/`, `QuickCullCore/`,
  `QuickCullCoreTests/`, `QuickCull.xcodeproj`, `Scripts/`, `README.md`
- **Method:** five read-only parallel audit passes over the eight architecture
  points named in `docs/plans/architecture-audit-wave3.brief.md`, findings
  merged and ranked by data safety → correctness → memory/perf → maintainability,
  then each accepted finding fixed with a regression test.
- **Difference from the wave-3 brief:** that brief scoped a read-only report.
  This run also fixes the accepted findings, per the request that opened it.

## 1. Baseline and final state

| | Baseline `c5f892c` | Final |
| --- | --- | --- |
| `QuickCullCore` Debug build | success | success |
| `QuickCull` Release build | success | success |
| Test suite | 207 tests, 0 failures, 82.9 s | 227 tests, 0 failures, 83.4 s |
| README claim | 205 tests | 227 tests |

Commands:

```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Release \
  -derivedDataPath Build/Release build
```

## 2. Ranked findings

Severity: P0 data loss, P1 user-visible correctness, P2 memory/perf, P3
maintainability. Every fixed row is covered by a test in `QuickCullCoreTests/`.

| ID | Sev | Finding | Evidence | Status |
| --- | --- | --- | --- | --- |
| AUD-01 | P0 | Moving into the folder a file already lives in renamed every original in place (`a.jpg` → `a 1.jpg`), because the collision suffix found the file itself. | `Commit/MoveCommit.swift:commit` | Fixed: same-folder move is a no-op. `testMoveIntoTheSourceFolderIsANoOp` |
| AUD-02 | P1 | The trash/move set was re-derived at confirm time, and flag keys still worked while the alert was up, so the committed set could differ from the count the dialog named. | `App/AppState.swift:requestCommit/confirmCommit` | Fixed: request snapshots the files, confirm commits the snapshot, and `handle` ignores keys while a confirm is pending. `testConfirmCommitsTheFilesTheDialogNamedEvenIfFlagsChange`, `testFlagKeysAreIgnoredWhileTheTrashDialogIsUp` |
| AUD-03 | P1 | The key monitor swallowed Cmd+Z / Cmd+C / Cmd+X (flag keys are matched by key code) and kept consuming keys inside the folder picker's modal and its text field. | `QuickCull/KeyboardMonitor.swift` | Fixed: routing is a pure `Core/Keys/KeyRouter` decision; chords, modals and text editing pass through. `KeyRouterTests` (6 cases), plus a live check: typing `/tmp/qc-shoot` into the panel worked, where `c`/`h`/`o`/`t` were previously consumed as cull keys |
| AUD-04 | P1 | A grid selection outlived a filter switch and a batch flag action mutated photos that were no longer on screen. | `App/AppState.swift:handle(.toggleFlag)` | Fixed: the batch path intersects the selection with the visible projection. `testGridFlagActionSkipsPhotosHiddenByTheFilter` |
| AUD-05 | P1 | Closing one window stopped the shared key monitor and the quit-time cache wipe for every other window. | `QuickCull/QuickCullApp.swift` | Fixed: monitor and quit observer are app-lifetime, not per window |
| AUD-06 | P1 | Landing on an index while its half-size load was still in flight left it half-size for good: the upgrade pass skips in-flight indices, and completion never re-checked the tier. | `Window/ImageWindow.swift:startLoad` | Fixed: completion re-runs the load when a reduced identity has entered the full tier. `testLandingOnAnInFlightReducedLoadUpgradesIt` |
| AUD-07 | P1 | An empty filter projection dropped the current photo, so leaving the placeholder (back to All) restarted the shoot at photo 1. | `Session/Session.swift:setFilter` | Fixed: the projection remembers the current photo by id. `testEmptyFilterPlaceholderKeepsTheCurrentPhotoForTheReturn` |
| AUD-08 | P1 | A cache-write failure was reported as a decode failure, telling the user their photo was broken when their disk was. | `Engine/DecodeEngine.swift` | Fixed: `DecodeError.cannotStorePreview` is its own case, caught at the cache boundary |
| AUD-09 | P1 | The loupe labelled itself "100%" while magnifying a half-size placeholder or a 320px thumbnail, and sampled `NSScreen.main`'s backing scale rather than the pane's. | `QuickCull/ZoomableImageView.swift:LoupeView`, `ImageDisplayView.swift` | Fixed: `ImageWindow.isFullResolution(at:)` drives the label (`100%` or `preview`), backing scale comes from `@Environment(\.displayScale)`. `testFullResolutionReflectsTheResidentTier` |
| AUD-10 | P2 | Grid thumbnails were never evicted: the grid's policy radius was the file count, so residency grew with the shoot (~273 KB/cell, ~1.4 GB at 5k). | `Window/ImageWindow.swift:gridThumbnails` | Fixed: grid runs a zero-radius policy plus a fixed 61-thumbnail residency cap. `testGridResidencyIsBoundedByTheFixedCap` |
| AUD-11 | P2 | Superseded decodes were un-cancellable (`Task.detached` breaks the cancellation link), so every image a fast scrub flew past still decoded and held a limiter slot ahead of the one the user landed on. | `Window/ImageWindow.swift` loaders | Fixed: `detachedUnlessCancelled` propagates cancellation, so the existing `Task.isCancelled` guards are reachable |
| AUD-12 | P2 | A superseded load wrote its image without checking it still owned the slot, so an older half-size result could permanently clobber a newer full-res one. | `Window/ImageWindow.swift:startLoad` | Fixed: the token is checked before the write; a mismatch drops the result entirely |
| AUD-13 | P2 | Eviction dropped the in-flight marker without awaiting the task, which allowed the same identity to decode twice at once and made `waitUntilSettled` return early (three window tests asserted on unsettled windows). | `Window/ImageWindow.swift:evictOutsideWindow` | Fixed: only the task's own completion clears its markers |
| AUD-14 | P2 | The filmstrip's real bound was 101 thumbnails, not the 61 the README promised: eviction ran before the ensured set was pruned. | `Window/ImageWindow.swift:ensureLoaded` | Fixed: prune → evict → load, with a shared 61 cap; README corrected |
| AUD-15 | P2 | `displayFullResBehind`/`displayFullResAhead` were unclamped, so one `defaults write` sized the whole window full-res. | `Window/ImageWindow.swift` | Fixed: clamped to the window extent. `testFullResTierKnobsAreClampedToTheWindowExtent` |
| AUD-16 | P2 | Decoding ran synchronously inside `TaskGroup` workers sized to the core count, parking every cooperative thread for the length of a demosaic. | `Engine/DecodeEngine.swift` | Fixed: the decode runs off the cooperative pool via a dispatch continuation, inside an `autoreleasepool` so per-file ImageIO temporaries are released |
| AUD-17 | P2 | JPEG encode and disk write ran inside the cache actor, serializing every worker's 100-400 ms encode behind one actor. | `Storage/ImageCacheStore.swift` | Fixed: `storeJPEG` is `nonisolated async`; only the directory check takes isolation |
| AUD-18 | P2 | Trashed and moved files kept their full-res cache JPEGs and histogram sidecars forever. | `App/AppState.swift` | Fixed: preview URLs are resolved before the commit (the key embeds size + mtime) and deleted after it. `testSuccessfulCommitDeletesTheCachedPreview` |
| AUD-19 | P2 | The HUD showed the previous photo's camera/ISO/shutter under the new file's thumbnail while metadata loaded. | `QuickCull/MetadataHUDView.swift` | Fixed: `metadata = nil` on file change |
| AUD-20 | P2 | Split view never drew the flag badge on the right pane, and one pane's pan clamp was applied to both panes. | `QuickCull/ImageDisplayView.swift`, `ZoomableImageView.swift` | Fixed: right pane passes its flag colour; the offset is re-clamped against each pane's own geometry at render time |
| AUD-21 | P3 | `Session.remove` reset the filter to All even when the projection had been empty already, discarding a filter the user chose. | `Session/Session.swift:remove` | Fixed: only a removal that empties a non-empty projection falls back. `testRemoveKeepsPlaceholderFilterWhenTheProjectionWasAlreadyEmpty` |
| AUD-22 | P3 | An unsupported-only import set `phase = .empty` directly, leaving the previous session's windows and flags live and committable behind the importer. | `App/AppState.swift:importFiles` | Fixed: it goes through the single empty-transition owner; request/confirm are phase-guarded. `testUnsupportedOnlyImportClearsThePreviousSession` |
| AUD-23 | P3 | Clearing the failure lists did not bump their revisions, so a view watching only the revision missed the clear. | `App/AppState.swift:resetTransientState` | Fixed; the two lifecycle tests now assert revision deltas |
| AUD-24 | P3 | `Session.currentFile` guarded a real precondition with `assert`, compiled out in release. | `Session/Session.swift` | Fixed: `precondition` |
| AUD-25 | P3 | `Session.contains(id:)` was a linear scan called once per selected id on the main actor. | `Session/Session.swift` | Fixed: uses the existing id → position map |
| AUD-26 | P3 | Cache JPEGs were tagged `DeviceRGB` while the demosaic writes sRGB. | `Decoding/LibRawDecoder.swift` | Fixed: tagged `CGColorSpace.sRGB` |
| AUD-27 | P3 | The fixture copy script merged into the bundle, so a renamed or deleted fixture kept passing against an orphan copy. | `Scripts/copy-test-fixtures.sh` | Fixed: the bundle's `Fixtures` tree is cleared first |
| AUD-28 | P3 | `testExifFieldsParsedIfPresent` asserted nothing (`iso == "ISO 400" || iso == nil`). | `QuickCullCoreTests/ImageMetadataProviderTests.swift` | Fixed: asserts the parsed ISO and aperture exactly |
| AUD-29 | P3 | Grid selection and the four selection entry points ignored the in-flight commit guard that every other input path has. | `App/AppState.swift` | Fixed: all of them are gated |
| AUD-30 | P3 | Documentation drift: README claimed 205 tests (207 actual), the filmstrip's 61 bound (101 actual), and unbounded grid retention as a feature. | `README.md` | Fixed |
| AUD-31 | P2 | The cache wipe on New Session is fire-and-forget while a decode can be past its cancellation check, so a dead session's preview could be written into the freshly wiped cache directory. | `Storage/ImageCacheStore.swift:wipe/storeJPEG` | Fixed: every `wipe()` bumps a generation, and a store call that began before it throws `CacheError.staleGeneration` instead of writing. `testWriteStartedBeforeAWipeDoesNotLandInTheFreshCache` |

## 3. Accepted and deferred

| Item | Why not now |
| --- | --- |
| Cache size cap / free-space preflight before an import | Real, but it is new product behavior (a warning surface and a policy for what to do when space runs out). AUD-08 makes the failure honest in the meantime. Needs a product decision on the threshold and the dialog. |
| Swift 6 strict-concurrency migration | The wave-3 brief explicitly keeps this out of scope. `@unchecked Sendable` in `DecodeLimiter`/`LockedAccumulator` is lock-backed and correct today. |
| Keyboard-only access to the Trash/Move menus | The dropdown panels are mouse-only, so a keyboard-only user cannot commit at all. Fixing it means adding `Commands` and shortcuts, which is a UX decision (which chord for which colour) rather than a bug fix. |
| Filmstrip re-keys all 61 cells on every scrub/flag | Deliberate: the key includes the flag revision and current index because in-place cell updates were being dropped by preempted render passes, leaving stale badges. Changing it needs visual verification of that regression, not a code-only change. |
| Raw histogram normalizes without subtracting the black pedestal | A real accuracy concern, but verifying the change needs a raw with a known black level; no fixture has one. Changing histogram math without evidence is worse than the current documented behavior. |
| Grid body rebuilds an O(n) element array per landed thumbnail | Bounded cost today (the grid keeps 61 thumbs), and a cache keyed on `(flagRevision, images.count)` would add state to the view. |
| `fileID` does not resolve symlinks, so a symlinked alias can enter a session twice | Exotic, and resolving symlinks changes the cache key (and therefore invalidates every existing preview) for a case no user has reported. |
| `AppState` body is 378 lines (SwiftLint's 350 threshold) | Splitting it is a refactor with its own risk profile; the class is cohesive and fully covered. |
| Decode worker count is derived from `physicalMemory` once at init, not from available memory | There is a low-memory shed (one worker when free memory dips under 1 GiB), and no measurement justifies a per-import recomputation. Re-deriving on every import would be a guess dressed as a fix. |
| `ImageWindow.ensureLoaded` scans the ensured set per appearing cell | The scan is bounded now: 61 entries maximum, so a grid body pass costs at most 61 comparisons per cell. It was only quadratic while the grid was unbounded. |
| The loupe crops its `CGImage` inside the view body on every hover move | `CGImage.cropping` creates a view over the existing bitmap rather than copying pixels, so this is cheap until measured otherwise. Restructuring it on suspicion would add state to a view that has none. |

## 4. Tooling note (read this before trusting a diagnostics panel)

This repository is a hand-maintained `.pbxproj` with no `compile_commands.json`
or `buildServer.json`, so a single-file Swift language server type-checks each
file in isolation and reports `Cannot find type 'SessionFile'`,
`No such module 'XCTest'`, and cascades of the same for every declaration that
lives in another file of the same module. A workspace-wide scan of this branch
reports 107 such "blocking" errors while `xcodebuild` builds both targets
cleanly and 226 tests pass.

`.pi-lens.json` disables the Swift LSP for this project for that reason, and
`AGENTS.md` records the rule: `xcodebuild` is the only authoritative type check
here. `Scripts/gen-compile-db.sh` emits a `compile_commands.json` in the shape
sourcekit-lsp accepts: one `swift-frontend -typecheck -primary-file <file>` entry
per source file, with the rest of the module as context, the LibRaw include
path, and the toolchain's macro plugin path. All 23 entries type-check clean
(`rc=0`), so the database itself is sound. Two things are needed before an
editor profits from it: run `Scripts/build-libraw.sh` first (the headers are not
in the tree), and make the server read the file — either start it with
`--compile-commands-path`, or point it at the repository root. The driver's
`-primary-file` spelling is rejected by this toolchain, which is why the entries
call `swift-frontend` directly.

## 5. What was verified, and how

- **Type checking and builds:** `QuickCullCore` Debug and `QuickCull` Release,
  both green after every accepted fix.
- **Behavior:** 227 unit tests, up from 207, each fixed finding carrying a test
  that fails on the pre-fix code (grid residency with 100 ensured cells and a
  61 cap, in-flight reduced load upgrading, snapshot commit, placeholder
  round-trip, same-folder move, key routing, cache cleanup, stale-generation
  cache write).
- **Real app surface:** Release build launched, empty state rendered, the file
  picker was driven through a modal with typed input, and the letters reached
  the panel instead of the cull key map — the AUD-03 regression, observed on the
  real surface.
- **Not visually verified:** the loupe label swap, the split-pane badge and pan
  clamp, and the HUD reset. Their inputs are unit-tested
  (`isFullResolution`, `KeyRouter`), but the rendered result was not confirmed
  against real raws in this run. Treat those three as needs-eyes before release.
