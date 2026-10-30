# Move Flagged to Folder — Design

Date: 2026-08-19
Status: approved design

## Purpose

Add a **Move Flagged** button next to **Move Flagged to Trash** in the same toolbar section. The button prompts where to move flagged images (NSOpenPanel folder picker each time, flat move), auto-renames on collision, and behaves like Trash commit: successful moves are removed from the session, failed moves keep their flags, with per-file failure reporting.

## Background

Today (`37ea43e`):

* `ScrubView.swift:74-87` has `ToolbarItem` `Label("Move Flagged to Trash", systemImage:"trash")` disabled when `flaggedCount==0||isCommitting`, calls `appState.requestCommit()` then `showCommitConfirm=true`. Alerts: `Move N file(s) to Trash?` → `Task { await confirmCommit() }` / `Cancel`, and `Could not move N file(s) to Trash` on `commitFailures.count>0`. `isCommitting` disables Metadata/View/Filter/New Session/Trash.
* `QuickCullCore/App/AppState.swift:275-306` has `private(set) var pendingCommitCount:Int`, `commitFailures:[TrashOutcome]`, `isCommitting:Bool`, `requestCommit()`, `confirmCommit() async` (detached `TrashCommit(trasher).commit(files: flaggedFiles)`), `cancelCommit()`. On success: `session.remove(succeeded)`, `gridSelection` pruned, `commitFailures=failed`, `isCommitting=false`, then `installWindows` or `phase=.empty` if `isEmpty`. `startNewSession()` and `importFiles` clear commit state.
* `QuickCullCore/Commit/TrashCommit.swift:30` is `struct TrashCommit(trasher:Trashing).commit(files:[SessionFile])->[TrashOutcome]` with `protocol Trashing { trash(url:URL) throws }` and `FileManagerTrasher` via `FileManager.trashItem`. Never throws, per-file outcome.
* `Session` is `SessionFile(url:)` with `id=url.path`, `flagged:Set<String>`, `flaggedFiles`, `flaggedCount`, `remove([SessionFile])` shifts index.
* No Move capability exists. Original spec `2026-08-16-quickcull-design.md:38` out-of-scoped “moving flagged files anywhere other than Trash”.

User (brainstorming 2026-08-19) chose:
* Pick folder each time via `NSOpenPanel` (choose directories, can create), flat move to that folder (no subfolders).
* Collision → auto-rename `name 1.ext`, `name 2.ext` before extension, preserving case.
* Like Trash: successful moves removed from session, failed keep flag, failure alert, `isMoving` disables chrome.
* Button: `Move Flagged` with `systemImage:"folder"` (SF Symbol), same `primaryAction` group immediately after Trash, disabled when `flaggedCount==0||isCommitting||isMoving`.

## Approach (approved — A: FileManager.moveItem with auto-rename, mirrored to TrashCommit)

Mirror `TrashCommit` with a new `MoveCommit` that takes a destination folder URL. Single responsibility, testable boundary, no `NSFileCoordinator` in v1, `FileManager.moveItem` handles same-volume rename and cross-volume copy+delete. Destination check + suffix search runs synchronously before move, still on detached background task.

Rejected: (B) `NSFileCoordinator` — adds coordinator ceremony for rare iCloud race, not needed for user-picked move. (C) per-file progress UI — Trash has no progress, Move on same volume is instant, YAGNI.

## Visual — `QuickCull/ScrubView.swift:74-87`

**Toolbar — same `primaryAction` group as Trash, immediately after:**

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

* Ordering: `Metadata | View | Filter | New Session | Trash | Move` — Move immediately after Trash in same section. On narrow window toolbar overflow, trailing group truncates together.
* State hoisted in `ScrubView`: `@State private var showMoveConfirm = false`, `@State private var showMoveFailures = false`, plus existing `showCommit*`. `isMoving` mirrors `isCommitting` disabling: `View`/`Filter`/`New Session`/`Trash`/`Move` all `.disabled(isCommitting||isMoving)` (existing disables already check `isCommitting`, updated to `isCommitting||isMoving`).
* Alerts:
  ```swift
  .alert("Move \(appState.pendingMoveCount) file(s) to \"\(appState.pendingMoveDestination?.lastPathComponent ?? "")\"?",
         isPresented: $showMoveConfirm) {
      Button("Move", role: .none) { Task { await appState.confirmMove() } }
      Button("Cancel", role: .cancel) { appState.cancelMove() }
  } message: {
      Text("Flagged files will be moved to the selected folder and removed from this session. Scrubbing continues with the rest.")
  }
  .alert("Could not move \(appState.moveFailures.count) file(s)",
         isPresented: $showMoveFailures) {
      Button("OK", role: .cancel) {}
  } message: {
      Text("The remaining files keep their flags. You may need to grant file access in System Settings, or choose a writable folder.")
  }
  .onChange(of: appState.moveFailures.count) { if appState.moveFailures.count>0 { showMoveFailures=true } }
  ```
