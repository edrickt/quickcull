# Tricolor Flags (Z Red, X Yellow, C Green) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace single red flag with exclusive three-color flags (Z red, X yellow, C green), 5-way filter, and per-color Trash/Move menus that remove only chosen color (or all flagged).

**Architecture:** New `FlagColor` enum + `flags: [String: FlagColor]` dict in `Session` (exclusive via single dict, missing=unflagged); `CullFilter` expands to `all/red/yellow/green/keepers`; `CullKeyMap` maps Z/X/C to `toggleFlag(FlagColor)`; `AppState` stores `pendingCommitColor`/`pendingMoveColor` and calls `session.flaggedFiles(color:)`; `FlagBadge` tints by color; `ScrubView` 5-segment filter + two `Menu` with live counts.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit `NSOpenPanel`, Observation `@Observable`, XCTest, `SessionFile` `id == url.path`

## Global Constraints

- Target macOS 14+, Xcode 16+
- Exclusive single color per photo; same key toggles off to unflagged; different key replaces color (Z on red → red off, X on red → yellow)
- Z keyCode 6 → red, X keyCode 7 → yellow, C keyCode 8 → green
- Filter 5 segments: All, Red (count), Yellow (count), Green (count), Unflagged (keepers) with live counts; `keepers` = unflagged; aggregate flagged only via Menu All Flagged (nil color), not filter
- FlagBadge same triangle shape (`FlagBadge.swift:18` `CornerTriangle`), fill `.red`/`.yellow`/`.green`, size 32/44, shadow `black.opacity(0.35) radius 1.5`
- Trash and Move each `Menu` with 4 items: Red / Yellow / Green / All Flagged, per-item disabled when target count==0 or isCommitting/isMoving, Menu disabled while isCommitting/isMoving; shows count in label e.g. `Trash Red (2)`
- Move flat to folder, auto-rename `name 1.ext` etc preserving extension case (from MoveCommit), no overwrite
- Pending colors: `pendingCommitColor: FlagColor?`, `pendingMoveColor: FlagColor?`, `pendingMoveDestination: URL?`, nil = all flagged
- No disk persistence; flags in-memory per session, cleared on `startNewSession`/`importFiles` (like today), also cleared on `session.remove`
- Use `filePath:line_number` when referencing code locations in docs/comments

---

## File Structure

**New files:**
- `QuickCullCore/Session/FlagColor.swift` — `enum FlagColor: String, CaseIterable, Sendable, Codable, Hashable { red, yellow, green }` with `displayName`, `keyCode`, `swiftUIColor`
- `QuickCullCoreTests/Session/FlagColorTests.swift` — trivial enum tests (optional, may fold into SessionTests)
- `QuickCullCoreTests/Session/TricolorSessionTests.swift` — exclusive, projection, counts (or extend existing `SessionTests.swift`)

**Modified files:**
- `QuickCullCore/Session/CullFilter.swift:4` — `all, red, yellow, green, keepers` (remove `flagged`)
- `QuickCullCore/Session/Session.swift:13-239` — `flags:[String:FlagColor]`, computed `flagged`, `flagColor(for:)`, `flaggedCount(_:)`, `flaggedFiles(_:)`, `matches`, `toggleFlag(color:)`, `toggleFlags(ids:color:)`, `remove`
- `QuickCullCore/Keys/CullKeyMap.swift:9,19` — `CullAction.toggleFlag(FlagColor)`, `xKey/cKey`, mapping
- `QuickCullCore/Models/FlagBadgeLogic.swift:6` — keep `shouldShow`, callers pass `flagColor != nil`
- `QuickCull/FlagBadge.swift:6` — `init(color: FlagColor, size:)` tint
- `QuickCullCore/App/AppState.swift:27-360` — `pendingCommitColor`, `pendingMoveColor`, `requestCommit(color:)`, `requestMove(to:color:)`, `confirmCommit/confirmMove` per-color, helper counts `flaggedCount(color:)`
- `QuickCull/ScrubView.swift:58,77,91,130` — 5-segment Filter, two Menu with per-color counts/disabled, alerts with color text
- `QuickCull/ImageDisplayView.swift:55`, `QuickCull/FilmstripView.swift`, `QuickCull/GridView.swift`, `QuickCull/BadgedThumbnailView.swift` — resolve `flagColor` → `FlagBadge(color:)`
- Tests: `QuickCullCoreTests/Keys/CullKeyMapTests.swift`, `QuickCullCoreTests/FlagBadgeLogicTests.swift`, `QuickCullCoreTests/Session/SessionTests.swift`, `QuickCullCoreTests/App/AppStateTests.swift`, `QuickCullCoreTests/App/AppStateMoveTests.swift`

