# FastRawViewer-style Line Histogram — Design

Date: 2026-08-18
Status: approved design
Amends: `2026-08-18-rendered-histogram-design.md` (histogram contents) + `2026-08-18-split-hud-corresponding-side-design.md` (HUD layout)

## Purpose

Make HUD histograms look and read like FastRawViewer: thin per-channel **lines** (not filled areas), faint axes/baseline, and a compact numeric read-out (per-channel clipping % + mean) so photographers can assess exposure like in FRV without leaving the culling flow. Keep the existing rendered sRGB 8-bit histogram data and stacked RGB-over-luma layout.

## Background

Today (`c2613d0` + `0ae7a6a` reverted, `9ba1dd4`):

* `RawHistogram` (`QuickCullCore/Metadata/RawHistogram.swift:4`) is `3×256 + 256 luma`, `sensorMax 255`, rendered sRGB `LibRawDecoder.renderedHistogram` from `mem_image` `w*h*3` sRGB buffer (`use_camera_wb=1`, `output_color=1`, `gamm 1/2.222,4.5`), `DisplayHistogram` fallback for JPEG/PNG/HEIC. Stored as `.hist.json` sidecar.
* `MetadataHUDView` (`QuickCull/ImageDisplayView.swift:333`) shows `VStack(spacing:8){ RawHistogramView 72pt; RawLuminanceHistogramView 72pt }` inside `ScrollView` above rows, `.padding(.horizontal,10).padding(.top,8)`, `histogram=nil` at task start.
* `RawHistogramView` (`ImageDisplayView.swift:393`) `Canvas` draws **filled** additive areas `Color.red/green/blue.opacity(0.55)` via `ctx.fill(path)` with `log10(1+count)/logMax` y, `RoundedRectangle(4)`, `background .black.opacity(0.3)`, vertical white clipping marker at `x=width-1` when `clipping>0.001`.
* `RawLuminanceHistogramView` (`ImageDisplayView.swift:435`) same but `Color.white.opacity(0.85)` filled.
* No axes, no numbers besides the clipping marker. FastRawViewer shows thin lines per channel, log/linear toggle, EV axis, and stats (over/under %, mean, clipping) — QuickCull currently shows filled blobs, no stats, no baseline.

User (brainstorming) chose: **A Thin lines + stats (recommended)**, keep two stacked panels (RGB on top, luma below) at 72pt each, with clipping % + mean read-out per panel. No merge to single panel, no toggle.

## Approach (approved — A: Thin lines + stats + faint axes)

Replace filled areas with **stroked lines** (1.5pt) in the same `Canvas` with same `log-y` and same sidecar data. Add a compact stats `HStack` above each `Canvas` and a faint baseline/border for FRV-like axes. Keep two stacked 72pt panels, same outer `VStack(spacing:8)` and same `MetadataHUDView.task` loading.

Rejected: (B) filled+line overlay (heavier, not pure FRV); (C) toggle line/filled/log/linear (more UI, YAGNI for v1).

## Visual — `QuickCull/ImageDisplayView.swift:393` + `435`

**RawHistogramView (RGB):**
* `Canvas` `let binCount=256, binW=width/256, rawMax=log10(maxCount+1), logMax=rawMax>0?rawMax:1, yFor=height*(1-log10(count+1)/logMax)`
* For `channel 0..<3`:
  * Build `Path` `move(0,height) → for bin 0..255 lineTo(x=bin*binW, y=yFor(bins[channel][bin])) → lineTo(width,height) close` is **not** closed for stroke; instead `Path` is open polyline `move(x0,y0) → lineTo(...)` then `ctx.stroke(path, with:.color(colors[channel]), lineWidth:1.5)`
  * Colors: `.red.opacity(0.9)`, `.green.opacity(0.9)`, `.blue.opacity(0.9)` (was `0.55` fill). No fill.
* Axes/baseline: `ctx.stroke(Path{ move(0,height)→lineTo(width,height) plus move(0,0)→lineTo(0,height) }, with:.color(.white.opacity(0.15)), lineWidth:0.5)` faint L-shape.
* Clipping marker: same `if clipping.prefix(3).contains(where:{$0>0.001}) { ctx.stroke(vertical line at x=width-1, y 0→height, .white, 1) }`
* Background `.black.opacity(0.3)`, `clipShape(RoundedRectangle(4))`, `accessibilityLabel("RAW histogram")` unchanged.

**RawLuminanceHistogramView (Luma):**
* Same log-y, `rawMax` from `luminance`, `yFor` same.
* Single `Path` for `luminance[bin]`, `ctx.stroke` with `.white.opacity(0.9)` `lineWidth:1.5`.
* Same axes/baseline `white.opacity(0.15)`.
* Clipping marker `if clipping.count>3 && clipping[3]>0.001` same.

**Stats rows (in `MetadataHUDView`):**
* RGB panel: `HStack { Text("R:\(r)% G:\(g)% B:\(b)%"); Spacer(); Text("Mean \(m)") }` `.font(.caption2).foregroundStyle(.secondary).padding(.horizontal,2)` where `r = String(format:"%.1f%%", clipping[0]*100)` etc., `m = Int(round( Σ(bin*count)/total ))` averaged across 3 channels? Chosen: `mean = Int( (meanR+meanG+meanB)/3 +0.5 )` with `meanC = Σ(bin*count)/samples[c]` (0 if total 0). Luma panel: `Text("Luma \(clipL)%")` + `Spacer()` + `Text("Mean \(meanL)")` where `clipL = clipping[3]*100`, `meanL = Σ(bin*luma[bin])/totalL`.
* Example: flat grey 128 → `R:0.0% G:0.0% B:0.0% Mean 128`; clipped shot → `R:0.2% G:0.0% B:1.1% Mean 98`; luma `Luma 0.5% Mean 112`.
* Font `caption2`, single line, truncated middle not needed (short).

