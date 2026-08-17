# Split View (Current + Next) — Design

Date: 2026-08-17
Status: approved design (pre-plan) — v1: HSplit with divider, left=current only

## Purpose

Add a Split view that shows current image and image+1 side-by-side in a horizontal split. Photographers can compare consecutive shots while culling without leaving the scrub flow. Split is a new third view mode alongside Single and Grid, reusing the existing filter, flag, zoom, and HUD semantics with minimal new state.

## Background

Single view today is `ImageDisplayView` (fit-to-window zoomable `CGImage` on black, `FlagBadge` top-trailing, pinch 1×…4× + double-click 2×, drag pan, `hudVisible` sidebar 240pt + Divider left of viewer) + `FilmstripView` (100×64 thumbs + titles) + `ScrubView` toolbar `Metadata | New Session | Single/Grid | Filter | Trash` (all `.fontWeight(.light)`, `hudVisible` hoisted, resets on `phase==.empty|decoding` and `viewMode` toggle). `GridView` is `LazyVGrid` adaptive. `Session` owns `files` projection, `currentIndex`, `flagged`. `AppState` owns `phase`/`viewMode`/`gridSelection`/`thumbWindow`/`gridThumbs`/`displayImages` via `ImageWindow` (radius 1 for display = current ±1, 320px for thumbs, `gridThumbs` radius=count). Navigation `←/→` moves ±1, `↑/↓` jumps ±10, `Z` toggles flag. Request is: split view showing current and image+1 in split, picker becomes Single|Split|Grid, both shift by 1 overlapping, left is current only (flag/HUD/zoom target), right is preview fit-only, last shows single placeholder.

## Approach (approved)

**Option A — HSplit with Divider (chosen).**

Extend `ViewMode` to `case split` and `ScrubView` picker to `Single | Split | Grid` (Split middle). In `ImageDisplayView`, when `viewMode==.split`, render `SplitViewer` as `HStack(spacing:0) { LeftPane(current) | Divider (1pt, only when both panes) | RightPane(next or placeholder) }` inside the viewer area. `LeftPane` is the existing `ZoomableImageView` (keeps `hudVisible` sidebar to its left, zoom bindings, `FlagBadge`, fileID-driven pan reset, `fittedSize`/`clampedOffset`). `RightPane` is a fit-only `Image` (no zoom/pan/tap, `opacity 0.92` dimmed to signal secondary, `scaledToFit` in its own `GeometryReader`). If metadata HUD is visible, outer layout is `HStack { Metadata 240 | Divider | SplitViewer flex }` — HUD leftmost, split viewer flex to the right, filmstrip below spans full width. `GridView` unchanged.

Rejected: (B) Vertical stacked — wastes horizontal space, filmstrip squeeze, worse for landscape raws; (C) Sync zoom both panes — more complex, not requested, doubles zoom state and hit-test.

## Architecture

- No new targets. 3 files changed, 0 new (reuse `ZoomableImageView`/`FitImage` extraction).
- `QuickCullCore/App/AppState.swift` — extend `ViewMode` to `.split`, add derived `splitSecondIndex` helper (or computed in view), ensure `syncWindows()` covers both indices and `setViewMode`/`phase` resets handle `.split` like `.scrub`/`.grid`.
- `QuickCull/ScrubView.swift` — `View` picker adds `Split` tag (`Single | Split | Grid`), no new button, toolbar order stays `Metadata | New Session | Single/Split/Grid | Filter | Trash` with `.fontWeight(.light)`; existing `onChange(phase/viewMode)` resets `hudVisible+zoom` on any viewMode toggle (covers `Split` round-trip).
- `QuickCull/ImageDisplayView.swift` — refactor viewer to branch on `appState.viewMode`: `Single` → existing single viewer; `Split` → `SplitViewer` (Left zoomable + Right fit/placeholder, divider, `HStack`). Extract `ZoomableImageView` reusable and add lightweight `FitImageView` for right pane. Keep outer `HStack` with optional `MetadataHUDView` sidebar 240pt + `Divider` left of viewer (existing v2 layout) so Split with HUD becomes `HStack { HUD 240 | Divider | SplitViewer flex }`.
- Nothing else (`Session`, `ImageWindow`, `DecodeEngine`, `GridView`, `FilmstripView`, `ImageMetadataProvider`) changes beyond reuse.

```
ScrubView (toolbar: Metadata | New Session | Single/Split/Grid | Filter | Trash)
  ├─ .scrub → HStack { [if hudVisible: Metadata 240|Divider] | SingleViewer (Zoomable, FlagBadge) } + Filmstrip
  ├─ .split → HStack { [if hudVisible: Metadata 240|Divider] | SplitViewer }
  │            SplitViewer: HSplit { LeftPane(current, Zoomable+FlagBadge+HUD-target) | Divider | RightPane(next fit-only dimmed or placeholder) } + Filmstrip below
  └─ .grid  → GridView (unchanged)
Session.files + currentIndex → leftFile/rightFile? → AppState.displayImages (radius 1 covers both)
```

