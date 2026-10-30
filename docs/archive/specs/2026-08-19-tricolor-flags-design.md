# Tricolor Flags (Z Red, X Yellow, C Green) — Design

Date: 2026-08-19
Status: approved design

## Purpose

Replace single red flag (`Z`) with three exclusive color flags: `Z` → red, `X` → yellow, `C` → green. Each photo holds at most one color; pressing same key toggles off to unflagged. Filtering expands to `All + 3 colors + Unflagged` (5 segments). Deleting (Trash) and moving (Move Flagged) each become a `Menu` with per-color choices (Red / Yellow / Green / All flagged), all with live counts and disabled states. Affects filtering, deleting, and move system as user requested.

## Background

Today (`d5e86ec`):

* `QuickCullCore/Session/Session.swift:13` has `flagged: Set<String>` (ids), `flaggedCount`, `flaggedFiles`, `isFlagged(_:)`, `toggleFlag() -> Bool` (current photo) and `toggleFlags(ids:Set<String>)` (batch). `matches(_:filter:)` handles `CullFilter.all/flagged/keepers` where `flagged` = any flagged, `keepers` = unflagged. `remove(_:)` subtracts `flagged.subtract(ids)` and clears flags of trashed files.
* `QuickCullCore/Session/CullFilter.swift:4` is `enum CullFilter { all, flagged, keepers }`.
* `QuickCullCore/Keys/CullKeyMap.swift:9` is `enum CullAction { toggleFlag }` and `CullKeyMap.action(forKeyCode:)` mapping `zKey=6` → `.toggleFlag`. Only `Z` is handled.
* `QuickCullCore/Models/FlagBadgeLogic.swift:6` is `shouldShow(isFlagged:hasImage:) -> Bool`.
* `QuickCull/FlagBadge.swift:6` is `struct FlagBadge(size:) { fill(.red) }` — always red triangle.
* `QuickCullCore/App/AppState.swift:27-30` has `pendingMoveCount/pendingMoveDestination/moveFailures/isMoving`, `pendingCommitCount/commitFailures/isCommitting`, `trasher/mover`. `handle(.toggleFlag)` calls `session.toggleFlag()` or `toggleFlags(ids:gridSelection)` for batch, rebuilding windows when projection changes. `requestMove(to:)`, `confirmMove()`, `requestCommit()`, `confirmCommit()` operate on `session.flaggedFiles` (all flagged) and `session.flaggedCount`.
* `QuickCull/ScrubView.swift:58,91` Filter `Picker` is 3 segments `All/Flagged( n)/Unflagged( n)` and toolbar has single `Move Flagged to Trash` (`trash` icon) and single `Move Flagged` (`folder` icon) buttons each querying `flaggedCount`.
* `QuickCull/ImageDisplayView.swift`, `QuickCull/FilmstripView.swift`, `QuickCull/GridView.swift`, `QuickCull/BadgedThumbnailView.swift` resolve `isFlagged = session.isFlagged(file)` then `FlagBadge()` if true.
* Tests `QuickCullCoreTests/SessionTests.swift`, `AppStateTests.swift`, `AppStateMoveTests.swift`, `MoveCommitTests.swift` cover single-flag, batch flag, filter projection, commit/move per-file outcomes.

Out-of-scope before this design: multi-color ratings, persistent flags, undo.

User (brainstorming 2026-08-19) chose:
* Exclusive single color per photo; same key toggles off; `X` on red → yellow (replace).
* `Move` and `Trash` via per-button `Menu` picking `Red / Yellow / Green / All Flagged` with live counts (not filter-driven).
* Filter bar `All + Red + Yellow + Green + Unflagged` (5 segments, counts). No aggregate `Flagged` segment in v1 (All Flagged available only via Menu).

## Approach (approved — A: Enum FlagColor dict)

