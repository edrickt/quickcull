# quickcull — code-quality and security audit (2026-11-24)

> **Status: report only.** No file in this repository was modified. Every finding carries a
> proposed fix for review; no regression test was added and no version file was touched.
> Gates at audit: `build-for-testing` success, 302 tests pass, 0 failures.


**Two passes.** This report is the first of two. The first pass (QC-01 … QC-03) read every
source file once; the adversarial second pass appended at the end of this document
(QS-01 … QS-04, plus a correction to QC-02 and to three first-pass clean bills) went deep on
the task/cancellation and session-mutation lanes, the thinnest part of the first pass. Read
both: **7 findings total — 0 Critical, 1 High, 4 Medium, 2 Low.**

## Baseline

- **Commit:** `5e30dfa` ("chore: bump to 1.0.5 (build 7)"), branch `main`, working tree clean. Preceding code commits: `7b765f7` (untrack retarget-dropped loads), `f09473a` (round-4 fixes).
- **Host:** macOS 26.0.1, Apple silicon, Xcode 26.3 / Swift 6.2.4. Repo is not a git-ignored build; `Build/` and `dist/` were not read.
- **`build-for-testing` (Debug, `-scheme QuickCullCore`):** success — `** TEST BUILD SUCCEEDED **`, exit 0.
- **Full suite:** `xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest` → **302 tests, 0 failures, 100.3 s**, exit 0. Matches `AGENTS.md` / `README.md`; nothing skipped in this run (the RAW-fixture suites found their fixtures).
- **LOC in scope:** 12,828 lines in the audited file set — 3,605 `QuickCullCore/`, 2,328 `QuickCull/`, 5,567 `QuickCullCoreTests/`, 1,328 `Scripts/` (Swift, sh, C bridging header).

## Scope and method

Read in full: `AGENTS.md`, `docs/agents/codebase-map.md` (its "Don't read" set was honoured: no `Build/`, `docs/archive/`, `docs/assets/`, fixture bytes, or `project.pbxproj` beyond targeted setting greps), `README.md`, `docs/README.md`, `Scripts/README.md`, and the round-3 and round-4 audit reports.

Then every source file in the audited set: all 17 `QuickCull/` views/adapters, all 26 `QuickCullCore/` files (AppState, Session, ImageWindow + policy, ImageCacheStore, DecodeEngine/Limiter, both decoders + the C interop, metadata/histogram, commit, keys, models, AsyncTimeout), all 11 scripts, and the test tree at file level plus the suites nearest the suspected defects (`AppStateLoupeTests`, `AppStateEarlyViewTests`, `ImageWindowTests`, `ImageCacheStoreTests`, `SessionTests`, `ScriptsContractTests`, `Support/TestDoubles.swift`).

Verification was read-only plus three throwaway probes compiled against the Debug `QuickCullCore.framework` under `/tmp/code-audit/probes/` (`probe_cache_key.swift`, `probe_upgrade_spin.swift`, `probe_eject.swift`); no repo file was created, edited, or deleted. The Release app in `Build/Release/` was inspected with `codesign` only.

Deliberately skipped, and why:
- Live GUI checks (real key events, loupe/zoom rendering, dropdown click-through, resize) — no GUI session in this pass; the pure rules behind them are unit-tested and were read.
- Performance benchmarking on real 45 MP RAWs — no card, and `Scripts/bench-decode.sh` mixes synthetic numbers into its CSV (see "Needs runtime verification").
- `docs/archive/`, `.superpowers/`, `compile_commands.json`, fixture bytes — per the codebase map.
- Sandbox-enabling experiment (would require a signed build and a card) — filed as a decision, not as a claim.

## Findings

### QC-01 — The cache key changes when the source file disappears, so every preview not already resident becomes unreachable

- **Severity:** Medium
- **Confidence:** High
- **Class:** correctness
- **Location:** `QuickCullCore/Storage/ImageCacheStore.swift:66`, `QuickCullCore/Storage/ImageCacheStore.swift:68`, `QuickCullCore/Window/ImageWindow.swift:500`, `QuickCullCore/Window/ImageWindow.swift:552`, `QuickCullCore/Window/ImageWindow.swift:566`
- **Code:**
```swift
// ImageCacheStore.swift:66
public nonisolated func cacheURL(for file: SessionFile) throws -> URL {
    var key = file.id
    if let attrs = try? FileManager.default.attributesOfItem(atPath: file.url.path) {
        let size = (attrs[.size] as? UInt64) ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        key = "\(file.id)|\(size)|\(Int(mtime * 1_000_000))"
    }
    let digest = SHA256.hash(data: Data(key.utf8))
```
```swift
// ImageWindow.swift:552 (full-res display loader; the thumbnail loader at :500 and
// the reduced loader at :566 do the same)
guard let file = byID[id] else { return nil }
guard let url = try? cache.cacheURL(for: file) else { return nil }
...
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }   // :559
```
- **Defect:** the key is `id|size|mtime`, but when the source cannot be stat-ed the same function silently falls back to `id` alone. Every write happens while the file exists (`DecodeEngine.decodeOne` → `storeJPEG`), so the JPEG lands under the three-field key. Every *read* recomputes the key at load time, so the moment the source is gone — card ejected, file moved/renamed in Finder, file removed by another app, volume unmounted — the read keys on `id` only and can never find the JPEG that is still sitting in `~/Library/Application Support/QuickCull/cache`. Trigger: open a session, let the display window fill, eject the card (or drag one file out of the folder in Finder), then scrub to any photo outside the residency window (or switch filter, or open the grid). Same for `MetadataHUDView`'s `cache.cacheURL` (`QuickCull/ScrubView` → `MetadataHUDView.swift:62`) and for `AppState.resolvedPreviewURLs` at commit time (`AppState.swift:774`): after an eject, the commit deletes nothing because it resolves the wrong path.
- **Impact:** after a card leaves the reader, every photo whose preview is not in memory shows the viewer's spinner and a blank filmstrip/grid tile for the rest of the session, even though all previews are on disk; the HUD silently falls back to the displayed thumbnail's dimensions ("320×213" for a 45 MP RAW) and re-labels the histogram as "Rendered ·". No data is lost and a new session recovers, but the documented card workflow ("read a photo card, cull, move on") is exactly the one that ejects.
- **Proposed fix:** resolve the preview URL once per session, while the file still exists, and stop recomputing it per read. `SessionFile`/`AppState` already carries the identity; add a `[String: URL]` built at import (`try? cache.cacheURL(for:)` under `importFiles`, before the decode starts) and hand it to the three `ImageWindow` factories, the HUD and `resolvedPreviewURLs` — `AppState.resolvedPreviewURLs` exists precisely because "the key embeds their size and mtime, so once they are gone it cannot be recomputed". Failing that, delete the stat fallback so a missing source is an honest cache miss instead of a second, unreachable key.
- **Evidence:** probe `/tmp/code-audit/probes/probe_cache_key.swift` — same file, same session, `cacheURL` before/after `removeItem`:
```
key while present : f4eaa046…fc8d.jpg
stored preview    : f4eaa046…fc8d.jpg
same as key?      : true
key after removal : 0fd25873…b607.jpg
same key?         : false
preview reachable : false
```
and `/tmp/code-audit/probes/probe_eject.swift`, which stores three previews, deletes only the source files, and then builds a display window over them:
```
mounted: image at 0 = true, at 2 = true
card ejected (source files removed); previews still on disk: 3
ejected: image at 0 = false, at 1 = false, at 2 = false
histogram sidecar reachable after eject: false
```