**No change:**
- `QuickCullCore/Commit/TrashCommit.swift:30`, `QuickCullCore/Commit/MoveCommit.swift:41`, `QuickCullCore/Engine/DecodeEngine.swift`, `QuickCullCore/Storage/ImageCacheStore.swift`, `QuickCullCore/Window/*`

---

### Task 1: Core Model — FlagColor, CullFilter, Session Flags

**Files:**
- Create: `QuickCullCore/Session/FlagColor.swift`
- Modify: `QuickCullCore/Session/CullFilter.swift:4`, `QuickCullCore/Session/Session.swift:13-239`
- Test: `QuickCullCoreTests/Session/SessionTests.swift` (or new `TricolorSessionTests.swift`)

**Interfaces:**
- Consumes: `SessionFile.id: String`, `CullFilter`, `Foundation`
- Produces: `public enum FlagColor: String, CaseIterable, Sendable, Codable, Hashable { case red, yellow, green }` with `displayName`, `keyCode`; `public enum CullFilter: CaseIterable, Hashable, Sendable { case all, red, yellow, green, keepers }`; `Session` API `var flags: [String: FlagColor]`, `var flagged: Set<String>`, `func flagColor(for file: SessionFile) -> FlagColor?`, `func flagColor(for id: String) -> FlagColor?`, `func flaggedCount(_ color: FlagColor? = nil) -> Int`, `func flaggedFiles(_ color: FlagColor? = nil) -> [SessionFile]`, `func isFlagged(_ file: SessionFile) -> Bool`, `func isFlagged(_ file: SessionFile, color: FlagColor) -> Bool`, `func toggleFlag(color: FlagColor) -> Bool`, `func toggleFlags(ids: Set<String>, color: FlagColor) -> Bool`, private `func matches(_:CullFilter)->Bool`

- [ ] **Step 1: Write the failing test**

Add to `QuickCullCoreTests/Session/SessionTests.swift` (or create `TricolorSessionTests.swift`) first failing exclusive test:

```swift
import XCTest
@testable import QuickCullCore

final class TricolorSessionTests: XCTestCase {
    func testExclusiveToggle() {
        let files = TestFixtures.makeFiles(["a.jpg","b.jpg"])
        let s = Session(files: files)
        _ = s.toggleFlag(color: .red) // a red
        XCTAssertEqual(s.flagColor(for: files[0]), .red)
        XCTAssertEqual(s.flaggedCount(.red), 1)
        _ = s.toggleFlag(color: .red) // same key toggles off
        XCTAssertNil(s.flagColor(for: files[0]))
        XCTAssertEqual(s.flaggedCount(), 0)
        _ = s.toggleFlag(color: .red)
        _ = s.toggleFlag(color: .yellow) // X on red → yellow replaces
        XCTAssertEqual(s.flagColor(for: files[0]), .yellow)
        XCTAssertEqual(s.flaggedCount(.red), 0)
        XCTAssertEqual(s.flaggedCount(.yellow), 1)
    }
    func testFilterProjections() {
        var files = TestFixtures.makeFiles(["a.jpg","b.jpg","c.jpg","d.jpg"])
        let s = Session(files: files)
        _ = s.toggleFlag(color: .red) // a red
        s.move(by: 1); _ = s.toggleFlag(color: .yellow) // b yellow
        s.move(by: 1); _ = s.toggleFlag(color: .green) // c green
        // d unflagged
        s.setFilter(.red); XCTAssertEqual(s.files.count, 1); XCTAssertEqual(s.files[0].id, files[0].id)
        s.setFilter(.yellow); XCTAssertEqual(s.files.count, 1)
        s.setFilter(.green); XCTAssertEqual(s.files.count, 1)
        s.setFilter(.keepers); XCTAssertEqual(s.files.count, 1) // d
        s.setFilter(.all); XCTAssertEqual(s.files.count, 4)
        XCTAssertEqual(s.flaggedCount(.red), 1); XCTAssertEqual(s.flaggedCount(.yellow), 1); XCTAssertEqual(s.flaggedCount(.green), 1)
        XCTAssertEqual(s.flaggedCount(), 3)
        XCTAssertEqual(s.flaggedFiles(.red).count, 1)
        XCTAssertEqual(s.flaggedFiles().count, 3)
    }
    func testRemovePerColorLeavesOthers() {
        let files = TestFixtures.makeFiles(["a.jpg","b.jpg","c.jpg"])
        let s = Session(files: files)
        _ = s.toggleFlag(color: .red) // a
        s.move(by:1); _ = s.toggleFlag(color: .yellow) // b
        s.move(by:1); _ = s.toggleFlag(color: .green) // c
        s.remove(s.flaggedFiles(.red))
        XCTAssertEqual(s.flaggedCount(.red), 0)
        XCTAssertEqual(s.flaggedCount(.yellow), 1)
        XCTAssertEqual(s.flaggedCount(), 2)
        XCTAssertEqual(s.allFiles.count, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing 2>&1 | tail -20
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest -XCTest TricolorSessionTests 2>&1 | tail -30
```
Expected: FAIL with `cannot find type 'FlagColor' in scope` / `value of type 'Session' has no member 'toggleFlag'` with color param / `no member 'red' in CullFilter`.

