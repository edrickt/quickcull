# New Session Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a New Session toolbar button in Single that always confirms then fully resets the app to the empty import state (wipe cache, clear session/windows/failures/selection, phase=.empty) — the in-app equivalent of quit+relaunch.

**Architecture:** `AppState` gains a single `startNewSession()` method that is the owner of the full-reset sequence (detached `cache.wipe()` like `prepareForLaunch`, nil windows/session, clear failures/selection, `viewMode=.scrub`, `phase=.empty`). `ScrubView` adds the toolbar button + `showNewSessionConfirm` alert that calls it; existing `onChange(phase)` zoom reset and `RootView` phase switch handle the rest. No fileImporter chaining.

**Tech Stack:** Swift 5, SwiftUI Observation (`@Observable`, `@Environment`, `@State`), XCTest, `xcodebuild` + `xcrun xctest` on macOS 14+.

## Global Constraints

- Requires Xcode 16+ on macOS 14+ (README Build).
- Swift language version 5.0, deployment target 14.0.
- No new targets; synchronized folders (no `.pbxproj` edit).
- New Session is toolbar only in ScrubView (visible only while scrubbing), not in EmptyStateView or DecodingView; File > New Session menu out of scope for v1.
- Reset is always confirmed via alert, even when `flaggedCount==0`; button disabled while `isCommitting`.
- Full reset like quit/relaunch: `Task { try? await cache.wipe() }` (detached best-effort, like `prepareForLaunch:47`), `session=nil`, `thumbWindow=nil`, `gridThumbs=nil`, `displayImages=nil`, `importFailures=[]`, `commitFailures=[]`, `pendingCommitCount=0`, `gridSelection=[]`, `gridAnchorID=nil`, `viewMode=.scrub`, `phase=.empty`; zoom resets via existing `ScrubView.onChange(phase)` (already resets on `.empty`).
- Button placed as first `.primaryAction` toolbar item before View picker: order `New Session | Single/Grid | Filter | Trash`.
- Label: `Label("New Session", systemImage: "plus.rectangle")` (spec).
- Build harness flags: every `xcodebuild` needs `CODE_SIGNING_ALLOWED=NO` and `OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'` when run in sandbox; `derivedDataPath /tmp/qc-dd`.

---

## File Structure

```
quickcull/
├── QuickCullCore/App/AppState.swift      # add startNewSession()
├── QuickCull/ScrubView.swift             # add New Session button + alert
└── QuickCullCoreTests/AppStateTests.swift # new tests for reset
```

---

### Task 1: AppState — `startNewSession()` full reset

**Files:**
- Modify: `QuickCullCore/App/AppState.swift:45-55`
- Test: `QuickCullCoreTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `AppState.phase: AppPhase`, `session: Session?`, `thumbWindow/gridThumbs/displayImages: ImageWindow?`, `importFailures: [DecodeOutcome]`, `commitFailures: [TrashOutcome]`, `pendingCommitCount: Int`, `isCommitting: Bool`, `gridSelection: Set<String>`, `gridAnchorID: String?`, `viewMode: ViewMode`, `cache: ImageCacheStore`, `ImageCacheStore.wipe() async throws` (existing).
- Produces: `@MainActor public func startNewSession()` — detached `cache.wipe()`, nils session/windows, clears failures/selection, resets `viewMode=.scrub`, `phase=.empty`; idempotent when already empty.

- [ ] **Step 1: Write the failing test**

Append to `QuickCullCoreTests/AppStateTests.swift` after the last `testStartNewSession` predecessor (or at end of class, before `}`):

```swift
func testStartNewSessionResetsToEmpty() async throws {
    // Setup: import 2 files, flag one, select in grid, create failures
    let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
    let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
    let state = makeState() // helper that injects temp ImageCacheStore, same as existing tests
    state.importFiles(urls: [a, b])
    await waitForScrubbing(state)
    // make non-empty state: flag, filter, grid selection, failures
    state.session?.toggleFlag() // flag current
    state.setFilter(.flagged)
    state.setViewMode(.grid)
    state.selectSingle(id: state.session!.files[0].id)
    state.requestCommit() // pendingCommitCount >0 but not committing
    // Create a marker file in cache to verify wipe is attempted (best-effort)
    let marker = state.cache.baseURL.appendingPathComponent("marker.tmp")
    try Data("x".utf8).write(to: marker)
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

    // Act
    state.startNewSession()
    // Allow detached Task { try? await cache.wipe() } to run
    try await Task.sleep(nanoseconds: 300_000_000) // 0.3s

    // Assert full reset like quit/relaunch
    XCTAssertEqual(state.phase, .empty)
    XCTAssertNil(state.session)
    XCTAssertNil(state.thumbWindow)
    XCTAssertNil(state.gridThumbs)
    XCTAssertNil(state.displayImages)
    XCTAssertTrue(state.importFailures.isEmpty)
    XCTAssertTrue(state.commitFailures.isEmpty)
    XCTAssertEqual(state.pendingCommitCount, 0)
    XCTAssertFalse(state.isCommitting)
    XCTAssertTrue(state.gridSelection.isEmpty)
    XCTAssertEqual(state.viewMode, .scrub)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "cache should be wiped")
}