### QC-02 — A failed full-resolution upgrade retries forever: the app pegs a CPU core and the viewer freezes on the placeholder

- **Severity:** High
- **Confidence:** High
- **Class:** concurrency (correctness/performance)
- **Location:** `QuickCullCore/Window/ImageWindow.swift:186`, `QuickCullCore/Window/ImageWindow.swift:222`, `QuickCullCore/Window/ImageWindow.swift:559`
- **Code:**
```swift
// ImageWindow.swift:183 — completion of a load that produced no image
// Landing inside the full tier while a reduced placeholder was still
// in flight must upgrade now: the `setCurrent` pass that would have
// done it skipped this index because a load was in flight.
if let isOutsideFullTier = self.isOutsideFullTier,
   self.degradedIDs.contains(id),
   !isOutsideFullTier(position, self.currentIndex) {
    self.startLoad(position)
}
```
```swift
// ImageWindow.swift:222 — the same condition, re-armed by every setCurrent
if let isOutsideFullTier {
    for i in windowSet
    where isDegraded(i) && !isOutsideFullTier(i, currentIndex) && !isInFlight(i) {
        startLoad(i)
    }
}
```
- **Defect:** when a full-res load returns `nil` and is *not* cancelled, the reduced placeholder stays in `images[position]` and the identity stays in `degradedIDs`; line 186-190 then restarts the full-res load unconditionally, and so does the `setCurrent` upgrade pass. Nothing distinguishes "failed" from "not attempted yet", so the pair spins forever. Trigger (deterministic): a photo sits outside the full-res tier (−5…+10 of a 31-image extent), so its half-size placeholder is resident and `degradedIDs` holds it; the cache JPEG then disappears or fails to decode — `ImageWindow.swift:559` returns `nil` for a missing file, and `loadJPEGFullRes` returns `nil` for any unreadable JPEG — and the user scrubs onto the photo. Concrete ways to delete that JPEG under a running session: a second QuickCull instance (`prepareForLaunch` → `cache.wipe()` on every launch), `Scripts/bench-decode.sh:101` (`rm -rf "$HOME/Library/Application Support/QuickCull/cache"`), or any full-res decode returning `nil` under memory pressure.
- **Impact:** from that scrub on, the process burns 100 % of one core indefinitely (until quit), the loupe keeps labelling the frozen placeholder "preview", and any `waitUntilSettled`-based work never settles. Round 4 logged this as deferred with "not reachable with the ImageIO decoders in this tree"; the trigger above is reachable without changing the decoders, so the deferral no longer holds.
- **Proposed fix:** remember the failure per identity and only retry on a real event. In `startLoad`'s completion, replace the unconditional retry with `else { self.upgradeFailedIDs.insert(id) }` (a new set beside `degradedIDs`), and gate both the retry at :186 and the `setCurrent` pass at :224 (its `startLoad` is at :225) on `!upgradeFailedIDs.contains(id)`. Clear the mark in `refresh(id:)` (a decode just landed — a genuine reason to retry) and in `retarget(ids:)`.
- **Evidence:** probe `/tmp/code-audit/probes/probe_upgrade_spin.swift` — 22 files with real cached JPEGs, `setCurrent(0)` fills the extent (index 11 resident as a half-size placeholder), the preview for index 11 is deleted, then `setCurrent(11)`:
```
after settle: 0 full=true 11 resident=true 11 full=false
removed the preview for index 11
index 11 image after upgrade attempt: true full=false
cpu after 0.3s: 0.32s, +1s: 1.00s, +2s: 1.00s (idle process would add ~0)
waitUntilSettled(2s) returned after 2.00s
cpu while waiting 2s: 2.02s
```

### QC-03 — The documented release build ships unsandboxed, without hardened runtime, carrying `get-task-allow`, while it parses untrusted RAW in-process

- **Severity:** Medium
- **Confidence:** High
- **Class:** security
- **Location:** `QuickCull.xcodeproj/project.pbxproj:484`, `Scripts/install.sh:41`, `Scripts/install.sh:33`
- **Code:**
```
// project.pbxproj:484 (app target, Release; :463 is the same for Debug)
A10000000000000000000018 /* Release */ = {
    isa = XCBuildConfiguration;
    buildSettings = {
        ...
        ENABLE_HARDENED_RUNTIME = NO; /* ad-hoc local signing + library validation are incompatible; re-enable with Developer ID */
        GENERATE_INFOPLIST_FILE = YES;
```
```bash
# Scripts/install.sh:33 and :41-43
SRC="Build/Release/Build/Products/Release/QuickCull.app"
...
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Release \
  -derivedDataPath Build/Release \
  OTHER_SWIFT_FLAGS='$(inherited)'"${EXTRA_FLAGS}" build
```
- **Defect:** the shipped artifact is produced by `build` (not `archive`) with `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` left at its non-archive default, so the Release app is signed with `com.apple.security.get-task-allow`; there is no entitlements file anywhere in the repo, so no App Sandbox and no scope limit; and `ENABLE_HARDENED_RUNTIME = NO` in both configurations. Meanwhile the app's entire input is attacker-controlled files on removable media, parsed by LibRaw's C++ (`QuickCullCore/Decoding/LibRawDecoder.swift`), in-process, and it then trashes/moves files.
- **Impact:** (a) any process running as the same user can attach to the app and read/patch its memory — a shipped build should not be debuggable; (b) a memory-safety bug in LibRaw reached through a crafted RAW yields code execution with the user's full home-directory and card access instead of a sandbox-limited compromise; (c) without the hardened runtime the process also loses library validation and the other runtime hardening. None of this is a live exploit, but for a file-format parser it is the difference between "photo crashes the app" and "photo owns the account".
- **Proposed fix:** minimal and non-breaking — set `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` for the Release configuration (or pass it on the `install.sh` command line) so no `get-task-allow` is injected, and make the shipped artifact with `xcodebuild archive` + `-exportArchive`; add a release check (`codesign -d --entitlements -` must not list `get-task-allow`). Follow-ups to decide explicitly in `NOTICE`/README: an App Sandbox entitlements file (`com.apple.security.app-sandbox` + `com.apple.security.files.user-selected.read-write`) and `ENABLE_HARDENED_RUNTIME = YES` once the app carries a Developer ID. The sandbox needs a runtime pass first because `FileManager.trashItem` on a card-selected file needs write access to the parent directory, which the open-panel grant may not include.
- **Evidence:** read-only inspection of the Release product built by the documented path:
```
$ codesign -d --entitlements - Build/Release/Build/Products/Release/QuickCull.app
[Dict]
    [Key] com.apple.security.get-task-allow
    [Value]
        [Bool] true
$ codesign -dv Build/Release/Build/Products/Release/QuickCull.app
CodeDirectory v=20400 ... flags=0x2(adhoc) ... Signature=adhoc
```
`find . -name '*.entitlements'` outside `Build/` returns nothing, and `grep CODE_SIGN_INJECT_BASE_ENTITLEMENTS` over `project.pbxproj` and `Scripts/` returns nothing (so the default applies).

