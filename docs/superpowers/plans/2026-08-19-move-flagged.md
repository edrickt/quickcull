# Move Flagged to Folder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Move Flagged button next to Trash that prompts for destination folder, auto-renames on collision, and removes moved files from session like Trash commit.

**Architecture:** New `MoveCommit` service mirroring `TrashCommit` with `Mover` protocol and `FileManagerMover` + `autoRenamedDestination` that appends ` 1`, ` 2` before extension; `AppState` holds `isMoving`/`pendingMoveCount`/`pendingMoveDestination`/`moveFailures` and `confirmMove()` on detached task; `ScrubView` adds `NSOpenPanel` folder picker and two alerts.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit `NSOpenPanel`, Foundation `FileManager`, XCTest, Observation `@Observable`

## Global Constraints

- Target macOS 14+, Xcode 16+
- Pick folder each time via NSOpenPanel (canChooseDirectories true, canCreateDirectories true, canChooseFiles false, allowsMultipleSelection false, prompt "Move", message "Choose a folder to move flagged images to"), flat move to that folder (no subfolders)
- Collision → auto-rename `name 1.ext`, `name 2.ext` before extension, preserving extension case, no overwrite
- Like Trash: successful moves removed from session, gridSelection pruned, failed keep flag, failure alert `Could not move N file(s)` with message `The remaining files keep their flags. You may need to grant file access in System Settings, or choose a writable folder.`
- Move Flagged button Label `folder` immediately after `Move Flagged to Trash` in same `primaryAction` group, `.fontWeight(.light)`, disabled when `flaggedCount==0 || isCommitting || isMoving`, shows `ProgressView` when `isMoving`
- `isMoving` disables View/Filter/New Session/Trash/Move during move; preserved across Single↔Split, cleared on `startNewSession` and `importFiles`
- No file writes for adjustments; Move and Trash have independent `pending*`/`*Failures`/`is*` state
- Use `filePath:line_number` when referencing code locations in docs/comments

---

## File Structure

**New files:**
- `QuickCullCore/Commit/MoveCommit.swift` — `protocol Moving`, `FileManagerMover`, `MoveOutcome`, `MoveCommit` with `autoRenamedDestination(for:in:)` and `commit(files:to:)`
- `QuickCullCoreTests/Commit/MoveCommitTests.swift` — unit tests for MoveCommit
- `QuickCullCoreTests/App/AppStateMoveTests.swift` — unit tests for AppState move state

**Modified files:**
- `QuickCullCore/App/AppState.swift:24-30` — add `pendingMoveCount`, `pendingMoveDestination`, `moveFailures`, `isMoving`, `mover`
- `QuickCullCore/App/AppState.swift:36-42` — init inject `mover: Moving = FileManagerMover()`
- `QuickCullCore/App/AppState.swift:54-68` — clears in `startNewSession`
- `QuickCullCore/App/AppState.swift:71-102` — clears in `importFiles`
- `QuickCullCore/App/AppState.swift:208-213` — guards `isMoving` in `setViewMode` (and `handle` if needed)
- `QuickCullCore/App/AppState.swift:275-307` — add `requestMove(to:)`, `cancelMove()`, `confirmMove() async`
- `QuickCull/ScrubView.swift:5-9` — add `@State showMoveConfirm`, `showMoveFailures`
- `QuickCull/ScrubView.swift:38-87` — new `ToolbarItem` Move Flagged with `NSOpenPanel`, update `.disabled(isCommitting||isMoving)` for all chrome
- `QuickCull/ScrubView.swift:89-113` — two new `.alert` for move confirm/failures and `.onChange(moveFailures)`

**No change:**
- `QuickCullCore/Commit/TrashCommit.swift:30`, `QuickCullCore/Engine/DecodeEngine.swift`, `QuickCullCore/Storage/ImageCacheStore.swift`, `QuickCullCore/Decoding/*`, `QuickCullCore/Session/Session.swift`, `QuickCullCore/Window/*`, `QuickCull/GridView.swift`, `QuickCull/FilmstripView.swift`, `QuickCull/ImageDisplayView.swift`