- [ ] **Step 3: Write minimal implementation**

Create `QuickCullCore/Session/FlagColor.swift`:

```swift
import Foundation
import SwiftUI

public enum FlagColor: String, CaseIterable, Sendable, Codable, Hashable {
    case red, yellow, green
    public var displayName: String {
        switch self { case .red: "Red"; case .yellow: "Yellow"; case .green: "Green" }
    }
    public var keyCode: UInt16 {
        switch self { case .red: 6; case .yellow: 7; case .green: 8 }
    }
    public var uiColor: Color {
        switch self { case .red: .red; case .yellow: .yellow; case .green: .green }
    }
}
```

Modify `QuickCullCore/Session/CullFilter.swift:4`:

```swift
public enum CullFilter: CaseIterable, Hashable, Sendable {
    case all
    case red
    case yellow
    case green
    case keepers // unflagged
}
```

Modify `QuickCullCore/Session/Session.swift:13`:

Replace `public private(set) var flagged: Set<String> = []` with:

```swift
public private(set) var flags: [String: FlagColor] = [:]
public var flagged: Set<String> { Set(flags.keys) }
public func flagColor(for file: SessionFile) -> FlagColor? { flags[file.id] }
public func flagColor(for id: String) -> FlagColor? { flags[id] }
public func flaggedCount(_ color: FlagColor? = nil) -> Int {
    if let c = color { return flags.values.filter { $0 == c }.count }
    else { return flags.count }
}
public var flaggedCount: Int { flags.count }
public func flaggedFiles(_ color: FlagColor? = nil) -> [SessionFile] {
    if let c = color { return allFiles.filter { flags[$0.id] == c } }
    else { return allFiles.filter { flags[$0.id] != nil } }
}
public var flaggedFiles: [SessionFile] { flaggedFiles(nil) }
public func isFlagged(_ file: SessionFile) -> Bool { flags[file.id] != nil }
public func isFlagged(_ file: SessionFile, color: FlagColor) -> Bool { flags[file.id] == color }
```

Update `matches(_:filter:)`:

```swift
private func matches(_ file: SessionFile, _ filter: CullFilter) -> Bool {
    switch filter {
    case .all: return true
    case .red: return flags[file.id] == .red
    case .yellow: return flags[file.id] == .yellow
    case .green: return flags[file.id] == .green
    case .keepers: return flags[file.id] == nil
    }
}
```

Add `toggleFlag(color:)`:

```swift
@discardableResult
public func toggleFlag(color: FlagColor) -> Bool {
    guard !files.isEmpty else { return false }
    let id = currentFile.id
    if flags[id] == color { flags.removeValue(forKey: id) } else { flags[id] = color }
    guard filter != .all else { return false }
    let newFiles = projection(for: filter)
    if newFiles.isEmpty { filter = .all; files = allFiles; if let idx = allFiles.firstIndex(where: { $0.id == id }) { currentIndex = idx } }
    else { files = newFiles; currentIndex = min(currentIndex, newFiles.count-1) }
    return true
}
```

Keep overload for compat: `@discardableResult public func toggleFlag() -> Bool { toggleFlag(color: .red) }`

Add `toggleFlags(ids:color:)` similarly looping `if flags[id]==color { remove } else { flags[id]=color }`.

Update `remove(_:)`:

```swift
let ids = Set(filesToRemove.map(\.id))
for id in ids { flags.removeValue(forKey: id) }
```