Introduce `enum FlagColor { red, yellow, green }`. `Session` stores `flags: [String: FlagColor]` keyed by `file.id` (missing = unflagged). Exclusive invariant enforced by single dict write. `CullFilter` expands to 5 cases. `CullAction.toggleFlag(FlagColor)` carries color. `FlagBadge` tints by color.

Rejected: (B) three Sets `flaggedRed/Yellow/Green` — 3 sets to keep exclusive, duplicated branches. (C) raw `String` color — no type safety.

Mapping to keys/persistence:
* `Z` (keyCode 6) → `.red`, `X` (keyCode 7) → `.yellow`, `C` (keyCode 8) → `.green`. `CullKeyMap` decodes keyCode → `CullAction.toggleFlag(color)`.
* No disk persistence; flags remain in-memory per session, cleared on `startNewSession`/`importFiles` like today. Future persistence could `Codable` the dict.

## Visual — Toolbar, Badges, Filter

**Key → Color:** `Z` red `#FF3B30`, `X` yellow `#FFCC02`, `C` green `#30D158` (system red/yellow/green, or exact sRGB). Same triangle shape (`CornerTriangle` at `FlagBadge.swift:18`) filled with color, same `size 32/44` and shadow.

**Filter Picker — `ScrubView.swift:58`:**

Replace 3-segment `Picker("Filter", selection: session.filter)` with 5 segments:

```swift
Picker("Filter", selection: Binding(
    get: { appState.session?.filter ?? .all },
    set: { appState.setFilter($0) }
)) {
    Text("All").tag(CullFilter.all)
    Text("Red (\(appState.session?.flaggedCount(.red) ?? 0))").tag(CullFilter.red)
    Text("Yellow (\(appState.session?.flaggedCount(.yellow) ?? 0))").tag(CullFilter.yellow)
    Text("Green (\(appState.session?.flaggedCount(.green) ?? 0))").tag(CullFilter.green)
    Text("Unflagged (\(appState.session.map { $0.totalCount - ($0.flaggedCount(.red)+$0.flaggedCount(.yellow)+$0.flaggedCount(.green)) } ?? 0))").tag(CullFilter.keepers)
}
.pickerStyle(.segmented)
```

* Counts live via `Session.flaggedCount(color:)`. `keepers` is alias for `unflagged` (existing `CullFilter.keepers` remains, no rename to avoid churn).
* At narrow width toolbar may overflow; 5 segments still fit at `ScrubView.swift:38` toolbar (existing 3 segments fit, 5 is wider — acceptable, or SwiftUI wraps to overflow menu).

**Trash & Move Menus — `ScrubView.swift:77,91`:**

Replace single `Button` with `Menu`:

```swift
Menu {
    Button("Trash Red (\(appState.session?.flaggedCount(.red) ?? 0))", role: .destructive) {
        appState.requestCommit(color: .red); showCommitConfirm = true
    }.disabled((appState.session?.flaggedCount(.red) ?? 0)==0 || appState.isCommitting || appState.isMoving)
    Button("Trash Yellow (\(appState.session?.flaggedCount(.yellow) ?? 0))", role: .destructive) {
        appState.requestCommit(color: .yellow); showCommitConfirm = true
    }.disabled(...)
    Button("Trash Green (...)") { appState.requestCommit(color: .green); showCommitConfirm = true }.disabled(...)
    Button("Trash All Flagged (\(appState.session?.flaggedCount ?? 0))", role: .destructive) {
        appState.requestCommit(color: nil); showCommitConfirm = true
    }.disabled((appState.session?.flaggedCount ?? 0)==0 || ...)
} label: {
    if appState.isCommitting { ProgressView().controlSize(.small) }
    else { Label("Move Flagged to Trash", systemImage: "trash") }
}
.fontWeight(.light)
.disabled(appState.isCommitting || appState.isMoving) // Menu itself disabled while busy, items also gate counts
```

Similarly Move:

