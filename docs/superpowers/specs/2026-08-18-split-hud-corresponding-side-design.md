# Split HUD — Corresponding Side Metadata — Design

Date: 2026-08-18
Status: approved design

## Purpose

In split view, show metadata on the side that corresponds to the photo: left HUD for the left photo, right HUD for the right photo. Today the HUD appears only on the left for the current photo; the right photo's metadata is invisible without exiting split. Corresponding-side HUDs let photographers compare two consecutive shots' EXIF/histograms without mental mapping.

## Background

`ImageDisplayView.swift:37-76` split branch today:

* Resolves `currentFile` (`files[index]`), `rightFile` (`files[index+1]`), `leftCG`/`rightCG` from `appState.displayImages`/`thumbWindow`.
* Renders `HStack(spacing:8){ if hudVisible { MetadataHUDView(file:currentFile, cgImage:leftCG, cache) .frame(240) } ; HStack(spacing:8){ LeftImage | RightImage } }` with `.ultraThinMaterial` + `.move(edge:.leading).combined(.opacity)` + `.animation(0.2, hudVisible)`.
* `MetadataHUDView` (`ImageDisplayView.swift:323`) is `file: SessionFile, cgImage: CGImage?, cache: ImageCacheStore` with internal `@State metadata/histogram` loaded via `.task(id:"\(file.id)-\(w)x\(h)")` using `Task.detached(utility){ cache.loadHistogram ?? DisplayHistogram.compute(cgImage) }`; shows stacked 72pt RGB + 72pt luminance histograms above key/value rows; `histogram=nil` at task start avoids stale flash.
* `Single` branch (`ImageDisplayView.swift:78`) is `HStack{ if hudVisible { MetadataHUDView(current, cgImage, cache) 240 } ; GeometryReader Zoomable }`.
* `hudVisible` is hoisted `@Binding` from `ScrubView`; single toggle `View > Show Metadata` (`Cmd+Shift+M`).
* At `index == files.count-1`, `rightFile==nil`, right pane shows `VStack{ "photo.slash" + "No next image" }` centered.

User request (brainstorming): split HUDs outer-mirrored, empty HUD at end of library, single toggle.

## Approach (approved — A: Outer mirrored HUDs)

In split view when `hudVisible == true`, render **two** `MetadataHUDView`s:

```
HStack(spacing:8){
  // outer left
  if hudVisible, let file=currentFile, let lcg=leftCG {
    MetadataHUDView(file:file, cgImage:lcg, cache:appState.cache)
      .frame(width:240).background(.ultraThinMaterial)
      .transition(.move(edge:.leading).combined(with:.opacity))
  }
  HStack(spacing:8){
    Left pane GeometryReader + ZoomableImageView(cgImage:leftCG, fileID:currentFile?.id)
    Right pane GeometryReader + ZoomableImageView(cgImage:rightCG, fileID:currentFile?.id) or "No next image" center
  }
  // outer right
  if hudVisible {
    if let rFile=rightFile, let rcg=rightCG { // right photo exists, maybe still loading
      MetadataHUDView(file:rFile, cgImage:rcg, cache:appState.cache)
        .frame(width:240).background(.ultraThinMaterial)
        .transition(.move(edge:.trailing).combined(with:.opacity))
    } else if rightFile == nil {
      // Empty HUD placeholder — same frame/style as HUD, no histogram/rows
      VStack(spacing:8){
        Image(systemName:"photo.slash").font(.title2).foregroundStyle(.secondary)
        Text("No next image").font(.caption).foregroundStyle(.secondary)
      }
      .frame(width:240).frame(maxHeight:.infinity, alignment:.center)
      .background(.ultraThinMaterial)
      .transition(.move(edge:.trailing).combined(with:.opacity))
    }
    // rightFile != nil but rightCG == nil (thumb pending) → MetadataHUDView shows "Loading..." (existing behavior) while not falling to empty branch
  }
}
.animation(.easeInOut(duration:0.2), value:hudVisible)
```

Single mode unchanged (`Left HUD only`). One `hudVisible` controls both; no per-side toggle (YAGNI).

Rejected: (B) inner adjacent HUDs (cramped center gap); (C) single contextual HUD switching on hover (contradicts "corresponding side").

## Components — `QuickCull/ImageDisplayView.swift`