## Checked and clean

- **Session state machine** — `QuickCullCore/Session/Session.swift`: projection is always an order-preserving subsequence of `allFiles`; `remove` (`:247`) picks the first survivor at or after the pre-removal position (from the `originalPositions` snapshot); `toggleFlag`/`toggleFlags` clamp, preserve the current photo when it still matches, tie-break forward in `nearestMatchIndex`, and fall back to `.all` only where documented; `stashedCurrentID` is only read while the projection is empty, and every path that empties it writes it. Traced by hand for 1-file, last-file, empty-placeholder and deleted-last-image cases; `SessionTests`/`TricolorSessionTests` cover the same ground.
- **Import pipeline and early view** — `AppState.importFiles`: identity dedupe, lexicographic order, unsupported-only path, threshold arithmetic (`threshold < count`, so a 50-photo shoot waits), generation guard on every event, failure pruning inside the viewer, preview discard for a file trashed mid-decode, and the `.completed` paths for viewing/non-viewing. No stale-write hole found: every path that bumps `sessionGeneration` also clears the pending commit/move slot, so a discarded session cannot leave `isCommitting` stuck.
- **Commit/move safety** — `MoveCommit.isSameDirectory` compares device+inode (AUD-01 regression stays fixed), collision rename is bounded, `trashItem`/`moveItem` outcomes are per file, and `autoRenamedDestination` cannot escape the destination folder (a file's `lastPathComponent` cannot contain `/`).
- **Cache write path** — unique `.tmp-<UUID>` per store, atomic `moveItem` with `replaceItemAt` on a lost race, generation check before publish, sidecar keyed off the JPEG URL rather than re-derived, and no EXIF orientation tag written (`storeJPEG` + `testStoreJPEGWritesNoOrientationTag`).
- **C interop / untrusted bytes** — `LibRawDecoder.makeCGImage` validates `p.type`, `colors == 3`, `bits == 8` and `data_size == width*height*3` before building `CFData`; the flexible-array-member access (`withUnsafePointer(to: &processed.pointee.data)` + rebind) is the correct idiom for `unsigned char data[1]`, not a real bug. `rawHistogram` bounds-checks `left+w <= rawW`, `top+h <= rawH`, guards `filters != 0/1/9`, derives the channel from a 2×2 LUT masked to 0…3 (3→green), and divides by `maxLevel` only when non-zero. Grep for `try!`, `as!`, `fatalError`, `preconditionFailure` across `QuickCull/`+`QuickCullCore/`: none.
- **Metadata/histogram** — `ImageMetadataProvider` trims EXIF strings, de-duplicates make+model, and ranks dimensions cache-JPEG → file props → displayed image; `RawHistogram.init(from:)` rejects anything that is not 3×256 bins before a view can subscript it (`RawHistogram` decode is `try?`-swallowed into "no histogram").
- **Keys and loupe routing** — `KeyRouter.outcome` order (modal/sheet/text-field → select-all chord → modifier passthrough → printed letter → ANSI keyCode), and the Space contract (`canActivateLoupe` for key-down, "a live hold always consumes its key-up") are enforced in one place and mirrored by tests; `KeyboardMonitor` installs one monitor pair for the app's lifetime.
- **Window residency** — `WindowPolicy` window/loadOrder/toEvict are pure and clamped; `ImageWindow` bounds residency by policy ∪ ensured, keeps the grid viewport un-truncated (`setViewport` bypasses `pruneEnsuredIndices`, pinned by `testSetViewportIsNotTruncatedByTheResidentCap`), cancels tasks for identities that leave a projection, and cancels everything from `deinit`.
- **Identity on case-insensitive volumes** — probe 1 created `shots/aaa.cr2` and asked for `shots/AAA.CR2`: the file resolves, and `RawFileIdentity.fileID` returned the on-disk spelling for both (`…/shots/aaa.cr2`), because `resolvingSymlinksInPath()` canonicalises case. No duplicate-identity defect in that lane.
- **App target** — `ScrubView`'s per-window `onDisappear` cancel, `DropdownMenu`'s host-window guard + deferred monitor removal, `WindowHitTest`'s screen↔window conversion, and the loupe crop math (backing scale, `min(max(relX,0),1)`, clamp-before-`cropping`) are all consistent with the tests that pin them.
- **Scripts** — every expansion is quoted, all scripts use `set -euo pipefail`, fixtures are sha256-pinned before use, and `copy-test-fixtures.sh`'s `rm -rf "$RES/Fixtures"` cannot become `rm -rf /Fixtures` because `set -u` aborts first when `TARGET_BUILD_DIR` is unset.
- **Project settings** — `MACOSX_DEPLOYMENT_TARGET = 14.0` matches the README and the APIs used (no macOS 15 API without `#available`), Release is `-O` with `dwarf-with-dsym`, Debug is `-Onone` + `ENABLE_TESTABILITY`. The only setting problem found is QC-03.

## Prior-audit disposition

- Round 4 **QC4-01** (loupe hold outliving its context) — **FIXED**: `releaseLoupeHold()` at `AppState.swift:237-239`, invoked from the `pendingCommitCount`/`pendingMoveCount` didSets (`:63`, `:73`) and from `installWindows` on an empty projection (`:462`).
- Round 4 **QC4-02** (Space consumed without a rendered image) — **FIXED**: `canActivateLoupe` requires `displayImages.image(at:) ?? thumbWindow.image(at:)` (`AppState.swift:218-231`); `KeyRouter.consumesLoupeSpace` consumes a live hold's key-up (`KeyRouter.swift:81`); `KeyboardMonitor.swift:41-49` passes `isKeyUp`/`isLoupeActive`.
- Round 4 **QC4-03** (discarded window kept decoding) — **FIXED**: `ImageWindow.deinit` → `loadTasks.cancelAll()` (`ImageWindow.swift:441-442`, box at `:651`); `7b765f7` also untracks retarget-dropped identities (`:361`), closing the follow-up hole in the same fix.
- Round 4 **QC4-04** (unobservable test) — **FIXED**: the gated-failure test is present and the class passes in this run's full suite (302/0).
- Round 3 **QC3-01…QC3-05** — **FIXED**: `start.sh:12` is `cd "$(dirname "$0")/.."` (and `ScriptsContractTests` now enforces the shape), `AsyncTimeout` is the unstructured single-resume race with a clamped deadline, QC3-03's single predicate is in place, and README/AGENTS now say 302 (verified against this run).
- Round 4 deferred "`ImageWindow` full-res upgrade retries indefinitely" — **STILL PRESENT and now reachable** → filed as **QC-02**. The round-4 note that it is "not reachable with the ImageIO decoders in this tree" no longer holds: the loader returns `nil` for a missing cached JPEG (`ImageWindow.swift:559`), which any cache wipe under a running session produces.
- Round 4 deferred "wipe/store race leaves an orphan preview" — **STILL PRESENT**, unchanged and still bounded to orphan disk: `storeJPEG` snapshots the generation at store time (`ImageCacheStore.swift:93`), so a decode that finishes after a wipe writes into the fresh cache.
- Round 4 deferred "one-frame stale metadata in the HUD" — **STILL PRESENT**: `MetadataHUDView` is still constructed without `.id(file.id)` at `ImageDisplayView.swift:40/76/92/106`, so the first render after a file change shows the previous photo's rows.
- Round 4 deferred "filmstrip re-keys all cells", "no cache size cap", "no keyboard path to Trash/Move", "grid arrows do not scroll", "raw histogram black pedestal", "monochrome `filters == 0` guard untested", "`resolvedPreviewURLs` stats on the main actor" — **all STILL PRESENT**, unchanged and as described there.
- Round 4 deferred `verify-*.swift` drift — **STILL PRESENT**, and reproduced: `swift Scripts/verify-control-bar.swift` still dies in a SwiftUI symbol/JIT dump here, `grep Filter Scripts/verify-control-bar.swift` finds nothing (production `ScrubView.filterLabel` renders one), and `grep keyWindow Scripts/verify-dropdown.swift` finds nothing (production `DropdownMenu.installMonitor` guards on the host window). Carried, not re-filed.
- Codebase-map anchors — **ACCURATE** where spot-checked (`AppState.swift:28/253/305`, `confirmCommit:660`, `confirmMove:729`); `Verified against f09473a` is one commit behind HEAD (`7b765f7` touched `ImageWindow.swift` but only its comments and the retarget loop, which does not shift the cited anchors). No behavioural doc drift found: README's cache/threshold/orientation/wipe claims and the "302 tests" counts match the code and this run.

## Test-coverage gaps

- **Cache key stability when the source disappears** — `ImageCacheStoreTests` covers a changed mtime (`testCacheKeyChangesWhenMtimeChanges`) but nobody asked what happens when the file is gone, which is why QC-01 survived. Add `testCacheKeyIsStableWhenTheSourceDisappears`: create, store a JPEG, delete the source, assert `cacheURL` still resolves the stored file (it fails today by design, so the fix must make it pass) — or, if the path-only fallback is deliberate, assert that the loaders report a miss instead of a second key.
- **A failed full-res upgrade** — `ImageWindowTests` covers `testLandingOnAnInFlightReducedLoadUpgradesIt` and `testRefreshDuringAnInFlightMissRetriesAfterItSettles` but never a *failing* full load. Add `testAFailedFullResUpgradeDoesNotRetryForever`: reduced loader succeeds, full loader returns `nil`, `setCurrent` onto it, then assert the full loader was invoked at most twice and `waitUntilSettled(timeout: 1)` returns.
- **The windows' use of a resolved preview URL** — after the QC-01 fix, add an `AppStateEarlyViewTests`/`AppStateWindowRetargetTests` case that imports with `StubDecoder`, deletes the source files, scrubs past the residency window, and asserts an image still loads from cache.
- **App-target key boost** — `KeyboardMonitor.systemOwnsKeys` and `route` (sheets via `isSheet` *and* `attachedSheet`, `NSTextView` first responder, `NSApp.modalWindow`) are the only untested part of the key path; `KeyRouter` is tested but the AppKit predicate that feeds it is not. A small testable seam (a pure function over `(modal, sheets, firstResponderIsTextView)`) would let `ScriptsContractTests`-style unit tests cover it.
- **HUD lifetime/values** — nothing covers `MetadataHUDView`'s task cancellation guards or the `.id(file.id)` staleness now carried from round 4; a non-GUI test could exercise `ImageMetadataProvider.metadata` plus a `cacheJPEGURL` that does not exist (the QC-01 fallback), asserting the dimension precedence.
- **`bench-decode.sh` output honesty** — no test asserts that the CSV the script writes cannot contain synthetic rows when the script advertises a >10 % shipping gate. A `ScriptsContractTests` case asserting the synthetic fallback is off by default (or writes only to stderr) would pin it.

## Needs runtime verification

- **Real card + eject (QC-01):** import from a mounted volume, scrub until the display window is full, `diskutil unmount` the card (or eject it), then scrub past the residency window and open the grid. Expected today: spinner in the viewer and blank tiles while `ls ~/Library/Application\ Support/QuickCull/cache` still shows the `.jpg` files; the HUD's Dimensions row shows the thumbnail size. Steps settle QC-01's user-visible impact and the fix's acceptance criterion.
- **Two instances (QC-02):** with a session open and a photo resident as a half-size placeholder (scrub ~15 photos past it), run `open -na QuickCull` so the second launch wipes the shared cache, then scrub onto that photo. Expect a pegged core in Activity Monitor, the loupe stuck at "preview", and no recovery until quit. Also worth repeating after `Scripts/bench-decode.sh` wipes the live cache.
- **Memory pressure (QC-02, second trigger):** import ~100 45 MP RAWs on an 8 GB machine and scrub quickly; if any full-res decode returns `nil` while a reduced placeholder is resident, the loop starts without any file deletion.
- **Sandbox feasibility (QC-03):** build with `com.apple.security.app-sandbox` + `files.user-selected.read-write` and try Trash and Move on files selected from a card, plus the "New Session" cache wipe; `FileManager.trashItem` needs write access to the source's parent directory, which the open-panel grant may or may not include. This decides whether the sandbox is a one-line change or a design change.
- **Loupe 1:1 on a second display** with a different backing scale: the crop uses `@Environment(\.displayScale)`, which no test can observe; a human has to compare lens pixels against the original in Preview at 100 %.
- **The two `verify-*.swift` mirrors:** they abort here with a SwiftUI symbol/JIT dump, so whether the hand-copied control bar and dropdown still match the production layout is unknown until someone runs them in a GUI session with a matching toolchain.
- **Real-body EXIF** (subsecond, orientation, GPS-less bodies) through the HUD: `ImageMetadataProvider` parses to second resolution and ignores `SubsecTimeOriginal`; only a real shoot shows whether the Date row is good enough.
- **Cross-volume Move** (card → internal disk) end-to-end: `FileManager.moveItem` is expected to copy+delete, but only a real card shows the per-file outcomes, the progress affordance and the collision rename under a slow volume.

---

## Second pass — adversarial concurrency and lifecycle review (2026-11-24)

> Read-only. No repo file was created, edited or deleted (`git status` clean at the end of the pass).
> Probes live in `/tmp/code-audit/probes/pass2-quickcull/` and are compiled against the Debug
> `QuickCullCore.framework` built from HEAD (`/tmp/qc-dd`), so they run the HEAD sources.
> Baseline at HEAD `5e30dfa`: `xcrun xctest … QuickCullCoreTests.xctest` → see "Gates" at the end.
> QC-01..QC-03 are not repeated. Cap respected: 4 new findings.

Scope of this pass: every `Task`/`Task.detached`/`AsyncTimeout`/`loadTasks` site, the four
`ImageWindow` bookkeeping structures, the commit/move state machines, the cache write path, the
decoder C interop, and the app-target views that hold `CGImage`s. All 25 `QuickCullCore/` files and
all 17 `QuickCull/` files were read in full (the codebase map's "Don't read" set was honoured except
one targeted grep of `Build/libraw/include/libraw/libraw_types.h` for the `gamm` field type, which
decides whether `LibRawDecoder`'s `withMemoryRebound` is correct).

### Lanes cleared (no finding)

- **Task/cancellation lifecycle — no finding.** The four structures the brief names — `inFlightIDs`,
  `taskByID`, `loadTokens`, `loadTasks` — plus the two identity sets (`degradedIDs`,
  `refreshPendingIDs`) are only ever written in one place — the load's own completion — and they are
  cleared together, synchronously, under the token guard, before any state write:
  `QuickCullCore/Window/ImageWindow.swift:141-159`.
  That is what makes `cancel()` safe: it never has to touch the maps, because the task that owns the
  token still runs its epilogue. `retarget` drops an identity's task handle, load-box entry and
  token in one loop and intersects the identity sets (`ImageWindow.swift:359-366`), so a dropped
  identity cannot leave a stale marker; a surviving one keeps its token and its result is written
  through `positionsByID` (`:148`, `:161`), never a captured position. Verified with probe
  `probe_e_window`:
  ```
  W1 load for #10 in flight, calls=1
  W1 settled 0.01s; #10 resident=true (width 14); calls(#10)=1        # cancelled by eviction, re-wanted, landed once
  W2 after retarget: image(0).width=6 (expect 6), image(2).width=4 (expect 4)   # no wrong-slot write
  W3 settled 0.01s after 200 scrubs + 600 ensureLoaded (5s timeout); resident=53
  ```
  W3 is the leak test: 200 random `setCurrent` + 600 `ensureLoaded` never left an identity in
  `inFlightIDs` (a leak would have run the full 5 s timeout). Early returns at
  `ImageWindow.swift:155-159` and `:167-175` are all before a state write and all clear the flags
  they own.
- **Session/AppState mutation races — no finding beyond QS-02/QS-03.** Every destructive entry point
  re-checks the busy/pending state before mutating (`AppState.swift:496-498` `handle`, `:561-562`
  `setViewMode`, `:543-544` `setCurrentIndex`, `:553-555` `setFilter`, `:598-605` grid taps,
  `:729-731` `confirmMove`), the target set is snapshotted before the alert (`:645-658`,
  `:710-723`) so a flag key landing under the dialog cannot change what gets trashed
  (`testConfirmCommitsTheFilesTheDialogNamedEvenIfFlagsChange`), and `session.remove(succeeded)` runs
  only after the per-file outcomes come back (`:674-681`, `:737-751`). A double-confirm is impossible
  because `isCommitting = true` is assigned before the first suspension (`:661`). There is no undo
  stack and no flag persistence to go stale (`Session.swift:10-16`; README "How it works").
- **Filesystem correctness — no finding beyond QS-02/QS-03/QS-04.** Preview writes are per-file
  `tmp-<UUID>` + rename with a `replaceItemAt` loser path and a generation re-check before publish
  (`ImageCacheStore.swift:100-124`, `:134-141`); the histogram is keyed off the JPEG's URL rather than
  re-derived (`:167-186`); directory creation is actor-serialized (`:31-36`, `:49-60`); collision
  rename is bounded and retries on `NSFileWriteFileExistsError` (`MoveCommit.swift:65-90`); trash and
  move report per-file outcomes so one bad volume cannot abort a batch (`TrashCommit.swift:37-45`).
  ENOSPC mid-write is caught and reported as `cannotStorePreview` — see QS-02 for what happens next.
- **Memory and image lifecycle — no finding.** The viewer cannot exceed its extent (31) because every
  completion is gated on `currentKeep` (`ImageWindow.swift:153-159`) and eviction runs on every
  `setCurrent` (`:213-214`, definition `:319`); the filmstrip is capped at 81 thumbnails (`:408-414`, `:485`); the
  grid is bounded by the reported viewport, not by the shoot. Decodes use
  `CGImageSourceCreateThumbnailAtIndex` (`:623-634`), which materialises a new bitmap, so no
  file-backed/mmapped buffer outlives a source delete, and concurrent 45 MP bitmaps are capped at 3
  by `displayDecodeLimiter` (`:679`) with thumbnails at 4 (`:684`). Evicted `CGImage`s stay alive only
  as long as the view struct or a HUD task holds one (see Notes).
- **Threading contract — no finding.** `AppState`/`Session`/`ImageWindow` are `@MainActor`;
  `ImageCacheStore` is an actor and its `nonisolated` members either read only their argument
  (`cacheURL`, `histogramURL`) or re-enter the actor once for the generation snapshot
  (`ImageCacheStore.swift:89-95`, `:175-186`), so no read/modify/write can interleave — the
  actor only ever executes single statements. Every `@unchecked Sendable` type is either lock-guarded
  (`LoadTasks` `ImageWindow.swift:651-670`, `DecodeLimiter`, `LockedAccumulator`, `SingleResume`,
  `TaskBox`) or immutable (`DecodedBitmap`, `RawBitmap`'s `CGImage`); the only raw-pointer use is
  `LibRawDecoder`'s, scoped to the call (`LibRawDecoder.swift:31-33`, `:108-114`). The `gamm` rebind
  is correct for LibRaw 0.22.1 — `double gamm[6]` (`libraw_types.h:932`), not `float[6]`.
- **Crash on malformed input — no finding.** No `try!`/`as!`/`fatalError`/force-unwrap exists in
  `QuickCullCore/` or `QuickCull/` (grep, zero hits outside `precondition`). `makeCGImage` validates
  type/colors/bits/`data_size == w*h*3` before touching bytes (`LibRawDecoder.swift:103-115`);
  `rawHistogram` bounds the crop rectangle against `raw_width/raw_height` and refuses non-Bayer CFA
  values (`LibRawDecoder.swift:63-79`); every ImageIO/EXIF read is `as?`; `RawHistogram.init(from:)`
  rejects anything that is not 3×256 before a view can subscript it (`RawHistogram.swift:42-58`), and
  the sidecar load is `try?`-swallowed (`ImageCacheStore.swift:188-195`). The one unguarded subscript
  pair (`HistogramStats`/`RawHistogramView` over `bins[0...2]`) is unreachable from production — see
  Notes.

### New findings

#### QS-01 — Every mid-import decode failure re-installs and re-fills the whole viewer + filmstrip window: O(N) per failure, O(N²) per import

- **Severity:** Medium
- **Confidence:** High — measured end-to-end and decomposed; the mechanism is four O(N) passes per failure.
- **Trigger:** any import in which many files fail *after* the early view opened (`earlyViewThreshold`
  successes, default 50). The realistic causes are exactly the ones this app meets in the field:
  the card is ejected mid-import (the QC-01 workflow), the cache volume fills up (QS-02), or the
  user selects a folder of files the decoder cannot read. Example: a 1600-photo shoot, the default
  threshold of 50 reached, the card pulled — the remaining 1540 files fail one after another.
- **Location:** `QuickCullCore/App/AppState.swift:334-337` (failure branch), `QuickCullCore/App/AppState.swift:458-478`
  (`installWindows` → three `retarget`s + `syncWindows`), `QuickCullCore/App/AppState.swift:417-422`
  (`surfaceImportFailures`)
- **Code:**
```swift
// AppState.swift:330-337 — one .fileCompleted event with an error, after the early view opened
guard isViewing else { break }
// Mid-import failures must not sit behind a permanent
// spinner in the viewer: drop the file now, re-map the
// windows (they are position-addressed) and say so.
removeFilesWithoutPreviews([outcome.file])
if let live = session { installWindows(for: live.files) }
surfaceImportFailures(failures, unsupported: unsupportedFailures,
                      order: inputOrder)
```
```swift
// AppState.swift:417-422 — re-sorts the whole accumulated failure list on every failure
importFailures = (unsupported + failures.sorted {
    (order[$0.file.id] ?? 0) < (order[$1.file.id] ?? 0)
}).filter { !dismissedImportFailureIDs.contains($0.file.id) }
```
- **Impact:** the UI stalls for the whole tail of such an import, and the cost grows quadratically
  with the shoot. Measured with `probe_f_failpath` (every decode after the first K throws — a real
  `AppState` with stub decoder/trasher/mover, time from `importFiles` to the session settling):
```
100 files,   98 failures, threshold 2  (window sits over undecoded slots): 0.04 s
200 files,  198 failures, threshold 2:                                     0.50 s
400 files,  398 failures, threshold 2:                                     1.63 s
800 files,  798 failures, threshold 2:                                     4.22 s
400 files,  340 failures, threshold 50 (window sits over cached slots):     0.41 s
800 files,  740 failures, threshold 50:                                    1.58 s
1600 files, 1540 failures, threshold 50:                                   6.23 s
```
  The threshold-50 rows are the realistic shape (default threshold 50, early view open, card pulled
  or disk full); 1600 photos costs 6.2 s and the growth from 400 → 1600 (4×) is ~15×. Decomposition
  at N=800 of the intrinsic O(N)-per-failure work (`probe_g_split`): three `retarget(ids:)` calls
  over the full list = **0.49 s**, `Session.remove`'s projection rebuild = **0.34 s**, re-sort of the
  accumulated failure list = 0.02 s. The rest of the threshold-50 figure is the re-queued window
  fill: `installWindows` → `syncWindows` re-queues every slot with no resident image, i.e. every
  slot holding a failed file, forever — a failed file never becomes resident, so each new failure
  pays for the missing slots again (one pass = 31 display + 61 strip loads = 3.6 ms,
  `probe_h_reload`; that term dominates when the window sits over undecoded files, as it does right
  after the early view opens). Resident images themselves survive `retarget`, so nothing is
  re-decoded twice.
- **Proposed fix:** coalesce per failure instead of per event. (a) Drop the `installWindows` call
  from the failure branch: `ImageWindow.retarget` already drops an identity that leaves the
  projection, so retarget all three windows **once** per flush, not per failure. (b) Flush the
  accumulated failures (remove + retarget + `surfaceImportFailures`) at most once per N ms
  (e.g. a `failureFlushScheduled` flag applied on the next main-actor turn) or only on `.progress`/
  `.completed`, which already exists as the `!isViewing` path at `:376-386`. (c) Append failures in
  completion order and sort once per flush rather than once per item.
- **Evidence:** the two probe tables quoted above; `probe_h_reload` shows the 3.6 ms/pass figure
  with the production `ImageWindow.display`/`thumbnails` factories over 800 files and an empty cache;
  `probe_g_split` splits the intrinsic O(N) terms.

#### QS-02 — A preview-cache write failure removes the photo from the culling session, so a full cache volume silently discards the rest of the shoot

- **Severity:** Medium
- **Confidence:** High — observed end-to-end on a genuinely full volume.
- **Trigger:** the cache volume fills (or `~/Library/Application Support` is not writable) while the
  import runs. The app has no cache size cap and each 45 MP preview is ~2 MB, so a long shoot can
  fill the boot volume by itself. Photos then fail with `cannotStorePreview`, which
  `removeFilesWithoutPreviews` treats exactly like a decode failure.
- **Location:** `QuickCullCore/App/AppState.swift:406-411`, `QuickCullCore/Engine/DecodeEngine.swift:185-190`,
  `QuickCullCore/Storage/ImageCacheStore.swift:117-119`
- **Code:**
```swift
// AppState.swift:406-411
private func removeFilesWithoutPreviews(_ files: [SessionFile]) {
    guard !files.isEmpty, let session else { return }
    session.remove(files)
    gridSelection = gridSelection.filter { session.contains(id: $0) }
    if session.totalCount == 0 { transitionToEmptySession() }
}
```
```swift
// DecodeEngine.swift:185-190 — the write failure is classified correctly …
} catch {
    // The cache is a separate boundary: a write failure is not a decode
    // failure, and saying so is what lets a user free up disk instead
    // of believing the photo is broken.
    return (DecodeOutcome(file: file, error: .cannotStorePreview("\(error)")),
            bitmap.width, bitmap.height)
}
```
- **Impact:** the photos are not broken, but they leave the session — with their flags — and the only
  recovery (`File ▸ New Session`, then re-import) wipes every preview that did land and re-decodes
  the shoot from scratch, which fills the disk again. The session is destroyed by a transient
  condition, and the taxonomy's own rationale ("retry the file vs. free up disk",
  `ImportFailureSummary.swift:3-9`) is defeated because the file is gone from the session by the
  time the user could act on it.
- **Proposed fix:** treat `cannotStorePreview` as an *import-level* condition, not a per-file one:
  stop the import the way `cancelImport` does (or pause it), report one failure, and keep every file
  in the session so the shoot survives a freed disk; failing that, do not remove a file whose only
  error is `.cannotStorePreview` and do not let it trigger `transitionToEmptySession`.
- **Evidence:** `probe_c_enospc` imports 12 copies of a 700×700 noisy bitmap into a 2 MB RAM volume
  (`/Volumes/QCENOSPC`) through `AppState`:
```
imported 12 files into a cache volume with ~1.9 MB free
phase: empty
session totalCount: -1, visible: -1
import failures: 12
failure kinds: ["cannotStorePreview (disk)": 12]
example store failure: cannotEncode
source files still present on the card: 12 of 12
previews actually cached: 0
```

#### QS-03 — A Move whose destination is the source folder reports success without moving anything; the photos then leave the session and lose their cached previews

- **Severity:** Low
- **Confidence:** High — observed; the branch is explicit.
- **Trigger:** choose a destination folder that is the folder the photos already live in — e.g. a
  shoot imported from `~/Pictures/Shoot` and "Move All Flagged…" back to `~/Pictures/Shoot`, or a
  destination that is the source folder of a *subset* of a multi-folder import. `isSameDirectory`
  also returns true through a symlink to that folder, so it triggers even when the path strings differ.
- **Location:** `QuickCullCore/Commit/MoveCommit.swift:44-50`, consumed at `QuickCullCore/App/AppState.swift:748-768`
- **Code:**
```swift
// MoveCommit.swift:44-50
// A move into the folder the file already lives in is a no-op.
// Without this the collision suffix below finds the file itself at
// the destination and renames every original to "name 1.ext" in
// place — a mass rename the user never asked for.
if Self.isSameDirectory(file.url.deletingLastPathComponent(), destination) {
    return MoveOutcome(file: file, error: nil)
}
```
- **Impact:** the session claims a durable change that never happened. `confirmMove` takes
  `outcomes.filter(\.succeeded)` (`AppState.swift:750`), removes those files from the session (`:751`),
  and deletes their cached previews (`:768`, definition `:785-789`), so the flagged photos silently vanish from the
  cull while remaining on disk; `moveFailures` stays empty, so no alert is raised. No data loss, but
  the AUD-01 fix traded a mass rename for a silent lie, and a re-import brings the photos back as if
  nothing happened.
- **Proposed fix:** give the no-op its own outcome (or a `MoveError.sameDirectory`) and have
  `confirmMove` keep those files in the session, or refuse the request in `AppState.requestMove`
  when the destination is the source directory of every selected file.
- **Evidence:** `probe_a_move` — three photos "moved" into their own folder:
```
destination == source folder
outcomes: 3, succeeded: 3, failed: 0
  IMG_0001.CR2 succeeded=true error=nil
  ...
source files still on disk: 3 of 3
folder now contains: ["IMG_0001.CR2", "IMG_0002.CR2", "IMG_0003.CR2"]
destination is a symlink to the source folder
  succeeded: 3 of 3
  source files still on disk: 3 of 3
```

#### QS-04 — Trash uses the imported path, not the file identity, so a symlinked photo's link is trashed and the real file survives

- **Severity:** Low
- **Confidence:** High — observed; `SessionFile` stores the unresolved URL while identity and cache
  key use the resolved one.
- **Trigger:** a photo imported through a symbolic link (a "picks" folder of symlinks into the card
  is a common curation trick; a symlinked folder component is not affected, only a symlinked *file*).
  The app identifies and caches the target (`RawFileIdentity.fileID` resolves symlinks,
  `RawFileIdentity.swift:54-56`) but trashes `file.url`.
- **Location:** `QuickCullCore/Models/SessionFile.swift:5-10`, `QuickCullCore/Commit/TrashCommit.swift:10-13`
- **Code:**
```swift
// SessionFile.swift:5-10 — identity of one object, path of another
public let url: URL
public let id: String
public init(url: URL) {
    self.url = url
    self.id = RawFileIdentity.fileID(for: url)
}
```
```swift
// TrashCommit.swift:10-13
public func trash(url: URL) throws {
    var resulting: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
}
```
- **Impact:** the reject the user believes is in the Trash is still on the card. The commit reports
  success, `session.remove` drops the photo, and its cached preview (keyed on the *target*) is
  deleted. Nothing unintended is trashed — the path is exactly the one the user selected — so this
  is a silent no-op presented as a durable delete, not a wrong-file delete.
- **Proposed fix:** give `SessionFile` a resolved `fileURL` (`url.resolvingSymlinksInPath()`) and use
  it for every destructive/fstat operation (`trash`, `move`, `cacheURL`'s stat), keeping `url` only
  for display.
- **Evidence:** `probe_d_symlink` — a `picks/IMG_0001.CR2` symlink to `card/IMG_0001.CR2`:
```
imported url : .../scratch-link/picks/IMG_0001.CR2
identity/id  : .../scratch-link/card/IMG_0001.CR2
trash outcome reported success: true
the symlink itself still exists : false
the real photo still exists     : true
```

### Corrections to the first pass

- **QC-02's proposed fix is slightly wrong.** It says to clear the failure mark "in `retarget(ids:)`".
  `retarget` runs on every filter switch, every flag toggle under a filter and every commit, so each
  of those would re-arm one doomed full-res decode per affected identity. That is bounded (one
  attempt per retarget, not a spin), so the advice is not dangerous — but the mark should only be
  cleared by `refresh(id:)` (a decode actually landed) or by a change to the cache key, not by a
  projection change that cannot affect the cache.
- **"Checked and clean → Import pipeline and early view — no stale-write hole found" is
  understated.** The *correctness* conclusion holds (I re-traced the generation guard, the
  failure-pruning and the preview discard), but the section reads as an endorsement of the pipeline
  and the per-failure path is measurably quadratic (QS-01: 1.6 s for 740 failures at N=800 and
  6.2 s for 1540 at N=1600 with the default threshold; 4.2 s at N=800 when the viewer sits on
  undecoded files).
- **"Checked and clean → Cache write path" stops at atomicity.** It verifies tmp+rename and the
  generation check but does not follow a *failed* store into `AppState`, where it removes the photo
  from the session (QS-02).
- **"Commit/move safety … collision rename is bounded" omits the same-directory branch.** AUD-01's
  fix (`isSameDirectory`) is real, but it returns a *success* outcome for a move that did not happen,
  which the session then treats as durable (QS-03). The first pass calls move safety clean.
- **QC-02's "line 186-190 restarts the full-res load unconditionally" and its 100 %-CPU evidence are
  accurate** — I re-read the branch and did not find an additional trigger, and I did not reproduce
  it in my probes because the trigger needs a missing cache entry, which is QC-02's subject. No
  correction, just confirmation that the surrounding bookkeeping is sound (lane 1 above).
- **QC-03 anchors verified** (`project.pbxproj:463` and `:484` are both
  `ENABLE_HARDENED_RUNTIME = NO`; there is still no `*.entitlements` outside `Build/`), so the report's
  security finding is not overstated.

### Notes

Not findings: hardening, missing tests, carried items.

- **`CacheError.cannotEncode` discards the underlying error** (`ImageCacheStore.swift:116-119`), so
  whatever went wrong — ENOSPC, a read-only volume, a sandbox denial — the banner always says
  "check free disk space" (`ImportFailureSummary.swift:40`). Capturing the `CFError`/errno would make
  the one actionable sentence in that banner correct.
- **`confirmCommit`/`confirmMove`'s generation-mismatch early return leaves the state machine
  armed** (`AppState.swift:679`, `:749`): `isCommitting`/`isMoving` stay true and
  `pendingCommitCount`/`pendingMoveCount` stay set. Today the only paths that bump the generation
  during a commit (`importFiles`, `startNewSession`, `cancelImport`) are all unreachable from the
  scrub UI, and each of them calls `resetTransientState()`, so the branch is purely defensive. It is
  a landmine for any future generation bump that skips `resetTransientState` (Trash/Move would stay
  disabled until the next import).
- **An early-view import cannot be cancelled.** `DecodingView`'s Cancel button
  (`DecodingView.swift:18`) exists only while `phase == .decoding`; once the early view opens, the
  background decode can only be stopped by File ▸ New Session, which discards flags and wipes the
  cache. Combined with QS-01 this is what makes a failing import feel stuck.
- **Window loads do one `stat` on the main actor per load** (`ImageWindow.swift:552`, `:566`, `:500`
  → `cache.cacheURL`), i.e. 92 of them per `setCurrent` pass. Measured at 3.6 ms total on a warm SSD
  (`probe_h_reload`); on a spun-down or network volume each one blocks the main thread. This is the
  same class as round 4's carried "`resolvedPreviewURLs` stats on the main actor" and is not
  re-filed.
- **`ImageWindow`'s blocking decode runs on the cooperative pool** (`ImageWindow.swift:556-562`,
  `:567-573`) while `DecodeEngine` deliberately moved its blocking demosaic to a dispatch queue for
  exactly this reason (`DecodeEngine.swift:200-206`). Up to 3 + 4 cooperative threads can park for
  100-400 ms during a window fill. No correctness or starvation effect observed; the two paths
  should agree.
- **`MetadataHUDView`'s detached workers outlive their task** (`MetadataHUDView.swift:58-67`): the
  outer `.task(id:)` is cancelled on every file change, but each `Task.detached` runs to completion
  and keeps its `CGImage` alive until then. Bounded in practice (tens of ms per worker), but it is a
  second retention path for an image `ImageWindow` may already have evicted.
- **`Session.toggleFlags`'s "projection changed" return is count+filter based**
  (`Session.swift:227`), which is only correct because the id set is always a subset of the
  projection (`AppState.swift:520`). Worth a comment: if a future caller passes ids outside the
  projection, a same-size swap would be missed and `installWindows` would be skipped.
- **`RawHistogram.init(bins:sensorMax:)` does not validate 3×256** (`RawHistogram.swift:39-42`);
  `HistogramStats.init` and `RawHistogramView` would trap on a two-channel value. No production path
  constructs one (both call sites pass three channels and the decoder path validates), so this is a
  latent API trap only.
- **Untested behaviours this pass exercised by hand:** a load cancelled by eviction and re-wanted
  before it settles; a load that completes after `retarget`; a cancel storm (200 scrubs + 600
  `ensureLoaded`); a wholesale mid-import failure; a full cache volume; a move into the source folder;
  a trashed symlink. The first five map to `ImageWindowTests`/`AppStateEarlyViewTests` gaps, the last
  two to `MoveCommitTests`/`TrashCommitTests`.

### Gates

- `xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest` at HEAD `5e30dfa`:
  302 tests, 0 failures (100 s) — reproduced on this pass.
- Probes: `probe_a_move`, `probe_b_importprep`, `probe_c_enospc`, `probe_d_symlink`,
  `probe_e_window`, `probe_f_failpath`, `probe_g_split`, `probe_h_reload` in
  `/tmp/code-audit/probes/pass2-quickcull/`, built with `build.sh` against the HEAD framework.
  `probe_b_importprep` measured import preparation (2 realpath passes per file) at 43.6 ms for 2000
  files on a local SSD — **not** reported as a finding, but it is redundant work
  (`RawFileIdentity.fileID` is computed once for the dedupe and again in `SessionFile.init`) and would
  matter on a network volume.