```swift
Menu {
    Button("Move Red (\(countRed))") {
        let panel = NSOpenPanel(); /* config as spec 2026-08-19-move-flagged-design.md:40 */ 
        if panel.runModal()==.OK, let dest = panel.url {
            appState.requestMove(to: dest, color: .red); showMoveConfirm = true
        }
    }.disabled(countRed==0 || appState.isCommitting || appState.isMoving)
    Button("Move Yellow (...)") { /* requestMove(to:dest, color:.yellow) */ }.disabled(...)
    Button("Move Green (...)") { ... color:.green ... }.disabled(...)
    Button("Move All Flagged (\(allCount))") { /* requestMove(to:dest, color:nil) */ }.disabled(allCount==0 || ...)
} label: {
    if appState.isMoving { ProgressView().controlSize(.small) }
    else { Label("Move Flagged", systemImage: "folder") }
}
.fontWeight(.light)
.disabled(appState.isCommitting || appState.isMoving)
```

* `requestCommit(color: FlagColor?)` and `requestMove(to:dest,color: FlagColor?)` store `pendingCommitColor`/`pendingMoveColor` (nil = all flagged).
* Alerts update to include color: `"Move \(pendingMoveCount) red file(s) to \"\(dest.lastPathComponent)\"?"` or `"Move \(pendingMoveCount) flagged file(s)"` when nil; similar for trash `"Move \(pendingCommitCount) yellow file(s) to Trash?"`.
* While `isCommitting||isMoving`, entire Menus disabled (like existing buttons) plus per-item disabled when its target count ==0.

**Badges — `ImageDisplayView.swift:55,FlagBadge.swift:6`:**

```swift
// in ImageDisplayView/ Filmstrip / Grid / BadgedThumbnailView
let flagColor = appState.session?.flagColor(for: file) // FlagColor?
if let c = flagColor, FlagBadgeLogic.shouldShow(isFlagged: c != nil, hasImage: hasImage) {
    FlagBadge(color: c, size: 32) // interior CornerTriangle().fill(color.swiftUIColor)
}
```

`FlagBadge` init: `init(color: FlagColor, size: CGFloat=32)` with `switch color { case .red: .red; .yellow: .yellow; .green: .green }`. Keep single triangle shape, same shadow.

**No HUD changes.**

## Data / Computation — `QuickCullCore/Session/*` + `QuickCullCore/App/AppState.swift` + `QuickCullCore/Commit/*`

**Model — new `QuickCullCore/Session/FlagColor.swift`:**

```swift
import Foundation
public enum FlagColor: String, CaseIterable, Sendable, Codable, Hashable {
    case red, yellow, green
    public var keyCode: UInt16 { switch self { case .red: 6 /* Z */; case .yellow: 7 /* X */; case .green: 8 /* C */ } }
    public var displayName: String { switch self { case .red: "Red"; case .yellow: "Yellow"; case .green: "Green" } }
    public var color: SwiftUI.Color { switch self ... } // optional, or keep in FlagBadge
}
```

**Filter — `QuickCullCore/Session/CullFilter.swift:4`:**

```swift
public enum CullFilter: CaseIterable, Hashable, Sendable {
    case all
    case red
    case yellow
    case green
    case keepers // alias unflagged, retains name for compat
    // flagged (all flagged) removed; aggregate accessed via Menu nil color, not filter
}
```

* Migration: existing `.flagged` → `.red`? No persistence, in-memory only. `Session.setFilter` callers pass `CullFilter` directly; old `flagged` usage in tests updated to `red`/`yellow`/`green` where aggregate needed → `nil` color path not filter.
* If aggregate flagged filter desired later, add `.flagged` as 6th case without breaking 5-segment UI.

**Session — `QuickCullCore/Session/Session.swift:13-193`:**

* Replace `public private(set) var flagged: Set<String> = []` with `private(set) var flags: [String: FlagColor] = [:]` plus computed `flagged: Set<String> { Set(flags.keys) }` for compat, and new helpers:

```swift
public func flagColor(for file: SessionFile) -> FlagColor? { flags[file.id] }
public func flagColor(for id: String) -> FlagColor? { flags[id] }
public func flaggedCount(_ color: FlagColor? = nil) -> Int {
    if let c = color { return flags.values.filter { $0 == c }.count }
    else { return flags.count }
}
public var flaggedCount: Int { flags.count } // existing, now computed
public func flaggedFiles(_ color: FlagColor? = nil) -> [SessionFile] {
    if let c = color { return allFiles.filter { flags[$0.id] == c } }
    else { return allFiles.filter { flags[$0.id] != nil } }
}
public var flaggedFiles: [SessionFile] { allFiles.filter { flags[$0.id] != nil } }
public func isFlagged(_ file: SessionFile) -> Bool { flags[file.id] != nil } // existing signature retained
public func isFlagged(_ file: SessionFile, color: FlagColor) -> Bool { flags[file.id] == color }
```

* `matches(_:filter:)`:

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

* `toggleFlag(color: FlagColor) -> Bool`:

```swift
@discardableResult
public func toggleFlag(color: FlagColor) -> Bool {
    guard !files.isEmpty else { return false }
    let id = currentFile.id
    if flags[id] == color { flags.removeValue(forKey: id) } else { flags[id] = color }
    guard filter != .all else { return false }
    // same projection logic as before but using new matches
}
```

* `toggleFlags(ids:Set<String>, color: FlagColor) -> Bool` — for batch grid: for each id in validIDs, if `flags[id]==color` remove else set to color.

* `remove(_:)` — `flagged` was `Set<String>`, now dict: `for id in ids { flags.removeValue(forKey: id) }` (instead of `subtract`). Keep `isFlagged`/`flaggedCount` computed.

* Keep `@Observable` on `Session` so `flags` dict mutation triggers UI.

**Keys — `QuickCullCore/Keys/CullKeyMap.swift:9`:**

```swift
public enum CullAction: Equatable { case next; case previous; case jumpForward; case jumpBack; case toggleFlag(FlagColor) }
private static let xKey: UInt16 = 7
private static let cKey: UInt16 = 8
public static func action(forKeyCode keyCode: UInt16) -> CullAction? {
    switch keyCode {
    case leftArrow: return .previous
    case rightArrow: return .next
    case downArrow: return .jumpForward
    case upArrow: return .jumpBack
    case zKey: return .toggleFlag(.red)
    case xKey: return .toggleFlag(.yellow)
    case cKey: return .toggleFlag(.green)
    default: return nil
    }
}
```

* Legacy `toggleFlag` without color (tests) → treat as `.red` for compat or keep overload `toggleFlag() -> toggleFlag(color:.red)`.

**Badge Logic — `QuickCullCore/Models/FlagBadgeLogic.swift:6`:**

Keep `shouldShow(isFlagged:hasImage:)`, but callers pass `isFlagged = flagColor != nil`. Add helper `color(for:)` if needed.

**FlagBadge — `QuickCull/FlagBadge.swift:6`:**

```swift
struct FlagBadge: View {
    var color: FlagColor
    var size: CGFloat = 32
    var body: some View {
        CornerTriangle().fill(switch color { case .red: .red; case .yellow: .yellow; case .green: .green })
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
    }
}
```

**Commit/Move — `QuickCullCore/Commit/TrashCommit.swift:37` + `MoveCommit.swift:41` + `AppState.swift:27-360`:**

* `AppState` adds `pendingCommitColor: FlagColor?`, `pendingMoveColor: FlagColor?`. `requestCommit(color: FlagColor?)`, `requestMove(to:dest,color: FlagColor?)` store count/destination/color. `confirmCommit()` and `confirmMove()` use `session.flaggedFiles(color)` and `session.flaggedCount(color)` for count. Failure alert text includes color when non-nil: `"Could not move 2 yellow file(s)"`.
* `pendingMoveDestination`/`pendingCommitColor` cleared in `cancelMove`/`cancelCommit`, `startNewSession`, `importFiles`.
* Guards `setViewMode`/`handle` already include `isMoving`/`isCommitting` (from 2026-08-19-move-flagged), keep.