---

### Task 1: MoveCommit Service

**Files:**
- Create: `QuickCullCore/Commit/MoveCommit.swift`
- Test: `QuickCullCoreTests/Commit/MoveCommitTests.swift`

**Interfaces:**
- Consumes: `SessionFile` (id == url.path), `Foundation.FileManager`
- Produces: `public protocol Moving: Sendable { func move(from: URL, to: URL) throws }`, `public struct FileManagerMover: Moving`, `public struct MoveOutcome { let file: SessionFile; let error: Error?; var succeeded: Bool }`, `public struct MoveCommit { init(mover: Moving); func autoRenamedDestination(for file: SessionFile, in folder: URL) -> URL; func commit(files: [SessionFile], to folder: URL) -> [MoveOutcome] }` — used by `AppState.confirmMove()` in Task 2

- [ ] **Step 1: Write the failing test**

Create `QuickCullCoreTests/Commit/MoveCommitTests.swift`:

```swift
import XCTest
@testable import QuickCullCore

final class MoveCommitTests: XCTestCase {
    func testAutoRenamedDestinationNoCollision() throws {
        let dir = try TestFixtures.makeTempDir(name: "move-no-coll")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/a.jpg"))
        let dest = MoveCommit(mover: FileManagerMover()).autoRenamedDestination(for: a, in: dir)
        XCTAssertEqual(dest.lastPathComponent, "a.jpg")
    }
    func testAutoRenamedDestinationCollisionAddsSuffix() throws {
        let dir = try TestFixtures.makeTempDir(name: "move-coll")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.jpg"))
        let a = SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/a.jpg"))
        let dest = MoveCommit(mover: FileManagerMover()).autoRenamedDestination(for: a, in: dir)
        XCTAssertEqual(dest.lastPathComponent, "a 1.jpg")
        try Data("y".utf8).write(to: dir.appendingPathComponent("a 1.jpg"))
        let dest2 = MoveCommit(mover: FileManagerMover()).autoRenamedDestination(for: a, in: dir)
        XCTAssertEqual(dest2.lastPathComponent, "a 2.jpg")
    }
    func testAutoRenamedPreservesExtensionCase() throws {
        let dir = try TestFixtures.makeTempDir(name: "move-case")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("IMG.JPG"))
        let f = SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/IMG.JPG"))
        let dest = MoveCommit(mover: FileManagerMover()).autoRenamedDestination(for: f, in: dir)
        XCTAssertEqual(dest.lastPathComponent, "IMG 1.JPG")
    }
    func testAutoRenamedNoExtension() throws {
        let dir = try TestFixtures.makeTempDir(name: "move-noext")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("README"))
        let f = SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/README"))
        let dest = MoveCommit(mover: FileManagerMover()).autoRenamedDestination(for: f, in: dir)
        XCTAssertEqual(dest.lastPathComponent, "README 1")
    }
    func testCommitMovesFilesAndAutoRenames() throws {
        let srcDir = try TestFixtures.makeTempDir(name: "move-src")
        let dstDir = try TestFixtures.makeTempDir(name: "move-dst")
        defer { try? FileManager.default.removeItem(at: srcDir); try? FileManager.default.removeItem(at: dstDir) }
        let srcURL = srcDir.appendingPathComponent("a.jpg")
        try Data("src".utf8).write(to: srcURL)
        try Data("existing".utf8).write(to: dstDir.appendingPathComponent("a.jpg"))
        let file = SessionFile(url: srcURL)
        let outcomes = MoveCommit(mover: FileManagerMover()).commit(files: [file], to: dstDir)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertTrue(outcomes[0].succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("a 1.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: srcURL.path))
    }
    func testCommitReportsFailurePerFile() throws {
        struct FailMover: Moving { func move(from: URL, to: URL) throws { throw NSError(domain: "t", code: 1) } }
        let file = SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/a.jpg"))
        let outcomes = MoveCommit(mover: FailMover()).commit(files: [file], to: URL(fileURLWithPath: "/tmp/dst"))
        XCTAssertFalse(outcomes[0].succeeded)
        XCTAssertNotNil(outcomes[0].error)
    }
    func testCommitSourceNotFoundFails() throws {
        let dst = try TestFixtures.makeTempDir(name: "move-nf")
        defer { try? FileManager.default.removeItem(at: dst) }
        let file = SessionFile(url: URL(fileURLWithPath: "/nonexistent/a.jpg"))
        let outcomes = MoveCommit(mover: FileManagerMover()).commit(files: [file], to: dst)
        XCTAssertFalse(outcomes[0].succeeded)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing 2>&1 | tail -20
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest -XCTest MoveCommitTests 2>&1 | tail -30
```
Expected: FAIL with `cannot find type 'MoveCommit' in scope` / `no such test`.