## Model — `QuickCullCore/App/AppState`

```swift
public enum ViewMode: Equatable, Sendable { case scrub, split, grid } // was scrub/grid

public var splitSecondIndex: Int? { // derived helper for view (or view computes)
    guard let s = session, s.files.indices.contains(s.currentIndex+1) else { return nil }
    return s.currentIndex+1
}
// No new stored state; hudVisible/zoom stay in ScrubView (already hoisted).
// setViewMode(_:) already guards phase==.scrubbing and viewMode!=mode — extend to allow .split.
// syncWindows() — extend to cover both indices:
private func syncWindows() {
    guard let session else { return }
    thumbWindow?.setCurrent(session.currentIndex)
    displayImages?.setCurrent(session.currentIndex) // radius 1 covers current±1, but ensure next is loaded
    // Also ensure next is in-flight if just outside radius due to edge; optional:
    // if let next = splitSecondIndex { displayImages?.ensureLoaded(indices: [next]) } // if using ensureLoaded API
}
```

- `setViewMode(.split)` guard same as other modes (`phase==.scrubbing`, not `isCommitting`).
- No new `Session` logic; `files` projection and `currentIndex` move unchanged. Split derives `rightFile` as `files.indices.contains(currentIndex+1) ? files[currentIndex+1] : nil`.
- `isCommitting` disables `View` picker (existing), so Split toggle blocked mid-commit.

## UI — `QuickCull/ScrubView` (picker)

Current:
```swift
Picker("View", selection: Binding(get:{appState.viewMode}, set:{appState.setViewMode($0)})) {
    Text("Single").tag(ViewMode.scrub)
    Text("Grid").tag(ViewMode.grid)
}.pickerStyle(.segmented).fontWeight(.light).disabled(appState.isCommitting)
```

Becomes:
```swift
Picker("View", selection: Binding(get:{appState.viewMode}, set:{appState.setViewMode($0)})) {
    Text("Single").tag(AppState.ViewMode.scrub)
    Text("Split").tag(AppState.ViewMode.split)
    Text("Grid").tag(AppState.ViewMode.grid)
}.pickerStyle(.segmented).fontWeight(.light).disabled(appState.isCommitting)
```

Order `Single | Split | Grid`, Split middle. Keep `.fontWeight(.light)` consistent. Toolbar order `Metadata | New Session | Single/Split/Grid | Filter | Trash` unchanged.

Existing resets already cover Split:
```swift
.onChange(of: appState.viewMode) { old,new in if old!=new { zoomScale=1; hudVisible=false } }
.onChange(of: appState.phase) { _,new in if new==.empty||isDecoding { hudVisible=false; zoom... } }
```

## UI — `QuickCull/ImageDisplayView` (SplitViewer)

Branch on `appState.viewMode` inside `ImageDisplayView` `else if let cgImage` (or higher in `ScrubView`):

```swift
@Binding var hudVisible: Bool // existing

var body: some View {
  let index = session?.currentIndex ?? 0
  let leftFile = files.indices.contains(index) ? files[index] : nil
  let rightIndex = index+1
  let rightFile: SessionFile? = files.indices.contains(rightIndex) ? files[rightIndex] : nil
  let leftCG = displayImages?.image(at: index) ?? thumbWindow?.image(at: index)
  let rightCG = rightFile != nil ? (displayImages?.image(at: rightIndex) ?? thumbWindow?.image(at: rightIndex)) : nil

  if appState.viewMode == .split {
    HStack(spacing: 0) {
      if hudVisible, let file = leftFile {
        MetadataHUDView(file: file, cgImage: leftCG).frame(width:240).background(.ultraThinMaterial)
          .transition(.move(edge:.leading).combined(with:.opacity))
        Divider()
      }
      // Split viewer
      HStack(spacing: 0) {
        // Left — current, zoomable, flag target, HUD left file
        GeometryReader { geo in
          ZStack {
            Color.black
            if let img = leftCG, let file = leftFile {
              ZoomableImageView(cgImage: img, fileID: file.id, scale: $zoomScale, lastScale:$zoomLastScale, offset:$zoomOffset, lastOffset:$zoomLastOffset)
                .overlay(alignment:.topTrailing){ FlagBadgeOverlay(file:file) }
            } else { Color.black }
          }.frame(width:geo.size.width,height:geo.size.height)
        }.clipped()
        if rightFile != nil { Divider() } // between panes only when both
        // Right — next preview, fit only, dimmed, no flag/zoom/HUD
        GeometryReader { geo in
          ZStack {
            Color.black
            if let img = rightCG {
              Image(decorative: img, scale:1).resizable().aspectRatio(contentMode:.fit)
                .frame(width: fittedSize(for: img, in: geo.size).width, height: fittedSize(for: img, in: geo.size).height)
                .opacity(0.92)
            } else {
              VStack(spacing:8){ Image(systemName:"photo.slash").font(.title2).foregroundStyle(.secondary)
                                 Text("No next image").font(.caption).foregroundStyle(.secondary) }
            }
          }.frame(width:geo.size.width,height:geo.size.height)
        }.clipped()
      }
    }
    .overlay(alignment:.topTrailing){ /* no badge for right */ }
    .animation(.easeInOut(duration:0.2), value: hudVisible)
    .animation(.easeInOut(duration:0.15), value: appState.viewMode)
  } else {
    // Existing Single viewer: HStack { [HUD 240|Divider] | GeometryReader Zoomable } + FlagBadge
  }
}
```