* `NSOpenPanel` is AppKit modal, main-actor only; call directly from button action (already `@MainActor`). No `Task` needed for panel.

**No HUD, Grid, Filmstrip changes.**

## Data / Computation — `QuickCullCore/Commit/MoveCommit.swift` + `QuickCullCore/App/AppState.swift`

**Model — `QuickCullCore/Commit/MoveCommit.swift`:**

```swift
import Foundation

public protocol Moving: Sendable { func move(from: URL, to: URL) throws }

public struct FileManagerMover: Moving {
    public init() {}
    public func move(from: URL, to: URL) throws { try FileManager.default.moveItem(at: from, to: to) }
}

public struct MoveOutcome {
    public let file: SessionFile
    public let error: Error?
    public var succeeded: Bool { error == nil }
    public init(file: SessionFile, error: Error?) { self.file=file; self.error=error }
}

public struct MoveCommit {
    private let mover: Moving
    public init(mover: Moving) { self.mover = mover }

    /// Destination auto-rename: "IMG.CR2" → "IMG 1.CR2", "IMG 2.CR2" …
    /// Preserves extension case, base name before last ".".
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
            do { try mover.move(from: file.url, to: dest); return MoveOutcome(file: file, error: nil) }
            catch { return MoveOutcome(file: file, error: error) }
        }
    }
}
```

* `Mover` protocol enables `StubMover` in tests like `Trashing` does.
* Auto-rename runs synchronously on detached background task, checking `fileExists` each time. No overwrite, no prompt.
* Moving file onto itself? If `folder` contains same path as `file.url` (user picks source folder), `autoRenamedDestination` will see source filename exists → returns `name 1.ext` (different path), so no self-move error, just renames. Acceptable.

**State — `QuickCullCore/App/AppState.swift:24-30,71-68,275-306`:**

Add:

```swift
public private(set) var pendingMoveCount: Int = 0
public private(set) var pendingMoveDestination: URL?
public private(set) var moveFailures: [MoveOutcome] = []
public private(set) var isMoving: Bool = false
private let mover: Moving
```

Extend `init(mover: Moving = FileManagerMover())` (alongside existing `trasher`).

Helpers:

```swift
public func requestMove(to dest: URL) {
    pendingMoveCount = session?.flaggedCount ?? 0
    pendingMoveDestination = dest
}
public func cancelMove() { pendingMoveCount = 0; pendingMoveDestination = nil }

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
    commitFailures = [] // keep trash failures independent; not cleared here
    pendingMoveCount = 0
    pendingMoveDestination = nil
    isMoving = false
    if session.isEmpty {
        self.session = nil; thumbWindow=nil; gridThumbs=nil; displayImages=nil; phase=.empty; viewMode=.scrub
    } else { installWindows(for: session.files) }
}
```

* Guards: `isMoving||isCommitting` prevents re-entrant move/commit. `setViewMode`/`handle`/`select` already guard `isCommitting`, extend to `isMoving` (like `setViewMode` does for commit).
* `startNewSession()` clears `moveFailures`, `pendingMoveCount`, `pendingMoveDestination`, `isMoving` alongside commit state.
* `importFiles` clears move state in same place as commit state.
* `syncWindows` unchanged; `installWindows` rebuilds over new projection after move (same as commit).

No file writes for adjustments (preview-only). Move failures never cached.

## Components — Summary

* New file `QuickCullCore/Commit/MoveCommit.swift` — `Moving`, `FileManagerMover`, `MoveOutcome`, `MoveCommit.commit(files:to:)` + `autoRenamedDestination`.
* Modify `QuickCullCore/App/AppState.swift:24-68,71-84,208-213,275-307` — add `pendingMove*`, `moveFailures`, `isMoving`, `mover` init param, `requestMove`, `cancelMove`, `confirmMove`, guards in `setViewMode`/`handle`, clears in `startNewSession`/`importFiles`.
* Modify `QuickCull/ScrubView.swift:5-9,38-87,89-113,110-133` — add `@State showMoveConfirm/showMoveFailures`, `isMoving` disable to all chrome, new `ToolbarItem` Move Flagged with `NSOpenPanel`, two `.alert` for move confirm/failures, `.onChange(moveFailures)`.