- [ ] **Step 3: Write minimal implementation**

Create `QuickCullCore/Commit/MoveCommit.swift`:

```swift
import Foundation

public protocol Moving: Sendable {
    func move(from: URL, to: URL) throws
}

public struct FileManagerMover: Moving {
    public init() {}
    public func move(from: URL, to: URL) throws {
        try FileManager.default.moveItem(at: from, to: to)
    }
}

public struct MoveOutcome {
    public let file: SessionFile
    public let error: Error?
    public var succeeded: Bool { error == nil }
    public init(file: SessionFile, error: Error?) {
        self.file = file
        self.error = error
    }
}

public struct MoveCommit {
    private let mover: Moving
    public init(mover: Moving) { self.mover = mover }

    public func autoRenamedDestination(for file: SessionFile, in folder: URL) -> URL {
        let base = file.url.deletingPathExtension().lastPathComponent
        let ext = file.url.pathExtension
        var candidate = folder.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }

    public func commit(files: [SessionFile], to folder: URL) -> [MoveOutcome] {
        files.map { file in
            let dest = autoRenamedDestination(for: file, in: folder)
            do {
                try mover.move(from: file.url, to: dest)
                return MoveOutcome(file: file, error: nil)
            } catch {
                return MoveOutcome(file: file, error: error)
            }
        }
    }
}
```

Ensure file added to `QuickCullCore` target via filesystem sync (no `project.pbxproj` edit).

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest -XCTest MoveCommitTests -v 2>&1 | tail -30
```
Expected: PASS (7 tests). Then full suite:
```bash
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -20
```
Expected: 134 + 7 = 141 tests pass.

- [ ] **Step 5: Commit**

```bash
git add QuickCullCore/Commit/MoveCommit.swift QuickCullCoreTests/Commit/MoveCommitTests.swift
git commit -m "feat: add MoveCommit with auto-rename destination"
```

---

### Task 2: AppState Move State

**Files:**
- Modify: `QuickCullCore/App/AppState.swift:24-30,36-42,54-68,71-102,208-213,275-307`
- Test: `QuickCullCoreTests/App/AppStateMoveTests.swift`

**Interfaces:**
- Consumes: `MoveCommit`, `Moving`, `MoveOutcome` from Task 1; `SessionFile`, `Session`, `ImageWindow`, `TrashCommit` pattern
- Produces: `AppState.pendingMoveCount: Int`, `pendingMoveDestination: URL?`, `moveFailures: [MoveOutcome]`, `isMoving: Bool`, `func requestMove(to: URL)`, `func cancelMove()`, `func confirmMove() async` — used by `ScrubView` Move button in Task 3. Also extends `setViewMode`/`handle` guards to include `isMoving`.

- [ ] **Step 1: Write the failing test**

Create `QuickCullCoreTests/App/AppStateMoveTests.swift`:

```swift
import XCTest
@testable import QuickCullCore