**No change to `DecodeEngine`, `ImageCacheStore`, `ImageWindow`, `TrashCommit`/`MoveCommit` internals (they already take file array, now filtered by color before call).**

## Components — Summary

* New file `QuickCullCore/Session/FlagColor.swift` — enum `red/yellow/green` + `keyCode`/`displayName`.
* Modify `QuickCullCore/Session/CullFilter.swift:4` — 5 cases `all/red/yellow/green/keepers`, remove `flagged` (or keep deprecated alias mapping to `.red` with migration).
* Modify `QuickCullCore/Session/Session.swift:13-239` — `flags:[String:FlagColor]`, helpers `flagColor(for:)`, `flaggedCount(_:)`, `flaggedFiles(_:)`, `toggleFlag(color:)`, `toggleFlags(ids:color:)`, `matches`, `remove`.
* Modify `QuickCullCore/Keys/CullKeyMap.swift:9,19` — `CullAction.toggleFlag(FlagColor)`, add `xKey`/`cKey`.
* Modify `QuickCullCore/Models/FlagBadgeLogic.swift:6` — keep, callers use `flagColor != nil`.
* Modify `QuickCull/FlagBadge.swift:6` — `init(color: FlagColor)` tint.
* Modify `QuickCullCore/App/AppState.swift:27-360` — add `pendingCommitColor`/`pendingMoveColor`, `requestCommit(color:)`, `requestMove(to:color:)`, `flaggedFiles(color)` usage, guards already include `isMoving`.
* Modify `QuickCull/ScrubView.swift:58,77,91,130` — 5-segment Filter picker, two `Menu` for Trash/Move with per-color counts/disabled, alerts with color text, `onChange` for both failures already.
* Modify `QuickCull/ImageDisplayView.swift:55`, `QuickCull/FilmstripView.swift`, `QuickCull/GridView.swift`, `QuickCull/BadgedThumbnailView.swift` — resolve `flagColor` and pass to `FlagBadge(color:)`.
* Update tests `QuickCullCoreTests/SessionTests.swift`, `AppStateTests.swift`, `AppStateMoveTests.swift`, `CullKeyMapTests.swift`, `FlagBadgeLogicTests.swift` for color.

No new targets, no new dependencies.

## Data Flow

```
Z/X/C keyDown → KeyboardMonitor → CullKeyMap.action(forKeyCode:) → CullAction.toggleFlag(.red/.yellow/.green)
  → AppState.handle(.toggleFlag(color)) → Session.toggleFlag(color:) exclusive (same color toggles off, opposite replaces) → @Observable flags dict → ImageDisplayView/Filmstrip/Grid resolve flagColor(for: file) → FlagBadge(color:) or nil → re-render
Filter Picker .red → AppState.setFilter(.red) → Session.setFilter(.red) → projection = allFiles.filter { flags[id]==.red } → installWindows → scrub shows only red
Menu Trash Red → requestCommit(color:.red) → pendingCommitCount=flaggedCount(.red), pendingCommitColor=.red → alert "Move 3 red file(s) to Trash?" → Task { await confirmCommit() } → TrashCommit.commit(files: session.flaggedFiles(.red)) on detached → succeeded ids removed from Session.remove(succeeded) → flags removed, gridSelection pruned, commitFailures, pending cleared, isCommitting false → installWindows or empty → failure alert if needed. Move analogous with NSOpenPanel → requestMove(to:dest,color:.red) → MoveCommit.
```

Batch grid: `handle(.toggleFlag(color))` when `viewMode==.grid && !gridSelection.isEmpty` → `session.toggleFlags(ids:gridSelection, color:color)` → same exclusive logic per id.

## Error Handling & Edge Cases