No change: `TrashCommit`, `DecodeEngine`, `ImageCacheStore`, `LibRawDecoder`, `Session`, `ImageWindow`, `GridView`, `FilmstripView`, `RootView`, `ImageDisplayView`.

## Data Flow

```
Click Move Flagged → NSOpenPanel (canChooseDirectories, canCreateDirectories) modally → user picks destURL or Cancel
  Cancel → no state change
  OK → requestMove(to: destURL) (pendingMoveCount, pendingMoveDestination) → showMoveConfirm=true
    Alert "Move N to Dest?" — Cancel → cancelMove() clears pending; Move → Task { await confirmMove() }
      confirmMove: guard !isCommitting&&!isMoving, dest exists, flagged non-empty → isMoving=true
        Task.detached: MoveCommit(mover).commit(files: flaggedFiles, to: dest) // auto-rename per file, moveItem
        succeeded = outcomes.filter(succeeded).map(file) → session.remove(succeeded) → gridSelection pruned
        moveFailures = failed → pending cleared → isMoving=false → if isEmpty → phase=.empty else installWindows
        onChange(moveFailures.count) → showMoveFailures alert if >0
Scrub → setCurrentIndex/syncWindows unchanged; flagged moves do not affect windows beyond installWindows
New Session / new import → move state cleared like commit state
```

Move and Trash share session-removal path but have independent `pending*`/`*Failures`/`is*` state so both alerts can coexist.

## Error Handling & Edge Cases

* `NSOpenPanel` Cancel → no `requestMove`, no alert, no state.
* `destURL` not writable / permission denied → `moveItem` throws per file → `MoveOutcome(error)` → flags kept, `moveFailures` alert shows “grant file access in System Settings, or choose a writable folder”.
* Collision auto-rename → `fileExists` check increments ` 1`, ` 2` … until free. No overwrite. Existing file untouched.
* Source and destination same folder → collision path hits, auto-renames to ` 1`, not self-move.
* Cross-volume move → `FileManager.moveItem` performs copy+delete atomically; either succeeds or throws, no partial.
* Destination inside flagged file’s own path (e.g., subfolder of source)? `moveItem` may fail if source is ancestor; failure kept flagged, pruned after.
* No flagged files → button disabled, `requestMove` no-ops if called programatically (`flagged.isEmpty` guard).
* Re-entrant click while `isMoving||isCommitting` → `setViewMode`/`handle` guards prevent mode/flag changes; button disabled; `confirmMove` guard `!isMoving&&!isCommitting` ignores second invocation.
* Commit and Move simultaneous → first sets `isCommitting||isMoving`, second’s `guard !isCommitting&&!isMoving` bails (“You can’t move while committing”). Both buttons disabled during either operation.
* Grid empty selection not relevant — Move operates on flagged set, not grid selection.
* View mode disabled: `Picker("View")`, `Picker("Filter")`, `New Session`, `Move Flagged to Trash`, `Move Flagged` all `.disabled(isCommitting||isMoving)`.
* Narrow window toolbar overflow — trailing `primaryAction` group may collapse; Move remains accessible via overflow menu (standard SwiftUI).
* Disk full during move → per-file throw, failed stay flagged.
* File already deleted/trashed externally → `moveItem` throws `NSFileNoSuchFileError`, kept flagged, failure alert.
* `session.isEmpty` after moving all flagged → `phase=.empty`, `viewMode=.scrub`, windows nil, pending cleared.

## Testing

*Unit — `QuickCullCoreTests/Commit/MoveCommitTests.swift` (new):*
  * Real `FileManagerMover` with temp dirs (`TestFixtures.makeTempDir`): move single file, dest exists → auto-rename ` 1`, multiple collisions → ` 2`, cross-volume not needed.
  * `StubMover` failing per ID: partial success keeps correct outcomes (`succeeded`/`error`).
  * Auto-rename helper isolated: `autoRenamedDestination` returns ` 1` when `base.ext` exists, ` 2` when ` 1` also exists, preserves extension case `JPG` vs `jpg`, no extension case.
  * Source file not found → outcome failed, no crash.