func testStartNewSessionIsIdempotentWhenAlreadyEmpty() {
    let state = makeState()
    XCTAssertEqual(state.phase, .empty)
    state.startNewSession()
    XCTAssertEqual(state.phase, .empty)
    XCTAssertNil(state.session)
}
```

Note: `makeState()`, `waitForScrubbing(_:)`, `TestFixtures.makeRawFile`, and `tempDir` are existing helpers in `AppStateTests.swift` (see `testViewModeDefaultsScrubAndResetsOnImport` and `makeState()` at top). Reuse them. If `cache.baseURL` is private, use `ImageCacheStore(baseURL: tempDir.appendingPathComponent("cache"))` injected via `makeState(cache:)` helper (create one that takes temp URL).

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build-for-testing && xcrun xctest -XCTest AppStateTests.testStartNewSessionResetsToEmpty /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -20
```
Expected: FAIL with `value of type 'AppState' has no member 'startNewSession'`

- [ ] **Step 3: Implement `startNewSession()`**

In `QuickCullCore/App/AppState.swift` after `prepareForLaunch()` (around line 49), add:

```swift
/// Full reset equivalent to quit+relaunch. Single owner of the empty transition.
/// Always confirmed by ScrubView, so no flag-count guard here.
@MainActor
public func startNewSession() {
    Task { try? await cache.wipe() }
    session = nil
    thumbWindow = nil
    gridThumbs = nil
    displayImages = nil
    importFailures = []
    commitFailures = []
    pendingCommitCount = 0
    isCommitting = false
    gridSelection = []
    gridAnchorID = nil
    viewMode = .scrub
    phase = .empty
}
```

