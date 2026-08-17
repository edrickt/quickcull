# Split View (Current + Next) — Design

Date: 2026-08-17 (amended v2: synchronized zoom both panes, no divider but gap)
Status: approved design (pre-plan) — HSplit with gap, left=current, synchronized zoom

## Purpose

Add a Split view that shows current image and image+1 side-by-side in a horizontal split. Photographers can compare consecutive shots while culling without leaving the scrub flow. Split is a new third view mode alongside Single and Grid, reusing the existing filter, flag, and HUD semantics with synchronized zoom on both panes and no dividing line but kept spacing so both images stay fully visible.

## Background

Single view today is `ImageDisplayView` (fit-to-window zoomable `CGImage` on black, `FlagBadge` top-trailing, pinch 1×…4× + double-click 2×, drag pan, `hudVisible` sidebar 240pt + Divider left of viewer) + `FilmstripView` (100×64 thumbs + titles) + `ScrubView` toolbar `Metadata | New Session | Single/Split/Grid | Filter | Trash` (all `.fontWeight(.light)`, `hudVisible` hoisted, resets on `phase==.empty|decoding` and `viewMode` toggle). `GridView` is `LazyVGrid` adaptive. `Session` owns `files` projection, `currentIndex`, `flagged`. `AppState` owns `phase`/`viewMode`/`gridSelection`/`thumbWindow`/`gridThumbs`/`displayImages` via `ImageWindow` (radius 1 for display = current ±1, 320px for thumbs, `gridThumbs` radius=count). Navigation `←/→` moves ±1, `↑/↓` jumps ±10, `Z` toggles flag. Previous Split spec had `HSplit` with `Divider` between panes and left-only zoom (right fit-only). Refinement: zooming in Split must zoom **both** images fully synchronized (shared scale/offset, drag/double-click/pinch on either affects both), and the `Divider` between images must be removed but the **space** kept (8pt black gap).

## Approach (approved)

**Option A — HSplit with gap, shared zoom state (chosen for v2).**

Extend `ViewMode` to `case split` and `ScrubView` picker to `Single | Split | Grid` (Split middle, already done). In `ImageDisplayView`, when `viewMode==.split`, render `SplitViewer` as `HStack(spacing:8) { LeftPane(current) | RightPane(next or placeholder) }` inside the viewer area — **no `Divider`**, 8pt `Color.black` gap shows as space. **Both panes share the hoisted `ScrubView` zoom bindings** (`zoomScale/lastScale/offset/lastOffset`): each pane is a `ZoomableImageView` reading same `scale`/`offset`, with gestures on **both** panes updating the shared state, so pinch/double-click/drag on either zooms/pans both together identically (`fileID` `onChange` still recenters shared `offset` for new pair, `container` `onChange` reclamps against each pane’s `fittedSize` but writes to shared `offset`). If metadata HUD is visible, outer layout is `HStack(spacing:8) { Metadata 240 | SplitViewer flex }` — HUD leftmost, 8pt gap, then split viewer flex; filmstrip below spans full width. `GridView` unchanged.

Rejected: (B) Vertical stacked — wastes horizontal space; (C) Keep left-only zoom — violates new “zoom both” requirement; (D) Keep Divider — violates “remove dividing line”.

## Architecture

- No new targets. 2 files changed, 0 new (reuse `ZoomableImageView` for both panes).
- `QuickCullCore/App/AppState.swift` — already extended `ViewMode` to `.split` (done), `syncWindows()` already covers both indices via radius 1; no further change needed for synchronized zoom (zoom is view state in `ScrubView`, not `AppState`).
- `QuickCull/ScrubView.swift` — already has `View` picker `Single|Split|Grid` and `hudVisible` hoist; no change for synchronized zoom (zoom bindings already hoisted).
- `QuickCull/ImageDisplayView.swift` — refactor Split branch: replace `Left Zoomable + Right FitImage (fixed 1×)` with **two `ZoomableImageView` sharing same bindings**; change `HStack(spacing:0)` + conditional `Divider` to `HStack(spacing:8)` with no `Divider` (keep outer `HStack` HUD 240 + gap 8 + SplitViewer). Right pane now also `ZoomableImageView` with shared state and `FlagBadge`? No, flag badge stays left only (right no badge per spec). Both panes get gestures.
- Nothing else (`Session`, `ImageWindow`, `DecodeEngine`, `GridView`, `FilmstripView`, `ImageMetadataProvider`) changes.

```
ScrubView (toolbar: Metadata | New Session | Single/Split/Grid | Filter | Trash)
  ├─ .scrub → HStack { [HUD 240 + gap 8] | SingleViewer (Zoomable) } + Filmstrip
  ├─ .split → HStack { [HUD 240 + gap 8] | SplitViewer } // HUD gap 8, viewer flex
  │            SplitViewer: HSplit(spacing:8) { Left(current Zoomable+FlagBadge+HUD-target, shared zoom) | Right(next Zoomable shared zoom, dimmed? or not) } + Filmstrip below
  │            Both panes share ScrubView zoomScale/offset bindings; divider removed, 8pt black gap
  └─ .grid  → GridView (unchanged)
Session.files + currentIndex → leftFile/rightFile → AppState.displayImages (radius 1 covers both)
```

## Model — `QuickCullCore/App/AppState`