*Unit — `QuickCullCoreTests/App/AppStateMoveTests.swift` (new):*
  * `requestMove` sets `pendingMoveCount`/`pendingMoveDestination`, `cancelMove` clears.
  * `confirmMove` removes succeeded from `session`, keeps failed flagged, prunes `gridSelection`, `isMoving` true during gate, `moveFailures` count, `pending*` cleared, `phase=.empty` when all moved, `installWindows` otherwise.
  * `isMoving` blocks `setViewMode`/`handle` (like commit test `testCommitSetsCommittingState` with `StubMover` gate).
  * `startNewSession` clears `moveFailures`/`pending*`/`isMoving`.
  * `importFiles` clears move state.
  * Commit vs Move mutual exclusion: while `isMoving`, `requestCommit` no-op / `confirmCommit` bails; while `isCommitting`, `confirmMove` bails.
  * Uses `StubMover` with `gate: DispatchSemaphore` to observe `isMoving` in-flight like `StubTrasher`.

*UI smoke — manual (`./start.sh`, import 4 RAWs+JPEG, flag 2):*
  * `Move Flagged` disabled when `flaggedCount==0`, enabled at 1+.
  * Click → `NSOpenPanel` folder chooser appears (can create dir), Cancel → no alert.
  * Pick empty tmp folder → alert `Move 2 file(s) to "tmp"?` → Cancel clears, Move removes 2 from session, files appear in dest, `isMoving` spinner if gated, scrub continues.
  * Pick folder where `IMG.CR2` already exists → moved as `IMG 1.CR2`, dest original untouched, source `IMG.CR2` removed from session.
  * Pick read-only folder → alert `Could not move 2 file(s)`, session retains 2 flagged.
  * While moving, View/Filter/New Session/Trash/Move disabled, `isMoving` spinner.
  * Grid selection pruned if flagged files overlap selection.
  * Move all flagged 3/3 → `phase=.empty`, `viewMode=.scrub`.

## Files

* New: `QuickCullCore/Commit/MoveCommit.swift` — `Moving`, `FileManagerMover`, `MoveOutcome`, `MoveCommit` with `autoRenamedDestination` + `commit(files:to:)`.
* New tests: `QuickCullCoreTests/Commit/MoveCommitTests.swift`, `QuickCullCoreTests/App/AppStateMoveTests.swift`.
* Modify: `QuickCullCore/App/AppState.swift:24-30` add `pendingMove*`, `moveFailures`, `isMoving`, `mover` property; `QuickCullCore/App/AppState.swift:36-42` init inject `mover`; `QuickCullCore/App/AppState.swift:54-68` clears in `startNewSession`; `QuickCullCore/App/AppState.swift:71-102` clears in `importFiles`; `QuickCullCore/App/AppState.swift:208-213` guards `isMoving` in `setViewMode` (and `handle` if needed); `QuickCullCore/App/AppState.swift:275-307` add `requestMove`/`cancelMove`/`confirmMove`.
* Modify: `QuickCull/ScrubView.swift:5-9` add `@State showMoveConfirm/showMoveFailures`; `QuickCull/ScrubView.swift:38-87` new `ToolbarItem` Move Flagged with `NSOpenPanel` + `Label("folder")`, update `.disabled(isCommitting||isMoving)` to all chrome; `QuickCull/ScrubView.swift:89-113` two new `.alert` + `.onChange(moveFailures)`.
* No change: `QuickCullCore/Commit/TrashCommit.swift:30`, `QuickCullCore/Engine/DecodeEngine.swift`, `QuickCullCore/Storage/ImageCacheStore.swift`, `QuickCullCore/Decoding/*`, `QuickCullCore/Session/Session.swift`, `QuickCullCore/Window/*`, `QuickCull/GridView.swift`, `QuickCull/FilmstripView.swift`, `QuickCull/ImageDisplayView.swift`, `QuickCull/RootView.swift`.

No new targets, no new dependencies (AppKit `NSOpenPanel`, Foundation `FileManager`).

## Acceptance Criteria

* Toolbar has `Move Flagged` `Label("folder")` immediately after `Move Flagged to Trash` in same `primaryAction` section; disabled when `flaggedCount==0||isCommitting||isMoving`, shows spinner when `isMoving`.
* Click → `NSOpenPanel` folder picker (canChooseDirectories, canCreateDirectories, prompt Move) each time; Cancel does nothing.
* Pick folder → confirm alert `Move N file(s) to "FolderName"?` with Move/Cancel; Move → detached `MoveCommit` auto-renames collisions to `name 1.ext` … and `moveItem`s; `isMoving` true in-flight, disables View/Filter/New Session/Trash/Move.
* After move: succeeded files removed from `session` and `gridSelection` pruned, `installWindows` or `phase=.empty`; failed files keep flags and `moveFailures` alert `Could not move N file(s)` (grant access / writable folder message).
* Auto-rename verified: dest `a.jpg` exists → moved as `a 1.jpg`, no overwrite.
* Build and full suite green: existing 134 + new Move tests.