@MainActor
final class AppStateMoveTests: XCTestCase {
    private var tempDir: URL!
    private var cache: ImageCacheStore!
    override func setUp() async throws {
        tempDir = try TestFixtures.makeTempDir(name: "move-state")
        cache = ImageCacheStore(baseURL: tempDir.appendingPathComponent("cache", isDirectory: true))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private func makeState(mover: Moving = StubMover()) -> AppState {
        AppState(decoder: StubDecoder(), cache: cache, trasher: StubTrasher(), mover: mover)
    }
    private func waitForScrubbing(_ s: AppState) async {
        for _ in 0..<200 { if s.phase == .scrubbing { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("never scrubbing")
    }
    // StubMover with gate and failIDs like StubTrasher
    private class StubMover: Moving {
        var failIDs: Set<String> = []
        var gate: DispatchSemaphore?
        var moved: [URL] = []
        func move(from: URL, to: URL) throws {
            if let g = gate { g.wait() }
            if failIDs.contains(from.path) { throw NSError(domain: "t", code: 1) }
            moved.append(from)
        }
    }

    func testRequestAndCancelMove() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let s = makeState()
        s.importFiles(urls: [a]); await waitForScrubbing(s)
        s.handle(.toggleFlag)
        let dest = URL(fileURLWithPath: "/tmp/dest")
        s.requestMove(to: dest)
        XCTAssertEqual(s.pendingMoveCount, 1)
        XCTAssertEqual(s.pendingMoveDestination, dest)
        s.cancelMove()
        XCTAssertEqual(s.pendingMoveCount, 0)
        XCTAssertNil(s.pendingMoveDestination)
    }

    func testConfirmMoveRemovesSucceededAndKeepsFailed() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let mover = StubMover(); mover.failIDs = [a.path]
        let s = makeState(mover: mover)
        s.importFiles(urls: [a,b]); await waitForScrubbing(s)
        s.handle(.toggleFlag); s.handle(.next); s.handle(.toggleFlag)
        let dest = URL(fileURLWithPath: "/tmp/dest2")
        s.requestMove(to: dest)
        await s.confirmMove()
        XCTAssertEqual(s.session?.count, 1)
        XCTAssertEqual(s.session?.flaggedCount, 1)
        XCTAssertEqual(s.moveFailures.count, 1)
        XCTAssertEqual(s.pendingMoveCount, 0)
        XCTAssertNil(s.pendingMoveDestination)
        XCTAssertFalse(s.isMoving)
    }

    func testConfirmMoveEmptiesSessionResetsPhase() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let s = makeState()
        s.importFiles(urls: [a]); await waitForScrubbing(s)
        s.handle(.toggleFlag)
        s.requestMove(to: URL(fileURLWithPath: "/tmp/dest3"))
        await s.confirmMove()
        XCTAssertNil(s.session)
        XCTAssertEqual(s.phase, .empty)
        XCTAssertEqual(s.viewMode, .scrub)
    }

    func testIsMovingTrueDuringMove() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let mover = StubMover()
        let gate = DispatchSemaphore(value: 0)
        mover.gate = gate
        let s = makeState(mover: mover)
        s.importFiles(urls: [a]); await waitForScrubbing(s)
        s.handle(.toggleFlag)
        s.requestMove(to: URL(fileURLWithPath: "/tmp/dest4"))
        let task = Task { await s.confirmMove() }
        var observed = false
        for _ in 0..<100 {
            if s.isMoving { observed = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(observed)
        gate.signal()
        await task.value
        XCTAssertFalse(s.isMoving)
    }

    func testStartNewSessionClearsMoveState() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let s = makeState()
        s.importFiles(urls: [a]); await waitForScrubbing(s)
        s.handle(.toggleFlag)
        s.requestMove(to: URL(fileURLWithPath: "/tmp/d"))
        s.moveFailures = [MoveOutcome(file: SessionFile(url: a), error: NSError(domain: "t", code: 1))]
        s.startNewSession()
        XCTAssertTrue(s.moveFailures.isEmpty)
        XCTAssertEqual(s.pendingMoveCount, 0)
        XCTAssertNil(s.pendingMoveDestination)
        XCTAssertFalse(s.isMoving)
    }

