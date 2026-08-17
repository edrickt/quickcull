# Cull Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tri-state toolbar filter (All / Flagged / Keepers) to the scrub phase, so the sequence and filmstrip show only photos matching the filter.

**Architecture:** `Session` owns the full post-commit file list privately (`allFiles`) and exposes the filtered projection as `files` — the property every view and window already reads. Filter changes and flag toggles under a filter rebuild the two `ImageWindow`s from the projection via the existing `installWindows(for:)` path. `ScrubView` gets a segmented toolbar picker. Views other than the toolbar are untouched.

**Tech Stack:** Swift 6, SwiftUI, Observation (`@Observable`), XCTest (macOS, `xcodebuild` + `xcrun xctest`).

## Global Constraints

- Default filter is `.all`; pre-filter behavior must be bit-for-bit unchanged (existing 69 tests pin this).- Filter is per-session state: fresh `Session` per import, always starting at `.all`.
- Under a non-All filter, a flag toggle always drops the current photo out of the sequence and auto-advances to the next match (index clamped at the end).
- An empty visible sequence falls back to `.all`: after the last photo drops out, keep that photo current (by id); after a commit empties it, land on the first remaining file.
- `flaggedFiles` must filter `allFiles` (not the projection) — commit must find flagged files while the Keepers filter hides them.
- Toolbar control only — no new keyboard shortcut. Filmstrip shows only matching photos (no view changes).
- Harness build workaround: every `xcodebuild` invocation needs `export TMPDIR=/tmp/qc-tmp CLANG_MODULE_CACHE_PATH=/tmp/qc-modcache` and `OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox"` (see Build / Test Commands; needed because the sandboxed shell can't write `/var/folders` and nested `sandbox-exec` is denied).
- `CullFilter` is `CaseIterable, Hashable, Sendable` (Hashable required for SwiftUI `Picker` `.tag`).
- Naming follows the repo: `CullFilter` next to `CullAction`; `allFiles` / `files` / `filter` as in the spec (`docs/superpowers/specs/2026-08-16-cull-filter-design.md`).

## File Structure

- Create: `QuickCullCore/Session/CullFilter.swift` — the tri-state filter enum. (Auto-picked-up by the Xcode project's synchronized file groups; no `.pbxproj` edit needed.)
- Modify: `QuickCullCore/Session/Session.swift` — `allFiles`, `filter`, `totalCount`, projection helpers, `setFilter`, `toggleFlag` (returns `Bool`), `remove` rework, `flaggedFiles` sourced from `allFiles`.
- Modify: `QuickCullCore/App/AppState.swift` — `setFilter(_:)`, `handle(.toggleFlag)` rebuild decision.
- Modify: `QuickCull/ScrubView.swift` — segmented filter picker in the toolbar.
- Modify: `QuickCullCoreTests/SessionTests.swift`, `QuickCullCoreTests/AppStateTests.swift` — new tests.

## Build / Test Commands

In this session (DSH harness), the sandboxed shell breaks xcodebuild two ways:
`/var/folders` is unwritable (clang module cache) and the Swift compiler's
`sandbox-exec`-wrapped plugin server cannot nest. Every `xcodebuild` run needs
the workaround below. In a normal Mac shell the extra flags are unnecessary
but harmless.

Incremental test build (fast; derived data already exists at `/tmp/qc-dd`):

```bash
export TMPDIR=/tmp/qc-tmp CLANG_MODULE_CACHE_PATH=/tmp/qc-modcache
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox" build-for-testing
```

Run all tests (real baseline: 69 tests, per README and per-source count):

```bash
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
```

Run one test class (faster iteration; note the option comes BEFORE the bundle
path — this xctest rejects the other order):

```bash
xcrun xctest -XCTest SessionTests /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
```

---

### Task 1: `CullFilter` type and `Session` projection + `setFilter`

**Files:**
- Create: `QuickCullCore/Session/CullFilter.swift`
- Modify: `QuickCullCore/Session/Session.swift`
- Test: `QuickCullCoreTests/SessionTests.swift`

**Interfaces:**
- Consumes: `SessionFile.id: String` (`QuickCullCore/Models/SessionFile.swift`, unchanged).
- Produces:
  - `public enum CullFilter: CaseIterable, Hashable, Sendable { case all, flagged, keepers }` in `QuickCullCore.Session` module namespace.
  - `Session.filter: CullFilter` (read-only, `.all` default), `Session.totalCount: Int` (full-list count).
  - `Session.setFilter(_ filter: CullFilter)` — public, `@MainActor`.

- [ ] **Step 1: Write the failing tests** — append to `QuickCullCoreTests/SessionTests.swift`, after `testFlagChangesAreObservable`:

```swift
    // MARK: Filter

    func testDefaultFilterIsAll() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2"]))
        XCTAssertEqual(session.filter, .all)
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.totalCount, 2)
    }

    func testFlaggedFilterProjectsFlaggedOnly() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.toggleFlag()              // flag a
        session.move(by: 2)
        session.toggleFlag()              // flag c
        session.setFilter(.flagged)
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.files.map(\.url.lastPathComponent), ["a.cr2", "c.cr2"])
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "c.cr2")   // current kept
    }

    func testKeepersFilterProjectsUnflagged() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.toggleFlag()              // flag a
        session.setFilter(.keepers)       // a no longer matches
        XCTAssertEqual(session.files.map(\.url.lastPathComponent), ["b.cr2", "c.cr2"])
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "b.cr2")   // nearest match
    }

    func testFilterJumpTieResolvesForward() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2", "d.cr2"]))
        session.setIndex(2)               // current = c
        session.toggleFlag()              // flag c, so keepers excludes it
        session.setFilter(.keepers)       // b and d are equidistant
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "d.cr2")
    }

    func testFilterJumpPrefersNearestBackward() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2", "d.cr2", "e.cr2"]))
        session.setIndex(2)               // current = c
        session.toggleFlag()              // flag c
        session.move(by: 1)
        session.toggleFlag()              // flag d
        session.setIndex(2)               // current = c again
        session.setFilter(.keepers)       // b is nearer than e
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "b.cr2")
        session.setFilter(.flagged)       // back to flagged: c, current by id
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "c.cr2")
    }

    func testFilterMatchingNothingResetsToAll() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2"]))
        session.setFilter(.flagged)       // nothing is flagged
        XCTAssertEqual(session.filter, .all)
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "a.cr2")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox" build-for-testing \
  && xcrun xctest -XCTest SessionTests /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
```

Expected: FAIL — `CullFilter` unresolved, `filter`/`totalCount`/`setFilter` missing.

- [ ] **Step 3: Create `QuickCullCore/Session/CullFilter.swift`**

```swift
import Foundation

/// Which photos the scrub sequence shows.
public enum CullFilter: CaseIterable, Hashable, Sendable {
    /// Every photo in the session.
    case all
    /// Only photos flagged for deletion.
    case flagged
    /// Only photos not flagged for deletion.
    case keepers
}
```

- [ ] **Step 4: Add projection state to `QuickCullCore/Session/Session.swift`**

Add `filter` and `allFiles` to the stored properties, and initialize `allFiles` in `init`:

```swift
    public private(set) var files: [SessionFile]
    public private(set) var currentIndex: Int = 0
    public private(set) var flagged: Set<String> = []
    public private(set) var filter: CullFilter = .all

    /// The full post-commit file list; `files` is its projection under
    /// `filter`. Nothing outside Session touches this.
    private var allFiles: [SessionFile]

    public init(files: [SessionFile]) {
        precondition(!files.isEmpty, "Session requires at least one file")
        self.files = files
        self.allFiles = files
    }
```

Add `totalCount` next to `count`/`isEmpty`:

```swift
    public var count: Int { files.count }
    public var isEmpty: Bool { files.isEmpty }
    /// Every photo in the session, filtered or not (for keeper counts).
    public var totalCount: Int { allFiles.count }
```

Add a `// MARK: Filtering` section after `setIndex(_:)`:

```swift
    // MARK: Filtering

    private func matches(_ file: SessionFile, _ filter: CullFilter) -> Bool {
        switch filter {
        case .all: return true
        case .flagged: return flagged.contains(file.id)
        case .keepers: return !flagged.contains(file.id)
        }
    }

    private func projection(for filter: CullFilter) -> [SessionFile] {
        allFiles.filter { matches($0, filter) }
    }

    /// Position of `file` in the full list (order-preserving projection
    /// invariant: `files` is always a subsequence of `allFiles`).
    private func position(of file: SessionFile) -> Int {
        allFiles.firstIndex(where: { $0.id == file.id }) ?? 0
    }

    /// Switches the visible sequence to `filter`. The current photo stays
    /// current when it still matches; otherwise the nearest match in full
    /// list order takes over, ties resolving forward. A filter matching
    /// nothing (e.g. Flagged while nothing is flagged) falls back to All.
    public func setFilter(_ filter: CullFilter) {
        let newFiles = projection(for: filter)
        guard !newFiles.isEmpty else {
            self.filter = .all
            files = allFiles
            if let idx = allFiles.firstIndex(where: { $0.id == currentFile.id }) {
                currentIndex = idx
            }
            return
        }
        let currentID = currentFile.id
        self.filter = filter
        files = newFiles
        if let idx = newFiles.firstIndex(where: { $0.id == currentID }) {
            currentIndex = idx
        } else {
            currentIndex = nearestMatchIndex(to: currentID, in: newFiles)
        }
    }

    /// Index in `newFiles` of the file closest to `currentID`'s position in
    /// the full list; a tie resolves to the later (forward) file. Only
    /// called when `currentID` is NOT in `newFiles`, so the anchor is the
    /// current photo's position in `allFiles` (it always exists there).
    private func nearestMatchIndex(to currentID: String, in newFiles: [SessionFile]) -> Int {
        let currentPos = allFiles.firstIndex(where: { $0.id == currentID }) ?? 0
        var best = 0
        var bestDistance = Int.max
        for (i, file) in newFiles.enumerated() {
            let pos = position(of: file)
            let distance = abs(pos - currentPos)
            if distance < bestDistance
                || (distance == bestDistance && pos > position(of: newFiles[best])) {
                best = i
                bestDistance = distance
            }
        }
        return best
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox" build-for-testing \
  && xcrun xctest -XCTest SessionTests /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
```

Expected: PASS — all 16 Session tests (10 existing + 6 new).

- [ ] **Step 6: Commit**

```bash
git add QuickCullCore/Session/CullFilter.swift QuickCullCore/Session/Session.swift QuickCullCoreTests/SessionTests.swift
git commit -m "feat: session filter projection with setFilter (all/flagged/keepers)"
```

---

### Task 2: Flag-toggle drop-out, `remove` rework, `flaggedFiles` from full list

**Files:**
- Modify: `QuickCullCore/Session/Session.swift`
- Test: `QuickCullCoreTests/SessionTests.swift`

**Interfaces:**
- Consumes: `CullFilter`, `position(of:)`, `projection(for:)` from Task 1; `Session.filter`, `Session.files`, `Session.flagged` (existing).
- Produces:
  - `Session.toggleFlag() -> Bool` — now `@discardableResult`, returns whether the visible sequence changed (always `false` in `.all` mode).
  - `Session.remove(_ filesToRemove: [SessionFile])` — reworked semantics below (existing callers unchanged).
  - `Session.flaggedFiles` — now filters `allFiles`.

- [ ] **Step 1: Write the failing tests** — append to `QuickCullCoreTests/SessionTests.swift`:

```swift
    // MARK: Filter interplay

    func testToggleFlagInFlaggedModeAdvances() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.toggleFlag()              // flag a
        session.move(by: 1)
        session.toggleFlag()              // flag b
        session.setFilter(.flagged)       // [a, b], current = b
        session.toggleFlag()              // unflag b: drops out, a takes over
        XCTAssertEqual(session.count, 1)
        XCTAssertEqual(session.files.map(\.url.lastPathComponent), ["a.cr2"])
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "a.cr2")
        XCTAssertTrue(session.isFlagged(session.currentFile))
    }

    func testToggleFlagInKeepersModeAdvances() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.toggleFlag()              // flag a
        session.setFilter(.keepers)       // [b, c], current = b
        session.toggleFlag()              // flag b: drops out, c takes over
        XCTAssertEqual(session.count, 1)
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "c.cr2")
        XCTAssertEqual(session.flaggedCount, 2)
    }

    func testUnflaggingLastVisibleResetsToAll() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2"]))
        session.toggleFlag()              // flag a
        session.setFilter(.flagged)       // [a]
        session.toggleFlag()              // unflag a: projection empties
        XCTAssertEqual(session.filter, .all)
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "a.cr2")  // kept by id
        XCTAssertEqual(session.flaggedCount, 0)
    }

    func testRemoveUnderKeepersFilterKeepsCurrent() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        let all = session.files
        session.toggleFlag()              // flag a
        session.setFilter(.keepers)       // [b, c], current = b
        session.remove([all[0]])          // trash flagged a (not visible)
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.files.map(\.url.lastPathComponent), ["b.cr2", "c.cr2"])
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "b.cr2")
        XCTAssertEqual(session.totalCount, 2)
    }

    func testRemoveAllVisibleUnderFlaggedFilterResetsToAll() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        let all = session.files
        session.toggleFlag()              // flag a
        session.move(by: 1)
        session.toggleFlag()              // flag b
        session.setFilter(.flagged)       // [a, b], current = b
        session.remove([all[0], all[1]])  // commit trashes both flagged
        XCTAssertEqual(session.filter, .all)
        XCTAssertEqual(session.count, 1)
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "c.cr2")  // first remaining
    }

    func testFlaggedFilesComesFromFullListUnderKeepers() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2"]))
        let all = session.files
        session.toggleFlag()              // flag a
        session.setFilter(.keepers)       // a is not visible
        XCTAssertEqual(session.flaggedFiles.map(\.id), [all[0].id])
    }

    func testRemoveCurrentLandsOnNextSurvivor() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2", "d.cr2"]))
        session.setIndex(2)               // current = c
        session.remove([session.files[2]])
        XCTAssertEqual(session.count, 3)
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "d.cr2")
    }

    func testRemoveCurrentAtEndLandsOnLastSurvivor() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.setIndex(2)               // current = c
        session.remove([session.files[2]])
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "b.cr2")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox" build-for-testing \
  && xcrun xctest -XCTest SessionTests /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
```

Expected: FAIL — auto-advance not implemented, `flaggedFiles` empty under Keepers, `remove` semantics off.

- [ ] **Step 3: Rework `toggleFlag`** — replace the existing `toggleFlag()` in `Session.swift` with:

```swift
    /// Toggles the current photo's reject flag. Under a non-All filter the
    /// flip always drops the photo out of the visible sequence, so the next
    /// match takes its place (index clamped at the end); if the sequence
    /// empties entirely the filter falls back to All, keeping the photo.
    /// Returns whether the visible sequence changed (always false in All
    /// mode).
    @discardableResult
    public func toggleFlag() -> Bool {
        guard !files.isEmpty else { return false }
        let id = currentFile.id
        if flagged.contains(id) { flagged.remove(id) } else { flagged.insert(id) }
        guard filter != .all else { return false }
        let newFiles = projection(for: filter)
        if newFiles.isEmpty {
            filter = .all
            files = allFiles
            if let idx = allFiles.firstIndex(where: { $0.id == id }) { currentIndex = idx }
        } else {
            files = newFiles
            currentIndex = min(currentIndex, newFiles.count - 1)
        }
        return true
    }
```

- [ ] **Step 4: Rework `flaggedFiles`** — replace the computed property with:

```swift
    /// Flagged files from the FULL session list: under the Keepers filter
    /// the flagged files are not visible, and commit must still find them.
    public var flaggedFiles: [SessionFile] {
        allFiles.filter { flagged.contains($0.id) }
    }
```

- [ ] **Step 5: Rework `remove`** — replace the existing `remove(_:)` with:

```swift
    /// Remove trashed files after a successful commit. All flags are cleared
    /// (flagged files are exactly the ones being removed). The current photo
    /// is preserved: after removal the first survivor at or after its old
    /// position becomes current, or the last survivor when none follows —
    /// exactly the pre-filter index-shift behavior in All mode, generalized
    /// to the projection. A commit that empties the visible sequence while
    /// files remain (e.g. every flagged photo committed in Flagged mode)
    /// falls back to All, landing on the first file.
    public func remove(_ filesToRemove: [SessionFile]) {
        let ids = Set(filesToRemove.map(\.id))
        let original = allFiles
        let currentPos = original.firstIndex(where: { $0.id == currentFile.id }) ?? 0
        flagged.subtract(ids)
        allFiles.removeAll { ids.contains($0.id) }
        files = projection(for: filter)
        guard !files.isEmpty else {
            currentIndex = 0
            if !allFiles.isEmpty {
                filter = .all
                files = allFiles
            }
            return
        }
        // First survivor at or after the old current position (today's
        // index-shift semantics, generalized to the projection); else the
        // last survivor. Positions are the ORIGINAL full-list ones: the
        // projection preserves full-list order, and `files` is a
        // subsequence of `allFiles` at every point.
        let originalPositions = Dictionary(uniqueKeysWithValues: original.enumerated().map { ($0.element.id, $0.offset) })
        if let survivor = files.first(where: { (originalPositions[$0.id] ?? 0) >= currentPos }),
           let idx = files.firstIndex(where: { $0.id == survivor.id }) {
            currentIndex = idx
        } else {
            currentIndex = files.count - 1
        }
    }
```

- [ ] **Step 6: Run the full test bundle**

```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox" build-for-testing \
  && xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
```

Expected: PASS — all 83 tests (75 existing + 8 new). The 5 pre-existing `remove` tests pin today's index-shift semantics; they must pass unmodified.

- [ ] **Step 7: Commit**

```bash
git add QuickCullCore/Session/Session.swift QuickCullCoreTests/SessionTests.swift
git commit -m "feat: flag toggle drops out of filtered sequence; remove reworked for projection"
```

---

### Task 3: `AppState` filter plumbing

**Files:**
- Modify: `QuickCullCore/App/AppState.swift`
- Test: `QuickCullCoreTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `Session.setFilter(_:)`, `Session.toggleFlag() -> Bool`, `Session.filter`, `Session.files`, `Session.flaggedCount` (Tasks 1-2); `AppState.installWindows(for:)`, `AppState.syncWindows()` (existing private methods, unchanged).
- Produces:
  - `AppState.setFilter(_ filter: CullFilter)` — public; no-op unless `phase == .scrubbing`; rebuilds both windows over `session.files`.
  - `AppState.handle(.toggleFlag)` — rebuilds windows only when `toggleFlag()` returns `true`.

- [ ] **Step 1: Write the failing tests** — append to `QuickCullCoreTests/AppStateTests.swift`:

```swift
    func testSetFilterRebuildsWindowsOverProjection() async throws {
        let files = try (0..<3).map { try TestFixtures.makeRawFile(named: "f\($0).cr2", in: tempDir) }
        let state = makeState()
        state.importFiles(urls: files)
        await waitForScrubbing(state)

        state.handle(.toggleFlag)          // flag f0
        state.setFilter(.flagged)
        XCTAssertEqual(state.session?.count, 1)
        XCTAssertEqual(state.thumbWindow?.count, 1)
        XCTAssertEqual(state.displayImages?.count, 1)

        state.setFilter(.all)
        XCTAssertEqual(state.session?.count, 3)
        XCTAssertEqual(state.thumbWindow?.count, 3)
    }

    func testToggleFlagRebuildsWindowsOnlyWhenProjectionChanges() async throws {
        let files = try (0..<3).map { try TestFixtures.makeRawFile(named: "f\($0).cr2", in: tempDir) }
        let state = makeState()
        state.importFiles(urls: files)
        await waitForScrubbing(state)

        let window = state.thumbWindow
        state.handle(.toggleFlag)          // All mode: sequence unchanged
        XCTAssertTrue(state.thumbWindow === window,
                      "flag toggle in All mode must not rebuild windows")

        state.setFilter(.flagged)          // [f0]
        state.handle(.toggleFlag)          // unflag f0: projection empties -> reset to All
        XCTAssertEqual(state.session?.filter, .all)
        XCTAssertEqual(state.session?.count, 3)
        XCTAssertNotNil(state.thumbWindow)
    }

    func testCommitUnderKeepersFilterTrashesFlagged() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let trasher = StubTrasher()
        let state = makeState(trasher: trasher)
        state.importFiles(urls: [a, b])
        await waitForScrubbing(state)

        state.handle(.toggleFlag)          // flag a
        state.setFilter(.keepers)          // [b], current = b
        state.requestCommit()
        XCTAssertEqual(state.pendingCommitCount, 1)
        await state.confirmCommit()

        XCTAssertEqual(trasher.trashed.count, 1)
        XCTAssertEqual(state.session?.count, 1)
        XCTAssertEqual(state.session?.filter, .keepers)
        XCTAssertEqual(state.session?.currentFile.url.lastPathComponent, "b.cr2")
        XCTAssertEqual(state.thumbWindow?.count, 1)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox" build-for-testing \
  && xcrun xctest -XCTest AppStateTests /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
```

Expected: FAIL — `setFilter` unresolved.

- [ ] **Step 3: Add `setFilter` to `AppState`** — insert after `setCurrentIndex(_:)`:

```swift
    /// Switches the visible sequence to `filter` and rebuilds both image
    /// windows over the new projection (same path commit uses). No-op
    /// outside the scrubbing phase.
    public func setFilter(_ filter: CullFilter) {
        guard let session, phase == .scrubbing else { return }
        session.setFilter(filter)
        installWindows(for: session.files)
    }
```

- [ ] **Step 4: Update `handle(.toggleFlag)`** — replace the existing case:

```swift
        case .toggleFlag:
            // A flag flip under a non-All filter changes the visible
            // sequence (the photo drops out / the filter falls back to
            // All), so the windows must be rebuilt over the new
            // projection. In All mode the sequence is unchanged and the
            // windows stay put.
            if session.toggleFlag() {
                installWindows(for: session.files)
            } else {
                syncWindows()
            }
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox" build-for-testing \
  && xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
```

Expected: PASS — all 86 tests.

- [ ] **Step 6: Commit**

```bash
git add QuickCullCore/App/AppState.swift QuickCullCoreTests/AppStateTests.swift
git commit -m "feat: app state filter plumbing — rebuild windows on filter change"
```

---

### Task 4: Toolbar filter picker

**Files:**
- Modify: `QuickCull/ScrubView.swift`

**Interfaces:**
- Consumes: `AppState.setFilter(_:)`, `AppState.session?.filter`, `AppState.session?.flaggedCount`, `AppState.session?.totalCount`, `AppState.isCommitting` (all existing/public from Tasks 1-3).
- Produces: the visible toolbar UI. No API surface.

- [ ] **Step 1: Add the picker to the toolbar** — in `QuickCull/ScrubView.swift`, inside the existing `.toolbar { ... }` block, add a new `ToolbarItem` BEFORE the existing commit-button item:

```swift
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Filter", selection: Binding(
                    get: { appState.session?.filter ?? .all },
                    set: { appState.setFilter($0) }
                )) {
                    Text("All").tag(CullFilter.all)
                    Text("Flagged (\(appState.session?.flaggedCount ?? 0))").tag(CullFilter.flagged)
                    Text("Keepers (\(appState.session.map { $0.totalCount - $0.flaggedCount } ?? 0))")
                        .tag(CullFilter.keepers)
                }
                .pickerStyle(.segmented)
                .disabled(appState.isCommitting)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // existing "Move Flagged to Trash" button, unchanged