**Layout in `MetadataHUDView`:**
```
if let hist = histogram {
  VStack(spacing:8){
    VStack(spacing:2){
      HStack{ Text(...clipping...); Spacer(); Text(...mean...) }.font(.caption2)...
      RawHistogramView(histogram: hist).frame(height:72)
    }
    VStack(spacing:2){
      HStack{ Text(...luma...); Spacer(); Text(...meanL...) }.font(.caption2)...
      RawLuminanceHistogramView(histogram: hist).frame(height:72)
    }
  }.padding(.horizontal,10).padding(.top,8)
}
```
Outer `VStack(spacing:8)` height ~ `12+72 +8 +12+72 = 176` inside 240pt HUD, fits `ScrollView`.

## Data / Computation — `QuickCullCore/Metadata/RawHistogram.swift` + `QuickCullCore/Decoding/LibRawDecoder.swift`

No model change. `RawHistogram` stays `bins 3×256`, `luminance 256`, `sensorMax 255`, `samples`/`clipping` derived, `Codable` with `decodeIfPresent`. `LibRawDecoder.renderedHistogram` (sRGB `mem_image` `w*h*3`, `highlight 0`, `gamm 1/2.222`, `output_color 1`) and `DisplayHistogram` unchanged. Stats are **derived in the views** on the fly, not stored.

Mean/clipping formulas:
* `clipping[c] = bins[c].last! / (total+1)` (existing `clipping` array, `*100` for display)
* `meanC = total>0 ? Σ(bin*binCount)/total : 0` as `Double` then `Int(round)`, `mean = (meanR+meanG+meanB)/3` for RGB panel, `meanL` for luma.

## Components — `QuickCull/ImageDisplayView.swift`

* `MetadataHUDView` (`ImageDisplayView.swift:333`) — add two stats `HStack`s, keep `histogram` state and `.task(id:)` loading `cache.loadHistogram ?? DisplayHistogram` with `histogram=nil` at start.
* `RawHistogramView` (`ImageDisplayView.swift:393`) — change `ctx.fill` → `ctx.stroke` 1.5pt, add axes, keep log-y, clipping marker, background, clipShape.
* `RawLuminanceHistogramView` (`ImageDisplayView.swift:435`) — same stroke change, axes, marker.
* No `ScrubView`, `AppState`, `ImageCacheStore`, `DecodeEngine`, `GridView`, `FilmstripView` changes. No new files/targets.

## Data Flow

```
import → LibRawDecoder (sRGB mem_image → renderedHistogram bins/luma sensorMax 255) → ImageCacheStore .hist.json
scrub HUD → MetadataHUDView.task(id: file.id-dims) → loadHistogram || DisplayHistogram → hist → RawHistogramView (stroke lines + stats) + RawLuminanceHistogramView (white line + stats)
```

## Error Handling & Edge Cases

* `total==0` (empty/all-black) → `logMax` guard `>0?logMax:1` prevents divide-by-zero; `mean 0`, `clip 0.0%`, no marker, line at `y=height`.
* `histogram==nil` → no block (as today). Missing/corrupt sidecar → fallback `DisplayHistogram` (same sRGB histogram, same view).
* `cgImage==nil` → `MetadataHUDView` shows "Loading…" rows, histogram block absent until loaded (stats not shown).
* `bins`/`luminance` always 256 (model invariant); corrupted JSON → `loadHistogram` nil → fallback.

## Testing

No new unit tests (view-only). Verify:

* Build: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build` passes.
* Suite: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS'` passes `134/0`.
* Manual QA (`./start.sh`, import 8 RAWs + JPEG):
  - HUD shows thin RGB lines (red/green/blue) + white luma line, faint baseline/border, log-y, no fill.
  - Flat grey 128 JPEG → `R:0.0% G:0.0% B:0.0% Mean 128` and luma `Luma 0.0% Mean 128`, lines vertical spike at `bin 128`, no marker.
  - Clipped `olympus_c5050z` → `B:1.1%` etc., white vertical marker at `x=width-1` in both panels where clipping>0.001.
  - Rapid scrub HUD → both panels update together, stats change per file, no stale flash (`histogram=nil` at task start).
  - Narrow window → HUDs fixed 240, images letterboxed, no overlap.

## Files

* Modify: `QuickCull/ImageDisplayView.swift:333-485` — `MetadataHUDView` add stats `HStack`s, `RawHistogramView`/`RawLuminanceHistogramView` fill→stroke 1.5pt + axes baseline, keep `log-y`, clipping, background, clipShape.
* No change: `QuickCullCore/Metadata/RawHistogram.swift`, `QuickCullCore/Decoding/LibRawDecoder.swift`, `QuickCullCore/Storage/ImageCacheStore.swift`, `QuickCullCore/Engine/DecodeEngine.swift`, `QuickCull/ScrubView.swift`.

No new targets. `ScrubView`, `Session`, `ImageWindow`, `FilmstripView`, `GridView` unchanged.

## Acceptance Criteria

* Two stacked 72pt histograms in HUD rendered as thin lines (RGB 1.5pt `0.9` opacity, luma white `0.9`), faint axes/baseline `0.15`, `RoundedRectangle(4)` background `black 0.3`, log-y.
* Stats row per panel: RGB `R:% G:% B:%` + `Mean`, luma `Luma % + Mean`, `caption2` secondary, correct for flat grey and clipped samples.
* Clipping marker white 1px at right edge only when `clipping>0.001`.
* Build and 134 tests green; manual QA line + stats visible and updating.