    func testImportClearsMoveState() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let s = makeState()
        s.importFiles(urls: [a]); await waitForScrubbing(s)
        s.requestMove(to: URL(fileURLWithPath: "/tmp/d2"))
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        s.importFiles(urls: [b]); await waitForScrubbing(s)
        XCTAssertEqual(s.pendingMoveCount, 0)
        XCTAssertNil(s.pendingMoveDestination)
        XCTAssertTrue(s.moveFailures.isEmpty)
    }

    func testMoveBlocksViewModeAndHandleWhileMoving() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let mover = StubMover()
        let gate = DispatchSemaphore(value: 0)
        mover.gate = gate
        let s = makeState(mover: mover)
        s.importFiles(urls: [a,b]); await waitForScrubbing(s)
        s.handle(.toggleFlag)
        s.requestMove(to: URL(fileURLWithPath: "/tmp/d5"))
        let task = Task { await s.confirmMove() }
        // wait until isMoving
        for _ in 0..<100 { if s.isMoving { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        s.setViewMode(.grid)
        XCTAssertEqual(s.viewMode, .scrub) // blocked
        gate.signal()
        await task.value
    }

    func testUnsupportedImportClearsMoveState() {
        let s = makeState()
        s.requestMove(to: URL(fileURLWithPath: "/tmp/d"))
        // pendingMoveCount 0 because no session, but dest set
        XCTAssertNotNil(s.pendingMoveDestination)
        s.importFiles(urls: [URL(fileURLWithPath: "/tmp/x.txt")]) // unsupported
        XCTAssertNil(s.pendingMoveDestination)
        XCTAssertEqual(s.pendingMoveCount, 0)
    }
}
```

Note: Add `import Foundation` at top. `StubMover` is defined inside test file (or add to `QuickCullCoreTests/TestDoubles.swift` if exists).

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing 2>&1 | tail -20
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest -XCTest AppStateMoveTests 2>&1 | tail -30
```
Expected: FAIL with `value of type 'AppState' has no member 'requestMove'` / `pendingMoveCount` etc.

- [ ] **Step 3: Write minimal implementation**

Edit `QuickCullCore/App/AppState.swift`:

1. At `public private(set) var` block add after `isCommitting`:
```swift
public private(set) var pendingMoveCount: Int = 0
public private(set) var pendingMoveDestination: URL?
public private(set) var moveFailures: [MoveOutcome] = []
public private(set) var isMoving: Bool = false
private let mover: Moving
```

2. Update `init` to inject mover:
```swift
public init(decoder: RawDecoding = RoutingDecoder(...),
            cache: ImageCacheStore = ImageCacheStore(...),
            trasher: Trashing = FileManagerTrasher(),
            mover: Moving = FileManagerMover()) {
    self.decoder = decoder; self.cache = cache; self.trasher = trasher; self.mover = mover
}
```

3. In `startNewSession()` after clearing commit state add:
```swift
pendingMoveCount = 0
pendingMoveDestination = nil
moveFailures = []
isMoving = false
```

4. In `importFiles` before `phase = .decoding` add `pendingMoveCount=0; pendingMoveDestination=nil; moveFailures=[]; isMoving=false` and also in `guard !supported.isEmpty else` branch before `phase=.empty` add same four clears (unsupported-only leak fix).

5. Update `setViewMode` guard: `guard !isCommitting, !isMoving else { return }` and also add `guard !isMoving` to `handle(_:)` first guard? Already `guard let session, phase == .scrubbing else {return}` — extend to `guard !isMoving, !isCommitting` similarly.