* Press `Z` on red → `flags[id]==.red` → remove → unflagged, badge disappears, `keepers` projection gains it, `red` projection loses it (fallback to All if empty).
* Press `X` on red → `flags[id] != .yellow` → set to `.yellow` (replaces), red count -1, yellow +1, `red` filter loses it, `yellow` gains it, no stale.
* `Filter .red` showing only red, toggle `X` on current red → current red becomes yellow → drops out of `red` projection → `Session.toggleFlag(color:)` recomputes `newFiles = projection(.red)` then `files = newFiles`, `currentIndex = min(currentIndex, count-1)` or nearest match; if `newFiles.isEmpty` fallback to `.all`.
* Empty color filter placeholder: `setFilter(.yellow)` when no yellow → `files=[]`, `Filter` shows yellow segment selected, UI shows empty black placeholder (as today for `flagged` empty).
* Grid batch `toggleFlags(ids:[a,b], color:.yellow)` where `a` is red, `b` is green → both become yellow; `toggleFlags` validIDs intersection, then `flags[id]=.yellow` for both.
* Move/Trash Menu disabled states: per-item `.disabled(count(color)==0 || isCommitting||isMoving)` plus Menu itself `.disabled(isCommitting||isMoving)`. `isMoving||isCommitting` also disables View/Filter/New Session while busy (already).
* Commit/Move color nil = all flagged: `flaggedFiles(nil)` returns `allFiles.filter { flags[$0.id] != nil }` (any color), `flaggedCount(nil)` = `flags.count`. Alert says "flagged file(s)" without color qualifier.
* While `isMoving||isCommitting`, `setFilter`, `setCurrentIndex`, `handleGridDoubleClick`, `requestMove`, `requestCommit` guards prevent filter/index/destination changes (from prior fix d5e86ec) — keep, now also for color-specific requests.
* Narrow toolbar with 5 segments: at 800pt width, 5 segments may wrap or truncate; acceptable, existing 3-segment already handles overflow via SwiftUI toolbar overflow menu.
* Legacy `CullFilter.flagged` removed: any persisted filter (none, in-memory only) resets to `.all` via `init` default; no migration needed. Tests updated to use `.red`/`.yellow`/`.green`/`.keepers` where former `.flagged` used.
* No disk persistence for flags; `startNewSession`/`importFiles` clear `flags` dict like today (via `flags.removeAll()` in `remove` path or explicit clear).

## Testing

*Unit — `QuickCullCoreTests/SessionTests.swift` (modify):*
  * Exclusive: `Z` red then `Z` again → unflagged; `Z` red then `X` → yellow, red count 0, yellow 1.
  * `flaggedCount(.red/.yellow/.green/nil)` and `flaggedFiles(.color)` return per-color and all.
  * `matches` projections: `all` = `totalCount`, `red` only red, `yellow` only yellow, `green` only green, `keepers` = unflagged.
  * `toggleFlag(color:)` under `filter != .all` drops out correctly, fallback to All when empty, `currentIndex` nearest-match.
  * `toggleFlags(ids:color:)` batch exclusive add/replace.
  * `remove` with per-color flagged files: `session.remove(flaggedFiles(.red))` leaves yellow/green.

*Unit — `QuickCullCoreTests/Keys/CullKeyMapTests.swift` (modify):*
  * `keyCode 6 → .toggleFlag(.red)`, `7 → .toggleFlag(.yellow)`, `8 → .toggleFlag(.green)`, other keys unchanged.

*Unit — `QuickCullCoreTests/FlagBadgeLogicTests.swift` (modify):*
  * `shouldShow` still `isFlagged && hasImage`, but caller now with `flagColor != nil`.

*Unit — `QuickCullCoreTests/App/AppStateTests.swift` (modify):*
  * `handle(.toggleFlag(.red))` flags red, counts per color, `setFilter(.red)` rebuilds windows over red projection.