- `MetadataHUDView` only for left file (current), not right.
- Right pane `Fitted` via helper `fittedSize(for:in:)` (reuse `ZoomableImageView`’s math, but scale fixed 1).
- Filmstrip below `SplitViewer` spans full width (outside `ImageDisplayView`’s outer `HStack`, in `ScrubView` `VStack` below `ImageDisplayView`), highlight stays on left/current `currentIndex`.
- Placeholder when `rightFile==nil` (last image): `Color.black` + `Text("No next image")` centered, same `GeometryReader` size as left, `Divider` not shown.
- Transitions: HUD slide+fade via existing `.transition`, split panes have no transition (instant).

## Data Flow

```
Launch→Import→phase==scrubbing, viewMode default .scrub
  Picker Single|Split|Grid → AppState.setViewMode → ScrubView onChange resets zoom/hud → ImageDisplayView branches
Split:
  currentIndex → leftFile/rightFile? → leftCG/rightCG from displayImages/thumbWindow
  Toolbar Filter/Flag: Z flags leftFile only (session.isFlagged(leftFile)), HUD shows left metadata
  Arrow →: session.move(by:1) → left becomes previous right (shifts both by 1 overlapping)
  Arrow ←: move -1 similarly
  Last: rightCG nil → placeholder
  New Session/phase empty/decoding/viewMode toggle → reset hudVisible+zoom, viewMode→.scrub
```

## Edge Cases

| Case | Behavior |
|------|----------|
| Hidden HUD (default) in Split | `HStack` is `SplitViewer` full width (no HUD 240), divider only between panes when both present |
| HUD visible in Split | Outer `HStack { HUD 240|Divider | SplitViewer flex }` — image pair shrinks to `full-241`, both panes remain fully visible side-by-side, divider between HUD and viewer + divider between panes (two dividers) |
| Filter yields 1 file | Left shows file, right placeholder `No next image` |
| Filter yields 0 | `Color.black` (no split) |
| Rapid scrub key repeat | `displayImages.setCurrent(currentIndex)` loads left ±1; right (current+1) is within radius 1, so already covered; no extra `ensureLoaded` needed, but acceptable to call |
| Missing thumb for right | Placeholder `Rectangle quaternary` inside right `GeometryReader` (like Grid placeholder) or keep fit logic with nil → placeholder text |
| Zoomed in Split | Zoom bindings only left pane (`ScrubView` hoisted); right pane fixed fit 1×; pan clamped to left container only |
| Flag badge | Only left pane `FlagBadge` (right no badge, no flag target) |
| Grid/Single unchanged | `GridView`/`Single` viewer untouched; `Filter` projection `files` used identically for left/right derivation |

## Testing

- **Unit — `AppStateTests`**: add `testSplitViewModeToggleAndShift` — import 3 files, `setViewMode(.split)`, assert `viewMode==.split`, `splitSecondIndex==1`, `move(by:1)` → left `b` right `c`, at last index `right==nil` placeholder (via `session.files` check). Also verify `setViewMode(.split)` disabled when `isCommitting` and ignored when `phase!=.scrubbing`.
- **Manual QA:**
  - Picker shows `Single | Split | Grid` (`Split` middle, light weight); default `Single`.
  - Switch to `Split` → left shows current, right shows next side-by-side with divider, both fully visible, left has flag badge if flagged, right dimmed no badge.
  - `→`/`←` shifts both by 1 overlapping; at last right shows `No next image` black placeholder, divider not shown after left.
  - `Z` flags left only (filmstrip badge left, count increments 1).
  - `Metadata` at far left separate from `Trash` far right — toggle shows left 240 HUD sidebar + divider left of split viewer; image pair shrinks but remains fully visible, not occluded; hide returns full width.
  - Zoom pinch/double-click/drag only left pane; right fit.
  - Filter `Flagged` with 1 → left shows keeper, right placeholder.
  - Empty filter → black.

## Out of Scope

- Grid with split, vertical split, or resizable divider.
- Synchronized zoom both panes, or selecting right pane to make current.
- Right pane flag/HUD/badges or independent zoom.
- Keyboard shortcut for Split (toolbar only).
- Persisting `hudVisible` or `viewMode` across launches.