Ensure `@MainActor` (class is `@MainActor`), no `async` needed (detached wipe). If `gridAnchorID` is private, this method can set it because it's inside `AppState`. Keep ordering: nil windows before `phase=.empty` so `RootView` unmounts cleanly.

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build-for-testing && xcrun xctest -XCTest AppStateTests /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -20
```
Expected: PASS — both new tests + 108 baseline (now 110).

- [ ] **Step 5: Commit**

```bash
git add QuickCullCore/App/AppState.swift QuickCullCoreTests/AppStateTests.swift
git commit -m "feat: app state startNewSession full reset like quit/relaunch"
```

---

### Task 2: ScrubView — New Session toolbar button with always-confirm

**Files:**
- Modify: `QuickCull/ScrubView.swift:4-32`

**Interfaces:**
- Consumes: `AppState.startNewSession()`, `AppState.isCommitting: Bool`, `AppState.phase: AppPhase`, existing toolbar pickers/buttons.
- Produces: Toolbar `New Session` button + `showNewSessionConfirm` alert; disabled while committing; always confirms.

- [ ] **Step 1: Add state for alert**

Edit `QuickCull/ScrubView.swift:4-8` (inside `ScrubView` struct, after `showCommitFailures`):

```swift
@State private var showNewSessionConfirm = false
```

- [ ] **Step 2: Add New Session button as first toolbar item**

Edit `QuickCull/ScrubView.swift:33-58` (inside `.toolbar`):

```swift
.toolbar {
    ToolbarItem(placement: .primaryAction) {
        Button { showNewSessionConfirm = true } label: {
            Label("New Session", systemImage: "plus.rectangle")
        }
        .disabled(appState.isCommitting)
    }
    ToolbarItem(placement: .primaryAction) {
        Picker("View", selection: Binding(
            get: { appState.viewMode },
            set: { appState.setViewMode($0) }
        )) {
            Text("Single").tag(AppState.ViewMode.scrub)
            Text("Grid").tag(AppState.ViewMode.grid)
        }.pickerStyle(.segmented).disabled(appState.isCommitting)
    }
    // existing Filter and Trash items follow unchanged
}
```

Order must be `New Session | Single/Grid | Filter | Trash`. Keep existing `Trash` button `disabled(appState.session?.flaggedCount==0 || appState.isCommitting)` and `Filter`/`View` disabled while committing.

- [ ] **Step 3: Add always-confirm alert**

After the existing `commitFailures` alert (around line 84, after `.onChange(of: appState.commitFailures.count)`), add:

```swift
.alert("Start new session?", isPresented: $showNewSessionConfirm) {
    Button("Start New Session", role: .destructive) { appState.startNewSession() }
    Button("Cancel", role: .cancel) { }
} message: {
    Text("Current session — including flagged photos — will be discarded. The decode cache will be cleared.")
}
```

No flag-count condition — always shows, per spec. Button role `.destructive` matches spec.

- [ ] **Step 4: Build the app**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manual verify New Session flow**

Run `./start.sh`, import set, flag 1, zoom 200%, switch to Grid with selection, then in Single click `New Session`:
- Alert always appears (even with 0 flagged) with `Start New Session` destructive + `Cancel`.
- `Cancel` → still scrubbing, flag/selection/zoom retained.
- `New Session` → `EmptyStateView` (Choose RAW Files), no banners, `phase==.empty`, cache dir empty (`ls ~/Library/Application\ Support/QuickCull/cache` empty), zoom reset to fit (via existing `onChange(phase)`), grid selection cleared.
- While `Trash` spinner (`isCommitting`), `New Session` disabled.

- [ ] **Step 6: Run tests (no regression)**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build-for-testing && xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -5
```
Expected: `Executed 110 tests, with 0 failures` (or 108→110).

- [ ] **Step 7: Commit**

```bash
git add QuickCull/ScrubView.swift
git commit -m "feat: new session button in scrub toolbar with always-confirm full reset"
```

---

## Self-Review

**Spec coverage:**
- Toolbar in ScrubView only (not Empty/Decoding), first primaryAction item before View → Task 2 Steps 2+3.
- Always confirm (even 0 flags) with destructive alert → Task 2 Step 3.
- Full reset like quit/relaunch (detached `cache.wipe()`, nil session/windows, clear failures/selection, `viewMode=.scrub`, `phase=.empty`, `isCommitting=false`) → Task 1 Step 3.
- Zoom reset via existing `onChange(phase)` (already in `ScrubView.swift:90`) — no new code needed, verified via Task 1 phase change.
- Disabled while committing → Task 2 Step 2 `.disabled(appState.isCommitting)`.
- No menu/fileImporter chaining (out of scope) — not built.

**Placeholder scan:** No TBD/TODO; every step has exact file paths, code blocks, and commands.

**Type consistency:** `public func startNewSession()` defined Task 1, consumed `appState.startNewSession()` Task 2; `AppPhase.empty`/`decoding` comparison uses `isDecoding` helper already in ScrubView; `ImageCacheStore.wipe()` async throws matches `Task { try? await }` usage; toolbar `Label("New Session", systemImage:"plus.rectangle")` string matches spec.