* `ImageDisplayView.body` split `HStack` — add trailing HUD branch as above; reuse `appState.cache`, `currentFile`/`rightFile`, `leftCG`/`rightCG` already resolved at top of `body`.
* `MetadataHUDView` — no change; second instance reuses same init and task logic; each instance owns its own `metadata`/`histogram` state and `task(id:)` cancellation on rapid scrub.
* `RawHistogramView` / `RawLuminanceHistogramView` — unchanged.
* `ZoomableImageView` — unchanged; shared `scale/lastScale/offset` bindings remain synchronized between panes.

No new files, types, or targets.

## Data Flow

```
ScrubView.hudVisible (Bool) → ImageDisplayView @Binding
currentIndex → currentFile/leftCG, rightFile/rightCG (appState.session/files, displayImages/thumbWindow)
hudVisible==true?
  left HUD MetadataHUDView.task(file:currentFile, cgImage:leftCG) → cache.loadHistogram || DisplayHistogram → left histogram+rows
  right HUD MetadataHUDView.task(file:rightFile, cgImage:rightCG) → cache.loadHistogram || DisplayHistogram → right histogram+rows (or empty placeholder if rightFile nil, or Loading if rightCG nil)
```

Each HUD's `task(id:"\(file.id)-\(w)x\(h)")` independently loads its file's sidecar; scrub changes `index` → both ids change → both tasks cancel/restart; `histogram=nil` at entry avoids cross-contamination.

## Error Handling & Edge Cases

* `hudVisible==false` → no HUDs, black `Color.black` gaps via `HStack(spacing:8)` (existing).
* `rightFile==nil` (last photo) → right outer panel shows empty `240pt` `photo.slash + "No next image"` (chosen), not hidden; prevents reflow and keeps "corresponding side" promise. Left HUD normal.
* `rightFile != nil && rightCG == nil` (thumb still decoding, `DisplayImages` pending) → right HUD is `MetadataHUDView` with `cgImage==nil` → shows "Loading…" row and no histogram until `rightCG` arrives; outer placeholder not shown.
* `cache.loadHistogram` missing/corrupt → fallback `DisplayHistogram.compute(cgImage)` per HUD (already handles nil `cgImage` → "Loading…").
* `leftCG` or `rightCG` nil while overall `currentFile` nil (filtered empty, `files.isEmpty`) → outer split not rendered; early `Color.black` empty state already at `ImageDisplayView.swift:34`.
* View mode toggle `Single ↔ Split` → `hudVisible` animation `.easeInOut(0.2)` applies to both outer panels; no extra state in `ScrubView`.
* Narrow window → `HStack` total fixed HUD width `480 + 16` plus `spacing 8+8`; image panes `GeometryReader` fitted logic clamps/shrinks; no overflow.
* No histogram logic change — `sensorMax 255` rendered histograms already verified `134/0`.

## Testing

No new automated unit tests (UI layout). Verify via:

* Build: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build` passes.
* Suite: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS'` passes `134/0`.
* Manual QA (`./start.sh`, import `QuickCullCoreTests/Fixtures/raws/` + `JPEG`):
  - Single + HUD → single left 240 HUD only (unchanged).
  - Split + HUD off → no panels, two images.
  - Split + HUD on, `index=0` → left HUD 240 on far left (left file histogram), right HUD 240 on far right (next file histogram) — verify filenames/`isFlagged` differ; both histograms load without re-decode; rapid `→/←` updates both.
  - Split + HUD on, `index == count-1` → left HUD normal, right empty 240 panel `photo.slash` + "No next image", right image pane also shows center "No next image".
  - Thumb-loading: cold import, split immediately → right HUD shows "Loading…" then histogram when `rightCG` decodes.
  - Narrow window → images remain letterboxed, HUDs fixed 240, no overlap.

## Files

* Modify: `QuickCull/ImageDisplayView.swift:37-76` — add trailing right HUD branch with `rightFile`/`rightCG` and empty placeholder, add trailing `.transition(.move(edge:.trailing)…)` and outer `HStack` structure; keep existing left HUD and inner `HStack(spacing:8)`.
* No change: `QuickCullCore/Metadata/RawHistogram.swift`, `QuickCullCore/Decoding/*`, `QuickCullCore/Storage/ImageCacheStore.swift`, `QuickCullCore/Engine/DecodeEngine.swift`, `ScrubView`, `Session`, `FilmstripView`.

No new targets.

## Acceptance Criteria

* Split view with `hudVisible` shows two HUDs outer-mirrored: left HUD = left photo, right HUD = right photo (240pt, `.ultraThinMaterial`, histograms 72+8+72, rows).
* Split hud off → no HUDs.
* Last photo split → left HUD normal, right outer shows empty 240 panel `photo.slash + "No next image"`.
* Single mode unchanged.
* Build and 134 tests green.