Keep `allFiles.removeAll` etc. Ensure `flagged.subtract` removed.

Ensure `Session` still `@Observable @MainActor`.

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest -XCTest TricolorSessionTests -v 2>&1 | tail -30
```
Expected: PASS (3 tests). Full suite:
```bash
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -20
```
Expected: all prior 149 + 3 new pass.

- [ ] **Step 5: Commit**

```bash
git add QuickCullCore/Session/FlagColor.swift QuickCullCore/Session/CullFilter.swift QuickCullCore/Session/Session.swift QuickCullCoreTests/Session/SessionTests.swift
git commit -m "feat: tricolor flags core model (FlagColor, 5 filters, exclusive dict)"
```

---

### Task 2: KeyMap and Badge Tint

**Files:**
- Modify: `QuickCullCore/Keys/CullKeyMap.swift:9,19`, `QuickCull/FlagBadge.swift:6`, `QuickCullCore/Models/FlagBadgeLogic.swift:6` (if needed)
- Test: `QuickCullCoreTests/Keys/CullKeyMapTests.swift`, `QuickCullCoreTests/Models/FlagBadgeLogicTests.swift` (or create)

**Interfaces:**
- Consumes: `FlagColor` from Task 1
- Produces: `public enum CullAction: Equatable { case next, previous, jumpForward, jumpBack, toggleFlag(FlagColor) }`, `CullKeyMap.action(forKeyCode:) -> CullAction?` mapping 6→.red,7→.yellow,8→.green; `struct FlagBadge: View { var color: FlagColor; var size: CGFloat }` with fill `.red/.yellow/.green`; `FlagBadgeLogic.shouldShow` unchanged but callers use `flagColor != nil`

- [ ] **Step 1: Write the failing test**

Create `QuickCullCoreTests/Keys/CullKeyMapTricolorTests.swift`:

```swift
import XCTest
@testable import QuickCullCore