```

- [ ] **Step 2: Build the app to verify it compiles**

```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Release \
  -derivedDataPath Build/Release build
```

Expected: BUILD SUCCEEDED. (In the DSH harness, add `OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'` as `start.sh` does.)

- [ ] **Step 3: Run the full test suite once more**

```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox" build-for-testing \
  && xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
```

Expected: PASS — all 86 tests.

- [ ] **Step 4: Manual verification** — run `./start.sh`, import a folder of photos, and check:

1. Toolbar shows `All | Flagged (0) | Keepers (N)`; `All` is selected.
2. Flag a few photos with `Z` — counts update live.
3. Select `Flagged` — sequence and filmstrip show only flagged photos; pressing `Z` on the current photo drops it out and auto-advances to the next flagged photo.
4. Unflag the last flagged photo in Flagged mode — filter resets to All, that photo stays current.
5. Select `Keepers` — only unflagged photos; flagging one drops it out and advances.
6. Commit while in Keepers mode — flagged files still go to Trash; the keepers sequence is unchanged and stays current.
7. Commit every flagged photo while in Flagged mode — filter resets to All and scrubbing lands on the first remaining photo.
8. The picker is disabled during the brief committing state.

- [ ] **Step 5: Commit**

```bash
git add QuickCull/ScrubView.swift
git commit -m "feat: segmented All/Flagged/Keepers filter in the scrub toolbar"
```

