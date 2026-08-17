# Grid View — Design

Date: 2026-08-17
Status: approved design (pre-plan)

## Purpose

Add a grid view of all images as a toggle alternative to the existing scrub view (large image + filmstrip). Photographers can see the full session at a glance, multi-select with Shift/Cmd, flag with `Z`, and double-click to jump to scrub at that photo. The existing `All/Flagged/Keepers` filter applies to both views.

## Background

Today `ScrubView` is `ImageDisplayView` (fit-to-window, ±1 display window) + `FilmstripView` (`LazyHStack`, `thumbWindow` radius 30). `Session` owns `allFiles` privately and exposes the filtered projection as `files`; `AppState` rebuilds both `ImageWindow`s on filter/commit/flag-drop-out. The grid reuses this projection and thumbnail pipeline — no new decode path.

## Approach (approved)

**Option A — Reuse `thumbWindow` + lightweight selection state.**

`ScrubView` becomes a container toggling between scrub and grid; a new `GridView` renders `session.files` in a `LazyVGrid` reusing `thumbWindow` thumbnails via a new `ensureLoaded(indices:)` helper. Selection is a `Set<String>` of `SessionFile.id` in `AppState`; `Z` batch-flags the selection; double-click sets `currentIndex` and flips to scrub. Filter is free (grid iterates the same projection).

Rejected alternatives: (B) dedicated unbounded `GridWindow` — more memory, second pipeline; (C) direct `cache` reads with no `ImageWindow` — duplicates logic, loses shared eviction.

## Architecture

- No new targets. 3 files changed, 1 new.
- `QuickCull/GridView.swift` — new, pure SwiftUI.
- `QuickCullCore/Session/Session.swift` — add `toggleFlags(ids:)`.
- `QuickCullCore/App/AppState.swift` — add `viewMode` + `gridSelection` + grid `Z` branch.
- `QuickCullCore/Window/ImageWindow.swift` — add `ensureLoaded(indices:)`.
- Nothing else (`DecodeEngine`, `ImageCacheStore`, `TrashCommit`, `RawFileIdentity`) changes.

```
ScrubContainerView (toolbar owns viewMode + filter)
  ├─ .scrub → ImageDisplayView + FilmstripView  (existing)
  └─ .grid  → GridView  (LazyVGrid over session.files)
Session (allFiles → files projection)
ImageWindow.thumbnails (radius 30 + ensureLoaded for grid viewport)
```

## Model — `QuickCullCore/Session`

Add batch-flag method; existing single-flag API unchanged:

```swift
/// Batch-toggles flags for ids in the session. Recomputes the projection
/// once, resolves currentIndex like setFilter (keep current if still
/// visible, else nearest match forward-tie, clamp; empty projection
/// falls back to .all with files=allFiles). Returns whether the
/// projection changed.
func toggleFlags(ids: Set<String>) -> Bool
```

- Iterates `ids` intersecting `allFiles`, flips `flagged`, then `files = projection(for: filter)`.
- Empty-projection fallback and `flaggedFiles` (sourced from `allFiles`) unchanged.
- Preserves order via `allFiles` projection.

`toggleFlag() -> Bool` stays for scrub's single-current path; batch shares `matches`/`projection`/`nearestMatch` helpers.

## App Flow — `QuickCullCore/App/AppState`

```swift
enum ViewMode { case scrub, grid }

@Observable var viewMode: ViewMode = .scrub
var gridSelection: Set<String> = []  // ids, not indices — stable across filters
private var gridAnchorID: String?    // for Shift-range
```

- `setViewMode(_ mode: ViewMode)` — flip only; no window rebuild; guards `phase == .scrubbing`; selection preserved; reset to `.scrub` + `gridSelection=[]` on new `importFiles`.
- `selectSingle(id:)` / `toggleSelection(id:)` / `selectRange(to:)` — range is `session.files` order between anchor and target.
- `handleGridToggleFlag()` — if `gridSelection.isEmpty` no-op; else `session.toggleFlags(ids: gridSelection)` then `if changed { installWindows(for: session.files) } else { syncWindows() }`; prune `gridSelection` to ids still in `allFiles`; drop ghost ids only on commit removal.
- `handle(.toggleFlag)` now branches: if `viewMode==.grid && !gridSelection.isEmpty` → grid batch; else → `session.toggleFlag()` (scrub single).
- `setCurrentIndex(_:)` + `syncWindows()` on double-click jump: `session.setIndex(idx)` then `viewMode=.scrub`.
- `setFilter`, `confirmCommit`, `remove` — unchanged except they prune `gridSelection` to `allFiles` survivors and call `installWindows(for: session.files)` (grid and scrub share the same call).

## Image Loading — `QuickCullCore/Window/ImageWindow`

```swift
/// Ensures thumbnails for arbitrary indices are in-flight/loaded,
/// same eviction as setCurrent but without moving currentIndex.
func ensureLoaded(indices: [Int])
```

- Called from `GridView.onAppear` for each visible cell index.
- Reuses `loader` closure (`cache.cacheURL` → `loadJPEG(maxPixelSize: 320)` off main actor).
- Eviction keeps `window(around: currentIndex) ∪ ensureLoaded` indices; viewport thumbs (~20–40) + scrub window 61 stays bounded even for 500+ files. `LazyVGrid` ensures only viewport cells call it.

## UI — `QuickCull`

### ScrubContainerView (`QuickCull/ScrubView.swift`)

Becomes container:

```swift
VStack(spacing: 0) {
  if appState.viewMode == .scrub {
    ImageDisplayView(); Divider(); FilmstripView()
  } else {
    GridView()
  }
}
.toolbar {
  ToolbarItem { Picker("View", selection: $appState.viewMode) {
    Text("Strip").tag(ViewMode.scrub); Text("Grid").tag(ViewMode.grid)
  }.pickerStyle(.segmented) }
  ToolbarItem { Filter picker (All/Flagged/Keepers) — existing }
  ToolbarItem { Trash button — existing }
}
.disabled(appState.isCommitting)
```

- Both pickers disabled while `isCommitting`.
- Filter picker visible in both modes, same binding `appState.setFilter`.
- `ScrubView` name may be kept or renamed to `ScrubContainerView`; call sites in `RootView` updated.

### GridView (`QuickCull/GridView.swift`) — new

- `ScrollView` + `LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 8)], spacing: 8)`, padding 12.
- `ForEach(session.files.indices, id: \.self)` → `GridCell`:
  - `ZStack(alignment:.topTrailing)` with `thumbWindow.image(at: index)` → `Image(decorative:scale:).resizable().scaledToFill().frame(width:160,height:108).clipped()` else `Rectangle().fill(.quaternary).frame(160,108)`.
  - `if isFlagged { FlagBadge(size:24).shadow(...) }`
  - `Rectangle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth:2)`
- No filename label in v1 (cleaner culling).
- Selection: `gridSelection.contains(file.id)`.
- Gestures: `onTapGesture` with `NSEvent.modifierFlags` for Shift/Cmd; `onTapGesture(count:2)` → `session.setIndex` + `viewMode=.scrub`. `Z` via `KeyboardMonitor`/`CullKeyMap` (no new shortcut).
- `onAppear` per cell → `thumbWindow?.ensureLoaded(indices:[index])`.
- Empty `session.files` → centered `Text("No photos in this filter")` on black, like `ImageDisplayView` empty-filter case.
- Accessibility: `accessibilityLabel = file.url.lastPathComponent`, traits `.isButton/.isSelected`.

## Data Flow

```
Launch → prepareForLaunch (wipe cache)
Import → Session(allFiles, files, filter=.all) → DecodeEngine → finishDecoding → installWindows → phase=.scrubbing, viewMode=.scrub
Toggle [Strip|Grid] → AppState.viewMode flip (no window work)
Grid single/Cmd/Shift click → AppState.gridSelection (+ anchor)
Z in grid → AppState.handleGridToggleFlag → Session.toggleFlags(ids) → installWindows/syncWindows → FlagBadge updates
Double-click → AppState.setCurrentIndex → syncWindows → viewMode=.scrub
Filter/Commit/Flag-drop-out → Session projection recompute → AppState pruning + installWindows (both views)
```

## Edge Cases

| Case | Behavior |
|------|----------|
| Empty session / all decodes failed | `phase==.empty`, container not shown |
| Filter yields empty (`session.files==[]`) | Grid shows placeholder `Text("No photos in this filter")`, not fallback to All |
| Batch flag in Keepers/Flagged drops photos | Dropped ids stay in `gridSelection` but disappear from `files` (ghost); switching filter to All reveals them flagged |
| Batch flag empties projection | `toggleFlags` falls back `filter=.all`, `files=allFiles`, grid shows all, selection kept, current pinned to anchor |
| Commit while in grid | `confirmCommit` → `session.remove` → prune `gridSelection` to survivors, `installWindows`, stays in grid if not empty, else `phase=.empty` |
| Rapid Z while thumbs loading | `flagged` is `@Observable`; badges update over placeholder |
| 500+ photos | `LazyVGrid` + `ensureLoaded` viewport-only; memory bounded to viewport + 61 |
| Double-click during commit | Toolbar + handler guard `!isCommitting`, no-op |

## Testing

### Session (`QuickCullCoreTests/SessionTests.swift`)

- `toggleFlags` single/multiple/mixed membership, order preservation, return value true iff projection size changed in non-All, false in All.
- Drop-out: batch in Keepers/Flagged removes flagged/keepers from `files`, index clamped; empty-projection fallback to All with current pinned to anchor id.
- `flaggedFiles` after batch still sourced from `allFiles`.
- `remove` prunes correctly after batch.

### AppState (`QuickCullCoreTests/AppStateTests.swift`)

- `viewMode` defaults `.scrub`, `setViewMode` flips without window rebuild, reset on new import.
- `gridSelection` single/Cmd toggle/Shift range in `session.files` order; pruned after `toggleFlags` ghost and after `confirmCommit`.
- `handle(.toggleFlag)` branches: grid with selection → batch, grid empty → single, scrub → single.
- `ensureLoaded` — after `finishDecoding`, `ensureLoaded([0,90,180])` populates those indices (via `waitUntilSettled`).

### ImageWindow (`QuickCullCoreTests/ImageWindowTests.swift`)

- `ensureLoaded` loads arbitrary indices beyond radius, keeps them until evicted by count change, respects `waitUntilSettled`.

No UI snapshot tests; manual QA for grid layout/scroll/selection/keyboard.

## Out of Scope

- Arrow-key navigation in grid (defer; Z + mouse covers v1).
- Filename/caption in grid cells.
- Persistent selection or viewMode across imports/sessions.
- Drag-reorder, zoom/loupe in grid.
- Keyboard shortcut for grid toggle (toolbar only in v1).