final class CullKeyMapTricolorTests: XCTestCase {
    func testZXYMapping() {
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 6), .toggleFlag(.red))
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 7), .toggleFlag(.yellow))
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 8), .toggleFlag(.green))
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 123), .previous)
        XCTAssertNil(CullKeyMap.action(forKeyCode: 99))
    }
}
```

And badge test (optional):

```swift
import XCTest
@testable import QuickCullCore
final class FlagBadgeLogicTestsTricolor: XCTestCase {
    func testShouldShowWithColor() {
        XCTAssertTrue(FlagBadgeLogic.shouldShow(isFlagged: true, hasImage: true))
        XCTAssertFalse(FlagBadgeLogic.shouldShow(isFlagged: false, hasImage: true))
        XCTAssertFalse(FlagBadgeLogic.shouldShow(isFlagged: true, hasImage: false))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest -XCTest CullKeyMapTricolorTests 2>&1 | tail -20
```
Expected: FAIL `cannot find case 'toggleFlag' with associated value` / `expected .toggleFlag(.red) got .toggleFlag` without param.

- [ ] **Step 3: Write minimal implementation**

Modify `QuickCullCore/Keys/CullKeyMap.swift:9`:

```swift
public enum CullAction: Equatable {
    case next
    case previous
    case jumpForward
    case jumpBack
    case toggleFlag(FlagColor)
}
```

Add `xKey=7`, `cKey=8`:

```swift
private static let zKey: UInt16 = 6
private static let xKey: UInt16 = 7
private static let cKey: UInt16 = 8
```

Update `action(forKeyCode:)`:

```swift
case zKey: return .toggleFlag(.red)
case xKey: return .toggleFlag(.yellow)
case cKey: return .toggleFlag(.green)
```

Keep overload? If existing tests call `.toggleFlag` without param, add `case toggleFlag` legacy? Instead keep `toggleFlag(FlagColor)` and update legacy call sites to `.toggleFlag(.red)`. Provide extension for tests: `static var toggleFlag: CullAction { .toggleFlag(.red) }` not needed.

Modify `QuickCull/FlagBadge.swift:6`:

```swift
import SwiftUI
import QuickCullCore
struct FlagBadge: View {
    var color: FlagColor
    var size: CGFloat = 32
    var body: some View {
        CornerTriangle().fill(color.uiColor)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
    }
}
```

Update `FlagBadgeLogic.swift:6` keep `shouldShow(isFlagged:hasImage:)`; callers compute `isFlagged = flagColor != nil`.

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest -XCTest CullKeyMapTricolorTests -v 2>&1 | tail -20
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -20
```
Expected: PASS (1+), full suite green.

Update existing `CullKeyMapTests.swift` that asserts `zKey == .toggleFlag` to `== .toggleFlag(.red)`.

- [ ] **Step 5: Commit**

```bash
git add QuickCullCore/Keys/CullKeyMap.swift QuickCull/FlagBadge.swift QuickCullCoreTests/Keys/CullKeyMapTricolorTests.swift
git commit -m "feat: map Z/X/C to red/yellow/green and tint FlagBadge"
```

---

### Task 3: AppState Per-Color Commit/Move

**Files:**
- Modify: `QuickCullCore/App/AppState.swift:27-30,36-42,54-68,71-102,208-213,275-360`
- Test: `QuickCullCoreTests/App/AppStateTricolorTests.swift`

**Interfaces:**
- Consumes: `FlagColor`, `Session.flaggedCount(_:)`, `Session.flaggedFiles(_:)`, `MoveCommit`, `TrashCommit` from Task 1-2
- Produces: `AppState` additions `pendingCommitColor: FlagColor?`, `pendingMoveColor: FlagColor?`, `func requestCommit(color: FlagColor?)`, `func requestMove(to: URL, color: FlagColor?)`, updated `confirmCommit/confirmMove` per-color, counts `flaggedCount(color:)` helpers, guards already include `isMoving`/`isCommitting`

- [ ] **Step 1: Write the failing test**

Create `QuickCullCoreTests/App/AppStateTricolorTests.swift`:

```swift
import XCTest
@testable import QuickCullCore

@MainActor
final class AppStateTricolorTests: XCTestCase {
    private var tempDir: URL!
    private var cache: ImageCacheStore!
    override func setUp() async throws {
        tempDir = try TestFixtures.makeTempDir(name: "tri-app")
        cache = ImageCacheStore(baseURL: tempDir.appendingPathComponent("cache", isDirectory: true))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }
    private func makeState(mover: Moving = FileManagerMover()) -> AppState {
        AppState(decoder: StubDecoder(), cache: cache, trasher: StubTrasher(), mover: mover)
    }
    private func waitForScrubbing(_ s: AppState) async {
        for _ in 0..<200 { if s.phase == .scrubbing { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("never scrubbing")
    }

    func testPerColorFlagCountsAndHandle() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let s = makeState()
        s.importFiles(urls: [a,b]); await waitForScrubbing(s)
        s.handle(.toggleFlag(.red)) // a red
        s.handle(.next); s.handle(.toggleFlag(.yellow)) // b yellow
        XCTAssertEqual(s.session?.flaggedCount(.red), 1)
        XCTAssertEqual(s.session?.flaggedCount(.yellow), 1)
        XCTAssertEqual(s.session?.flaggedCount(), 2)
        s.setFilter(.red); XCTAssertEqual(s.session?.files.count, 1)
    }

    func testRequestCommitPerColorRemovesOnlyThatColor() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let c = try TestFixtures.makeRawFile(named: "c.cr2", in: tempDir)
        let s = makeState()
        s.importFiles(urls: [a,b,c]); await waitForScrubbing(s)
        s.handle(.toggleFlag(.red)) // a
        s.handle(.next); s.handle(.toggleFlag(.yellow)) // b
        s.handle(.next); s.handle(.toggleFlag(.green)) // c
        s.requestCommit(color: .red)
        XCTAssertEqual(s.pendingCommitCount, 1)
        XCTAssertEqual(s.pendingCommitColor, .red)
        await s.confirmCommit()
        XCTAssertEqual(s.session?.flaggedCount(.red), 0)
        XCTAssertEqual(s.session?.flaggedCount(.yellow), 1)
        XCTAssertEqual(s.session?.flaggedCount(), 2)
        // all flagged
        s.requestCommit(color: nil)
        XCTAssertEqual(s.pendingCommitCount, 2)
        await s.confirmCommit()
        XCTAssertEqual(s.session?.flaggedCount(), 0)
    }

    func testRequestMovePerColor() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let dest = try TestFixtures.makeTempDir(name: "tri-dest")
        defer { try? FileManager.default.removeItem(at: dest) }
        let s = makeState()
        s.importFiles(urls: [a,b]); await waitForScrubbing(s)
        s.handle(.toggleFlag(.red)) // a
        s.handle(.next); s.handle(.toggleFlag(.yellow)) // b
        s.requestMove(to: dest, color: .red)
        XCTAssertEqual(s.pendingMoveCount, 1)
        XCTAssertEqual(s.pendingMoveColor, .red)
        await s.confirmMove()
        XCTAssertEqual(s.session?.flaggedCount(.red), 0)
        XCTAssertEqual(s.session?.flaggedCount(.yellow), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.cr2").path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest -XCTest AppStateTricolorTests 2>&1 | tail -30
```
Expected: FAIL `has no member 'toggleFlag' with FlagColor` / `requestCommit(color:)` missing / `pendingCommitColor` missing.

- [ ] **Step 3: Write minimal implementation**

Modify `QuickCullCore/App/AppState.swift`:

1. Add `pendingCommitColor`/`pendingMoveColor`:

```swift
public private(set) var pendingCommitColor: FlagColor?
public private(set) var pendingMoveColor: FlagColor?
```

2. Update `init` already has `mover`; keep.

3. Update `requestCommit` to `requestCommit(color: FlagColor?)`:

```swift
public func requestCommit(color: FlagColor? = nil) {
    pendingCommitColor = color
    pendingCommitCount = session?.flaggedCount(color) ?? 0
}
public func cancelCommit() { pendingCommitCount = 0; pendingCommitColor = nil }
```

4. Update `confirmCommit()` to use color:

```swift
public func confirmCommit() async {
    guard let session, !isCommitting, !isMoving else { return }
    let color = pendingCommitColor
    let flagged = session.flaggedFiles(color)
    guard !flagged.isEmpty else { pendingCommitCount=0; pendingCommitColor=nil; return }
    isCommitting = true
    let outcomes = await Task.detached(priority: .userInitiated) { TrashCommit(trasher: self.trasher).commit(files: flagged) }.value
    // same remove/prune logic but pendingCommitColor cleared
    ...
    pendingCommitColor = nil
}
```

5. Similarly `requestMove(to:color:)`:

```swift
public func requestMove(to dest: URL, color: FlagColor? = nil) {
    pendingMoveCount = session?.flaggedCount(color) ?? 0
    pendingMoveDestination = dest
    pendingMoveColor = color
}
public func cancelMove() { pendingMoveCount=0; pendingMoveDestination=nil; pendingMoveColor=nil }
```

Update `confirmMove()` to use `pendingMoveColor`:

```swift
let flagged = session.flaggedFiles(pendingMoveColor)
```

Clear `pendingMoveColor` after.

6. Update `handle(_:)` to extract color:

```swift
case .toggleFlag(let color):
    if viewMode == .grid && !gridSelection.isEmpty {
        let changed = session.toggleFlags(ids: gridSelection, color: color)
        ...
    } else {
        if session.toggleFlag(color: color) { installWindows }
        else { syncWindows() }
    }
```

Keep `handle(_:)` signature `CullAction`.

7. Update `startNewSession`/`importFiles` clears to also nil colors.

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest -XCTest AppStateTricolorTests -v 2>&1 | tail -30
```
Expected: PASS (3 tests). Full suite:
```bash
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -20
```
Expected: 149 + 3 = 152 tests pass (plus Task1/2 new tests, total ~154).

- [ ] **Step 5: Commit**

```bash
git add QuickCullCore/App/AppState.swift QuickCullCoreTests/App/AppStateTricolorTests.swift
git commit -m "feat: AppState per-color commit/move (pending color, flaggedFiles(color:))"
```

---

### Task 4: ScrubView Filter and Menus + Viewer Badges

**Files:**
- Modify: `QuickCull/ScrubView.swift:58,77,91,130`, `QuickCull/ImageDisplayView.swift:55`, `QuickCull/FilmstripView.swift`, `QuickCull/GridView.swift`, `QuickCull/BadgedThumbnailView.swift`
- Test: manual QA + existing suite (no new XCTest for NSOpenPanel/Toolbar Menu beyond Task 3)

**Interfaces:**
- Consumes: `FlagColor`, `CullFilter.red/yellow/green/keepers/all`, `Session.flagColor(for:)`, `Session.flaggedCount(_:)`, `AppState.handle(.toggleFlag(color:))`, `AppState.setFilter`, `AppState.requestCommit(color:)`, `requestMove(to:color:)`, `pendingCommitColor/MoveColor`, `FlagBadge(color:)`
- Produces: 5-segment Filter picker with live counts, Trash Menu and Move Menu with per-color counts/disabled, alerts with color text, viewer/filmstrip/grid colored badges

- [ ] **Step 1: Write the failing test (build gate)**

Run:
```bash
grep -n "CullFilter.red" QuickCull/ScrubView.swift || echo "not found (expected before)"
grep -n "FlagBadge(color" QuickCull/ImageDisplayView.swift || echo "not found"
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build 2>&1 | tail -10
```
Expected: not found.

- [ ] **Step 2: Run test to verify it fails (post-intent)**

Search for `Menu {` with Trash Red — should not exist yet:

```bash
grep -n "Trash Red" QuickCull/ScrubView.swift || echo "fail before"
```

- [ ] **Step 3: Write minimal implementation**

**A. ScrubView Filter 5 segments** `ScrubView.swift:58`:

Replace 3-case Picker with 5:

```swift
Picker("Filter", selection: Binding(
    get: { appState.session?.filter ?? .all },
    set: { appState.setFilter($0) }
)) {
    Text("All").tag(CullFilter.all)
    Text("Red (\(appState.session?.flaggedCount(.red) ?? 0))").tag(CullFilter.red)
    Text("Yellow (\(appState.session?.flaggedCount(.yellow) ?? 0))").tag(CullFilter.yellow)
    Text("Green (\(appState.session?.flaggedCount(.green) ?? 0))").tag(CullFilter.green)
    Text("Unflagged (\(appState.session?.flaggedCount(nil) != nil ? (appState.session!.totalCount - (appState.session!.flaggedCount(.red)+appState.session!.flaggedCount(.yellow)+appState.session!.flaggedCount(.green))) : 0))").tag(CullFilter.keepers)
}
.pickerStyle(.segmented)
.fontWeight(.light)
.disabled(appState.isCommitting || appState.isMoving)
```

Simpler Unflagged count: `appState.session.map { $0.totalCount - $0.flaggedCount() } ?? 0`.

**B. Trash Menu** `ScrubView.swift:77`:

Replace single `Button` Trash with `Menu`:

```swift
Menu {
    Button("Trash Red (\(appState.session?.flaggedCount(.red) ?? 0))", role: .destructive) {
        appState.requestCommit(color: .red); showCommitConfirm = true
    }.disabled((appState.session?.flaggedCount(.red) ?? 0)==0 || appState.isCommitting || appState.isMoving)
    Button("Trash Yellow (\(appState.session?.flaggedCount(.yellow) ?? 0))", role: .destructive) {
        appState.requestCommit(color: .yellow); showCommitConfirm = true
    }.disabled((appState.session?.flaggedCount(.yellow) ?? 0)==0 || ...)
    Button("Trash Green (\(appState.session?.flaggedCount(.green) ?? 0))", role: .destructive) {
        appState.requestCommit(color: .green); showCommitConfirm = true
    }.disabled(...)
    Button("Trash All Flagged (\(appState.session?.flaggedCount() ?? 0))", role: .destructive) {
        appState.requestCommit(color: nil); showCommitConfirm = true
    }.disabled((appState.session?.flaggedCount() ?? 0)==0 || ...)
} label: {
    if appState.isCommitting { ProgressView().controlSize(.small) }
    else { Label("Move Flagged to Trash", systemImage: "trash") }
}
.fontWeight(.light)
.disabled(appState.isCommitting || appState.isMoving)
```

**C. Move Menu** `ScrubView.swift:91`:

Similarly `Menu` with `Move Red/Yellow/Green/All Flagged` each opening `NSOpenPanel` then `requestMove(to:dest,color: ...)`:

```swift
Menu {
    Button("Move Red (\(appState.session?.flaggedCount(.red) ?? 0))") {
        let panel = NSOpenPanel(); panel.canChooseFiles=false; panel.canChooseDirectories=true; panel.canCreateDirectories=true; panel.allowsMultipleSelection=false; panel.prompt="Move"; panel.message="Choose a folder to move flagged images to"
        if panel.runModal()==.OK, let dest=panel.url {
            appState.requestMove(to: dest, color: .red); showMoveConfirm=true
        }
    }.disabled((appState.session?.flaggedCount(.red) ?? 0)==0 || ...)
    // Yellow, Green, All Flagged similarly
} label: {
    if appState.isMoving { ProgressView() } else { Label("Move Flagged", systemImage: "folder") }
}
.fontWeight(.light)
.disabled(appState.isCommitting || appState.isMoving)
```

**D. Alerts with color text** `ScrubView.swift:130`:

Update confirm alerts to include color:

```swift
.alert("Move \(appState.pendingCommitCount) \(appState.pendingCommitColor?.displayName.lowercased() ?? "flagged") file(s) to Trash?",
       isPresented: $showCommitConfirm) { ... }
.alert("Move \(appState.pendingMoveCount) \(appState.pendingMoveColor?.displayName.lowercased() ?? "flagged") file(s) to \"\(appState.pendingMoveDestination?.lastPathComponent ?? "")\"?",
       isPresented: $showMoveConfirm) { ... }
.alert("Could not move \(appState.commitFailures.count) \(appState.pendingCommitColor?.displayName.lowercased() ?? "flagged") file(s) to Trash", ...)
.alert("Could not move \(appState.moveFailures.count) \(appState.pendingMoveColor?.displayName.lowercased() ?? "flagged") file(s)", ...)
```

Or simpler: if `pendingCommitColor != nil` show color, else `flagged`.

**E. Badges** `ImageDisplayView.swift:55` etc:

Replace `isFlagged = session.isFlagged(file)` + `FlagBadge(size:)` with:

```swift
let flagColor = appState.session?.flagColor(for: file)
if let c = flagColor, FlagBadgeLogic.shouldShow(isFlagged: true, hasImage: true) {
    FlagBadge(color: c, size: 44)
}
```

Same for `FlagBadgeOverlay`, `FilmstripView`, `GridView`, `BadgedThumbnailView`.

Update `FlagBadgeOverlay` to accept `FlagColor`.

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build 2>&1 | tail -20
```
Expected: build succeeds.

Run full suite:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -20
```
Expected: all ~154 + Task 3 new tests pass, no regressions.

Manual QA `./start.sh` import 5 RAWs: Z red, X yellow, C green, same key off, X on red → yellow, Filter Red/Yellow/Green/Unflagged live, Trash/Move menus show counts/disabled, Grid batch select then Z/X/C exclusive.

- [ ] **Step 5: Commit**

```bash
git add QuickCull/ScrubView.swift QuickCull/ImageDisplayView.swift QuickCull/FilmstripView.swift QuickCull/GridView.swift QuickCull/BadgedThumbnailView.swift QuickCull/FlagBadge.swift
git commit -m "feat: ScrubView 5 filters + Trash/Move per-color menus + tinted badges"
```

---

## Self-Review

**1. Spec coverage:** Each spec section maps:
- Purpose/Approach (FlagColor dict exclusive, 5 filters, per-color Menus) → Tasks 1,3,4
- Visual (Filter 5 segments, Menus with counts/disabled, FlagBadge tint, same triangle) → Tasks 2,4
- Data/Computation (FlagColor enum, CullFilter 5 cases, Session flags dict/helpers/matches/toggle/remove, CullKeyMap Z/X/C, FlagBadgeLogic, AppState pending colors, Badge view) → Tasks 1-3
- Components summary → Tasks 1-4 file lists
- Data Flow (Z/X/C → Session → badge, Filter → projection, Menu → pendingColor → commit/move per-color → remove succeeded) → Tasks 1,3,4
- Error Handling (same key off, replace color, empty placeholder, batch exclusive, Menu disabled, narrow toolbar, legacy flagged migration, no persistence) → Tasks 1,3,4
- Testing (Session exclusive/filter/remove, KeyMap Z/X/C, Badge show, AppState per-color commit/move, Manual QA Z/X/C, filter, menu, grid batch) → Tasks 1-4
- Files list → covered
- Acceptance Criteria (Z/X/C exclusive, badge color, 5 filters, Menus per-color counts/disabled, per-color commit/move with auto-rename, build + suite green) → Tasks 1-4

**2. Placeholder scan:** No TBD/TODO, no “implement later”, no “similar to Task N” without code — all steps have verbatim Swift, bash, expected outputs.

**3. Type consistency:** `FlagColor` `.red/.yellow/.green` used consistently in `Session.flagColor(for:)`, `flaggedCount(_:)`, `flaggedFiles(_:)`, `toggleFlag(color:)`, `toggleFlags(ids:color:)`, `CullAction.toggleFlag(FlagColor)`, `CullKeyMap` 6/7/8, `FlagBadge(color:)`, `AppState.requestCommit(color:)`, `requestMove(to:color:)`, `pendingCommitColor/MoveColor`, `ScrubView` Filter `tag(.red/.yellow/.green)`, Menu counts `flaggedCount(.red)` etc. `CullFilter` `all/red/yellow/green/keepers` matches `Session.matches` cases.

Fixes applied inline: none needed; spec tight.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-19-tricolor-flags.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