---

## Self-Review

**Spec coverage:**
- Tri-state filter type + projection → Task 1. Toolbar control (only) → Task 4 (no key map changes anywhere). Current-preservation / nearest-match / tie-forward / empty→reset → Task 1 tests. Auto-advance + empty-reset-by-toggle → Task 2. Commit interplay, `flaggedFiles` from full list, empty-reset-by-commit → Tasks 2-3. Window rebuild vs sync → Task 3. Filmstrip shows only matches → falls out of the projection (no view changes; Task 4 verifies manually). Per-session filter → `Session` is rebuilt per import with `.all` default (Task 1); no cross-session state added.

**Placeholder scan:** no TBD/TODO; every step has exact code or commands.

**Type consistency:** `CullFilter` (CaseIterable/Hashable/Sendable) defined in Task 1, used in `Session.filter`, `setFilter`, `AppState.setFilter`, and `Picker` `.tag` in Task 4. `toggleFlag() -> Bool` defined in Task 2, consumed by AppState in Task 3. `totalCount` defined in Task 1, used in Task 4. `position(of:)` defined in Task 1, reused by `nearestMatchIndex`. `installWindows(for:)`/`syncWindows()` pre-exist and are unchanged.

**Risks checked:** existing `remove` tests (`testRemoveTrashedFilesClearsFlagsAndClampsIndex`, `testRemoveBeforeCurrentShiftsIndex`, `testRemoveBeforeCurrentKeepsPosition`, `testRemoveAllLeavesEmptySession`) are exactly the semantics the reworked `remove` generalizes — verified case-by-case during design; they pin the no-regression guarantee and run in Task 2 Step 6.