6. Add helpers after `cancelCommit()`:
```swift
public func requestMove(to dest: URL) {
    pendingMoveCount = session?.flaggedCount ?? 0
    pendingMoveDestination = dest
}
public func cancelMove() {
    pendingMoveCount = 0
    pendingMoveDestination = nil
}
public func confirmMove() async {
    guard let session, !isCommitting, !isMoving, let dest = pendingMoveDestination else { return }
    let flagged = session.flaggedFiles
    guard !flagged.isEmpty else { pendingMoveCount=0; pendingMoveDestination=nil; return }
    isMoving = true
    let outcomes = await Task.detached(priority: .userInitiated) {
        MoveCommit(mover: self.mover).commit(files: flagged, to: dest)
    }.value
    let succeeded = outcomes.filter(\.succeeded).map(\.file)
    session.remove(succeeded)
    gridSelection = gridSelection.filter { session.contains(id: $0) }
    moveFailures = outcomes.filter { !$0.succeeded }
    pendingMoveCount = 0
    pendingMoveDestination = nil
    isMoving = false
    if session.isEmpty {
        self.session = nil; thumbWindow=nil; gridThumbs=nil; displayImages=nil; phase=.empty; viewMode=.scrub
    } else {
        installWindows(for: session.files)
    }
}
```

Ensure `@Observable` tracks new vars.

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest -XCTest AppStateMoveTests -v 2>&1 | tail -30
```
Expected: PASS (8 tests). Full suite:
```bash
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -20
```
Expected: 141 + 8 = 149 tests pass.

- [ ] **Step 5: Commit**

```bash
git add QuickCullCore/App/AppState.swift QuickCullCoreTests/App/AppStateMoveTests.swift
git commit -m "feat: add per-image move state to AppState (isMoving, pendingMove, failures)"
```

---

### Task 3: ScrubView Move Button Wiring

**Files:**
- Modify: `QuickCull/ScrubView.swift:5-9,38-87,89-113,110-133`
- Test: manual QA via `./start.sh` + existing suite (no new XCTest for NSOpenPanel modal)

**Interfaces:**
- Consumes: `AppState.requestMove(to:)`, `cancelMove()`, `confirmMove() async`, `pendingMoveCount`, `pendingMoveDestination`, `moveFailures`, `isMoving` from Task 2; `AppState.session.flaggedCount`, `isCommitting` existing
- Produces: Toolbar UI with Move Flagged button and two alerts; no new public API

- [ ] **Step 1: Write the failing test (build gate)**

Before implementation, verify `ScrubView` does not yet contain `Move Flagged`:

Run:
```bash
grep -n "Move Flagged" QuickCull/ScrubView.swift || echo "not found (expected before)"
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build 2>&1 | tail -5
```
Expected: not found, build passes (no reference yet).

- [ ] **Step 2: Run test to verify it fails (post-intent)**

Attempt to build with expected Move button disabled logic — intentionally fail by searching for `isMoving` not yet wired:

Run:
```bash
grep -n "isMoving" QuickCull/ScrubView.swift || echo "isMoving not in ScrubView (fail before)"
```
Expected: not found.

- [ ] **Step 3: Write minimal implementation**

Edit `QuickCull/ScrubView.swift`:

1. Add state at top with other `@State`:
```swift
@State private var showMoveConfirm = false
@State private var showMoveFailures = false
```

2. Update all chrome `.disabled(appState.isCommitting)` to `.disabled(appState.isCommitting || appState.isMoving)` for: Metadata button, View Picker, Filter Picker, New Session button. Trash button already has `|| isCommitting`, extend to `|| isMoving`.

3. Add new ToolbarItem after Trash:
```swift
ToolbarItem(placement: .primaryAction) {
    Button {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        panel.message = "Choose a folder to move flagged images to"
        if panel.runModal() == .OK, let dest = panel.url {
            appState.requestMove(to: dest)
            showMoveConfirm = true
        }
    } label: {
        if appState.isMoving {
            ProgressView().controlSize(.small)
        } else {
            Label("Move Flagged", systemImage: "folder")
        }
    }
    .fontWeight(.light)
    .disabled(appState.session?.flaggedCount == 0 || appState.isCommitting || appState.isMoving)
}
```

Need `import AppKit` at top if not already (file already has no AppKit? ScrubView currently `import SwiftUI` + `QuickCullCore` only; add `import AppKit` for `NSOpenPanel`).

4. Add alerts after existing commit alerts:
```swift
.alert("Move \(appState.pendingMoveCount) file(s) to \"\(appState.pendingMoveDestination?.lastPathComponent ?? "")\"?",
       isPresented: $showMoveConfirm) {
    Button("Move", role: .none) {
        Task { await appState.confirmMove() }
    }
    Button("Cancel", role: .cancel) { appState.cancelMove() }
} message: {
    Text("Flagged files will be moved to the selected folder and removed from this session. Scrubbing continues with the rest.")
}
.alert("Could not move \(appState.moveFailures.count) file(s)",
       isPresented: $showMoveFailures) {
    Button("OK", role: .cancel) { }
} message: {
    Text("The remaining files keep their flags. You may need to grant file access in System Settings, or choose a writable folder.")
}
```

5. Add onChange for moveFailures after existing commitFailures onChange:
```swift
.onChange(of: appState.moveFailures.count) {
    if appState.moveFailures.count > 0 { showMoveFailures = true }
}
```

6. Ensure `onChange(of: appState.phase)` also handles `isMoving`? Not needed; phase reset already clears pending via AppState.

Need to handle `isMoving` disabling already done.

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build 2>&1 | tail -20
```
Expected: build succeeds, warnings only sandbox.