No further model change beyond already-implemented `case split` and `syncWindows()` comment. `splitSecondIndex` remains view-derived (`files.indices.contains(currentIndex+1)`). Zoom state stays hoisted in `ScrubView` (4 `CGFloat`/`CGSize` vars) — shared by both panes.

## UI — `QuickCull/ScrubView` (picker, unchanged)

Already `Single | Split | Grid` with `Split` middle, `.fontWeight(.light)`, `.disabled(isCommitting)`. No new button for synchronized zoom (gestures on either pane suffice). HUD button `Metadata` far left separate from `Trash` far right stays.

## UI — `QuickCull/ImageDisplayView` (SplitViewer synchronized zoom, no divider)

Current Split (v1):
```swift
HStack(spacing:0){
  Left: ZoomableImageView(leftCG, shared bindings) + FlagBadge
  if rightFile != nil { Divider() }
  Right: FitImage(rightCG, fittedSize, opacity 0.92) // fixed 1×, no zoom
}
```

Becomes v2:
```swift
HStack(spacing: 8) { // 8pt gap, no Divider, Color.black shows through
  // Left — current, zoomable shared
  GeometryReader { geo in
    ZStack {
      Color.black
      if let img = leftCG, let file = leftFile {
        ZoomableImageView(cgImage: img, fileID: file.id, scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
          .overlay(alignment:.topTrailing){ FlagBadgeOverlay(file:file) }
      }
    }.frame(width:geo.size.width,height:geo.size.height)
  }.clipped()
  // Right — next, also zoomable shared, dimmed? Keep dimmed 0.92 or full? Spec says both zoom together, keep dimmed to signal secondary but still zoomable
  GeometryReader { geo in
    ZStack {
      Color.black
      if let img = rightCG, let file = rightFile {
        ZoomableImageView(cgImage: img, fileID: leftFile?.id ?? file.id, // use left fileID for shared offset reset so new pair recenters together (or rightFile.id? Use leftFile.id for pair)
                          scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
          .opacity(0.92) // dimmed secondary
      } else {
        VStack(spacing:8){ Image(systemName:"photo.slash").font(.title2).foregroundStyle(.secondary)
                           Text("No next image").font(.caption).foregroundStyle(.secondary) }
      }
    }.frame(width:geo.size.width,height:geo.size.height)
  }.clipped()
}
```

Notes:
- Both panes use **same** `$zoomScale`/`$zoomOffset` bindings from `ScrubView` → fully synchronized; `fileID` for both uses `leftFile.id` so `onChange(fileID)` recenters shared offset when left changes (new pair).
- `ZoomableImageView`’s `magnificationGesture`/`dragGesture`/`handleDoubleClick` are on both panes; dragging left updates shared offset, right pane reflects instantly (and vice versa).
- `HStack(spacing:8)` with no `Divider` — 8pt black gap visible, fulfills “remove dividing line but keep the space between the image”.
- Outer HUD `HStack { HUD 240 | gap 8 | SplitViewer }` — also 8pt gap, no divider (v2 asks remove dividing line — apply to both HUD-viewer and pane-pane gaps).
- `fittedSize`/`clampedOffset` per pane still recomputed on each `GeometryReader`’s `container` size; shared `offset` is clamped to the more restrictive max of the two (or per-pane display will clamp visually; shared state holds min max).

Alternative fileID for right: use `leftFile.id` for pair recentering (so new pair recenters together), not `rightFile.id`.

## Data Flow

```
Split:
  currentIndex → leftFile/rightFile → leftCG/rightCG
  Shared zoomScale/offset in ScrubView → both ZoomableImageView scale/offset
  Gesture on left → updates shared scale/offset → right reflects → and vice versa
  fileID change (currentIndex move) → shared offset reset to zero (both recentre)
  HUD visible: outer HStack HUD 240 + gap 8 + SplitViewer flex (both panes fully visible + 8pt gap)
```

## Edge Cases

| Case | Behavior |
|------|----------|
| HUD visible in Split | Outer gap 8 between HUD and split viewer; split panes gap 8 between left/right (no divider) |
| Last image rightFile nil | Right pane placeholder `No next image` black, no zoom, gap 8 still between left and placeholder |
| Different aspects left/right | Shared offset clamped to each pane’s max; the larger max may have slack, the smaller may be at edge — acceptable for burst |
| Rapid scrub | Shared offset reset on leftFile.id change; only latest pair wins |
| isCommitting / phase empty | Split toggle disabled, HUD hidden |
| Single view | Unchanged single viewer with HUD sidebar |

## Testing

- **Unit — `AppStateTests` already has `testSplitViewModeToggleAndShift`** — still passes; no new AppState test needed for synchronized zoom (view state).
- **Manual QA (updated):**
  - Split shows left current + right next with 8pt black gap, no divider line, both fully visible.
  - Pinch on left → both zoom together; pinch on right → both zoom; double-click either → both toggle fit↔200%; drag either → both pan together.
  - HUD `Metadata` far left separate from `Trash` far right; HUD 240 + gap 8 left of split viewer, no divider.
  - `→` shifts both by 1 overlapping; last right placeholder gap still 8.
  - Filter empty → black.

## Out of Scope

- Grid with split, vertical split, resizable divider/gap width.
- Independent zoom per pane or selecting right pane to make current.
- Right pane flag/HUD/badges.
- Persisting hudVisible/viewMode.