*Unit — `QuickCullCoreTests/App/AppStateMoveTests.swift` + `AppStateMoveTests` equivalent for commit (modify):*
  * `requestCommit(color:.red)` → `pendingCommitCount==countRed`, `confirmCommit` removes only red, yellow/green remain, gridSelection pruned per color.
  * `requestMove(to:dest,color:.yellow)` → moves only yellow, auto-rename still.

*UI smoke — manual (`./start.sh`, import 5 RAWs, flag mix):*
  * `Z` red triangle, `X` yellow, `C` green, same key toggles off, `X` on red → yellow.
  * Filter `All`, `Red(2)`, `Yellow(1)`, `Green(1)`, `Unflagged(1)` segments live; clicking each shows only that color, empty shows placeholder.
  * Trash Menu → `Trash Red (2)` moves 2, leaves others; `Trash All Flagged (4)` moves all; failure alert per color.
  * Move Menu → picker each time, `Move Yellow` moves only yellow to folder with auto-rename `name 1.ext` on collision.
  * Grid batch: select 3, `X` → all 3 become yellow, `Filter Yellow` shows 3.
  * While moving, View/Filter/New Session/Trash/Move disabled, spinner.

## Files

* New: `QuickCullCore/Session/FlagColor.swift` — `enum FlagColor` `red/yellow/green` `keyCode/displayName`.
* Modify: `QuickCullCore/Session/CullFilter.swift:4` — `all/red/yellow/green/keepers` (remove `flagged`).
* Modify: `QuickCullCore/Session/Session.swift:13-239` — `flags:[String:FlagColor]`, computed `flagged`, helpers per-color, `matches`, `toggleFlag(color:)`, `toggleFlags(ids:color:)`, `remove`.
* Modify: `QuickCullCore/Keys/CullKeyMap.swift:9,19` — `CullAction.toggleFlag(FlagColor)`, `xKey/cKey`.
* Modify: `QuickCullCore/Models/FlagBadgeLogic.swift:6` — keep, callers pass `flagColor != nil`.
* Modify: `QuickCull/FlagBadge.swift:6` — `init(color:FlagColor)` tint.
* Modify: `QuickCullCore/App/AppState.swift:27-360` — `pendingCommitColor/pendingMoveColor`, `requestCommit(color:)`, `requestMove(to:color:)`, per-color `flaggedFiles`/`count`, guards already include `isMoving`.
* Modify: `QuickCull/ScrubView.swift:58,77,91,130` — 5-segment Filter picker, two `Menu` with per-color counts/disabled, alerts with color text.
* Modify: `QuickCull/ImageDisplayView.swift:55`, `QuickCull/FilmstripView.swift`, `QuickCull/GridView.swift`, `QuickCull/BadgedThumbnailView.swift` — resolve `flagColor` → `FlagBadge(color:)`.
* Modify tests: `CullKeyMapTests`, `FlagBadgeLogicTests`, `SessionTests`, `AppStateTests`, `AppStateMoveTests`, `TrashCommitTests` (if per-color).

No new targets, no new dependencies (AppKit, SwiftUI, Foundation).

## Acceptance Criteria

* `Z` flags red triangle, `X` yellow, `C` green, same key toggles off, different key replaces color; exclusive invariant holds for single and batch `Grid` toggle.
* `FlagBadge` shows correct color per file in viewer/filmstrip/grid, hidden when unflagged or no image.
* Filter picker has 5 segments `All/Red(n)/Yellow(n)/Green(n)/Unflagged(n)` live counts; each filters to only that color (keepers = unflagged), empty shows placeholder.
* Trash and Move each are `Menu` with `Red/Yellow/Green/All Flagged` items, per-item count, disabled when target count ==0 or busy; selecting item prompts confirm (`Move` also shows folder picker first) and performs color-scoped commit/move (auto-rename for Move) removing only that color's succeeded files, keeping failed flagged, pruning gridSelection, disabling chrome while busy.
* Build and full suite green: existing 149 + new/updated color tests.