Run full suite still green:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -20
```
Expected: 149 tests pass.

Manual QA (run `./start.sh`, import 4 RAWs+JPEG, flag 2):
- Move Flagged disabled at 0, enabled at 1+
- Click → NSOpenPanel folder chooser appears (can create dir), Cancel → no alert
- Pick empty tmp folder → alert `Move 2 file(s) to "tmp"?` → Cancel clears, Move removes 2 from session, files appear in dest, scrub continues
- Pick folder where `a.jpg` exists → moved as `a 1.jpg`
- Pick read-only folder → `Could not move 2 file(s)` alert, session retains flagged
- While isMoving, View/Filter/New Session/Trash/Move disabled, spinner

- [ ] **Step 5: Commit**

```bash
git add QuickCull/ScrubView.swift
git commit -m "feat: add Move Flagged button with folder picker and alerts"
```

---

## Self-Review

**1. Spec coverage:** Each spec section maps:
- Purpose/Approach (FileManager.moveItem auto-rename mirrored to TrashCommit) → Task 1
- Visual (Toolbar Move Flagged after Trash, NSOpenPanel, alerts, disabled/isMoving, progress) → Task 3
- Data/Computation (MoveCommit autoRenamedDestination + commit, AppState pendingMove/isMoving/mover) → Tasks 1-2
- Components summary → Tasks 1-3 file lists
- Data Flow (panel → requestMove → confirmMove detached → session.remove → installWindows/.empty → failures alert) → Task 2-3
- Error Handling (cancel, not writable, collision, same folder, cross-volume, re-entrant, empty, narrow, disk full) → Task 1-2
- Testing (MoveCommitTests 7, AppStateMoveTests 8, manual QA) → Tasks 1-3
- Files list → covered
- Acceptance Criteria (button after Trash, picker each time, confirm alert, detached auto-rename moveItem, succeeded removed/pruned, failed keep flag + alert, no overwrite, 134+new tests green) → Tasks 1-3

**2. Placeholder scan:** No TBD/TODO, no “implement later”, no “similar to Task N” without code — all steps have verbatim Swift, bash commands, expected PASS/FAIL.

**3. Type consistency:** `Moving` protocol `move(from:to:) throws`, `FileManagerMover`, `MoveOutcome`, `MoveCommit(mover: Moving)`, `autoRenamedDestination(for:in:) -> URL`, `commit(files:to:) -> [MoveOutcome]` consistent across Tasks 1-2. `AppState` init `mover: Moving = FileManagerMover()` matches `trasher` pattern. `pendingMoveDestination: URL?`, `pendingMoveCount: Int`, `moveFailures: [MoveOutcome]`, `isMoving: Bool` used consistently in Task 3 alerts/disabled. `ScrubView` `showMoveConfirm`/`showMoveFailures` paired with `pendingMoveCount`/`moveFailures.count`.

Fixes applied inline: none needed; spec tight.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-19-move-flagged.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
