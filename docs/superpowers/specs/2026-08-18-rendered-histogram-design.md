# Rendered (Lightroom-matched) Histogram — Design

Date: 2026-08-18
Status: approved design (supersedes linear sensor histogram for histogram contents)
Amends: `2026-08-18-raw-histogram-design.md` + `2026-08-18-raw-histogram-luminance-design.md`

## Purpose

Make both HUD histograms (RGB overlay + luminance) visually match Lightroom / Capture One / other raw editors' **rendered histograms** rather than the current FastRawViewer-style linear sensor histogram. Photographers culling in QuickCull should see the same exposure/clipping cues they will see after import, without mental translation of a left-crushed linear distribution.

## Background

Today (§1 specs, implemented `adbb89d`):

* `RawHistogram` (`QuickCullCore/Metadata/RawHistogram.swift:4`) is `256×3 + 256 luma` computed from `handle.pointee.rawdata.raw_image` (`UInt16` linear, pre-white-balance, pre-gamma, `maxLevel = color.maximum` e.g. 16383) in `LibRawDecoder.rawHistogram(from:)` (`LibRawDecoder.swift:81`). Bin = `(v * 255)/maxLevel`. Green channels merged. `luminance` is unweighted count of every Bayer value (`luma[bin]++`). `sensorMax` is sensor maximum.
* `DecodeEngine` stores it as `<cacheKey>.hist.json` sidecar; `MetadataHUDView` (`ImageDisplayView.swift:323`) loads `cache.loadHistogram ?? DisplayHistogram.compute(cgImage)` and renders `RawHistogramView` (additive R/G/B `0.55`) + `RawLuminanceHistogramView` (white `0.85`) with `log10(1+count)` y-normalization and clipping marker at `sensorMax`.
* `DisplayHistogram.compute(from: CGImage)` (`RawHistogram.swift:48`) is the correct rendered path: draws `CGImage` into `DeviceRGB` 8-bit and counts `R/G/B` plus weighted `Y=0.2126R+0.7152G+0.0722B` with `sensorMax=255`. Used for `JPEG/PNG/HEIC` and for missing sidecar.
* Verification (2026-08-18) shows RAW histograms do **not** match Lightroom: linear X-axis (18% grey `45` vs Lightroom `118`, +73 bins), no black subtract, no WB multipliers, unweighted luma, log-y vs linear vertical. Display fallback *does* match Lightroom because it counts the gamma-corrected image.

User confirmed (brainstorming Q1-2): **Approach A — Rendered histogram** is desired: histogram the **post-demosaic 8-bit sRGB buffer** that QuickCull already displays, so RAW and non-RAW share the same histogram semantics.

## Approach (approved — A: Rendered buffer histogram)

Count the `libraw_processed_image_t` 8-bit `RGB` buffer produced by `libraw_dcraw_process`/`libraw_dcraw_make_mem_image` (already `output_bps=8`, `use_camera_wb=1`, `output_color=1 sRGB`, `gamm 1/2.222,4.5` at `LibRawDecoder.swift:28`). This buffer is wrapped into the `CGImage` for `RawBitmap`, so histogram == viewer image == Lightroom rendered preview (modulo Lightroom's ProPhoto vs sRGB and tone-curve differences, which are minor and not reproducible without Adobe's engine).

Rejected: (B) gamma-correct raw counts — still 1 channel/pixel, approximates but not identical to demosaiced; (C) dual raw+rendered toggle — more useful but out-of-scope for this fix; can be added later as a preference.

## Model — `QuickCullCore/Metadata/RawHistogram.swift`

No struct shape change. Keep:

```swift
public struct RawHistogram: Codable, Equatable, Sendable {
  public static let binCount = 256
  public let bins: [[Int]]      // 3 × 256
  public let luminance: [Int]   // 256
  public let sensorMax: Int     // now always 255 for rendered
  public var samples: [Int] { (bins + [luminance]).map{$0.reduce(0,+)} } // 4 entries
  public var clipping: [Double] { (bins + [luminance]).map{ Double($0.last ?? 0)/Double($0.reduce(0,+)+1) } }
  private enum CodingKeys: String, CodingKey { case bins, luminance, sensorMax }
  public init(bins:[[Int]], luminance:[Int], sensorMax:Int) { self.bins=bins; self.luminance=luminance; self.sensorMax=sensorMax }
  public init(bins:[[Int]], sensorMax:Int) { self.init(bins:bins, luminance:[Int](repeating:0,count:Self.binCount), sensorMax:sensorMax) }
  public init(from decoder:Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self); bins=try c.decode([[Int]].self, forKey:.bins); sensorMax=try c.decode(Int.self, forKey:.sensorMax); luminance=try c.decodeIfPresent([Int].self, forKey:.luminance) ?? [Int](repeating:0,count:Self.binCount) }
  public func encode(to encoder:Encoder) throws { var c=encoder.container(keyedBy:CodingKeys.self); try c.encode(bins, forKey:.bins); try c.encode(luminance, forKey:.luminance); try c.encode(sensorMax, forKey:.sensorMax) }
}
```

Update doc comment: "Rendered sRGB histogram (8-bit post-demosaic, post-WB, post-gamma), plus weighted luminance (Rec.709). `sensorMax` is 255. Backward-compatible with old linear sidecars via `decodeIfPresent`."

`DisplayHistogram.compute(from:)` unchanged — already rendered semantics with `Y = (0.2126R+0.7152G+0.0722B).rounded()` and `sensorMax=255`.

## Computation — `QuickCullCore/Decoding/LibRawDecoder.swift`

Delete `rawHistogram(from handle: UnsafeMutablePointer<libraw_data_t>) -> RawHistogram?` (the `raw_image`/`filters`/`fcol`/`iwidth`/`left_margin` loop). Replace with:

```swift
private static func renderedHistogram(from p: UnsafeMutablePointer<libraw_processed_image_t>) -> RawHistogram {
  var bins = [[Int]](repeating: [Int](repeating: 0, count: RawHistogram.binCount), count: 3)
  var luma = [Int](repeating: 0, count: RawHistogram.binCount)
  let total = Int(p.pointee.data_size) // w*h*3, bits==8, colors==3, type==LIBRAW_IMAGE_BITMAP
  guard total > 0, total % 3 == 0 else { return RawHistogram(bins: bins, luminance: luma, sensorMax: 255) }
  withUnsafePointer(to: &p.pointee.data) { ptr in
    ptr.withMemoryRebound(to: UInt8.self, capacity: total) { buf in
      for i in stride(from: 0, to: total, by: 3) {
        let r = Int(buf[i]), g = Int(buf[i+1]), b = Int(buf[i+2])
        bins[0][r] += 1
        bins[1][g] += 1
        bins[2][b] += 1
        let y = min(255, max(0, Int((0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)).rounded())))
        luma[y] += 1
      }
    }
  }
  return RawHistogram(bins: bins, luminance: luma, sensorMax: 255)
}
```

In `decodeRaw(at:)`:

1. `libraw_open_file` → `libraw_unpack` (no histogram here).
2. Set `params` (`output_bps 8`, `use_camera_wb 1`, `output_color 1`, `gamm 1/2.222,4.5`) → `libraw_dcraw_process` → `libraw_dcraw_make_mem_image`.
3. Validate `p.pointee.type == LIBRAW_IMAGE_BITMAP && p.pointee.colors == 3 && p.pointee.bits == 8 && p.pointee.data_size == w*h*3`.
4. `let histogram = Self.renderedHistogram(from: processed)` (before `CGImage` creation, while `processed` is live).
5. Create `CGImage` from `Data(bytes: &p.pointee.data, count: data_size)` as today.
6. `return RawBitmap(image:..., width: Int(p.width), height: Int(p.height), flip: Int(handle.pointee.sizes.flip), histogram: histogram)`

Consequences:

* Super-CCD (`fuji_e550`) and X-Trans (`filters 9/1`) now **have** a histogram (previously `nil` due to non-Bayer guard). They go through `dcraw_process` and produce a valid `mem_image`.
* `sensorMax` is always `255`; clipping marker at right edge (`bin 255`) now means rendered white clipping, matching Lightroom.
* Performance: one pass over `w*h*3` bytes (≈ 18 MP → 54 MB, ~5–10 ms), same order as old raw loop.

## Storage — `QuickCullCore/Storage/ImageCacheStore.swift` / `QuickCullCore/Engine/DecodeEngine.swift`

No key or API change. `histogramURL`, `storeHistogram`, `loadHistogram`, `DecodeEngine` best-effort `try? storeHistogram` remain. JSON now contains rendered bins with `sensorMax 255`. Old linear sidecars (e.g. `sensorMax 16383`) still decode via custom `init(from:)`; they will be overwritten on next import because `ImageCacheStore.wipe()` clears the cache on launch and `DecodeEngine` rewrites on mtime bump. No migration needed.

## UI — `QuickCull/ImageDisplayView.swift`

No structural change. `MetadataHUDView` stacked `VStack(spacing:8){ RawHistogramView 72pt; RawLuminanceHistogramView 72pt }` (`ImageDisplayView.swift:333`), `log-y` (`log10(1+count)/logMax` with `logMax>0 ? logMax : 1` guard), `roundedRectangle` background, clipping marker `clipping>0.001` (now at rendered white) all stay. `RawHistogramView` draws additive R/G/B `0.55`; `RawLuminanceHistogramView` draws white `0.85`. `task(id:)` loading `cache.loadHistogram ?? DisplayHistogram.compute` still covers both branches — now both branches produce comparable rendered histograms (full-res vs thumb-res; difference < sampling noise).

No change to `ScrubView`, `Session`, `ImageWindow`, `FilmstripView`, `GridView`. No new targets.

## Data Flow

```
import → DecodeEngine worker → LibRawDecoder (open → unpack → dcraw_process → make_mem_image → renderedHistogram from sRGB 8-bit buffer → RawBitmap with histogram)
      → ImageCacheStore.storeJPEG + storeHistogram (.hist.json rendered, sensorMax 255)
scrub HUD → MetadataHUDView.task(id:) → loadHistogram sidecar (rendered) ?? DisplayHistogram.compute(cgImage) (rendered fallback) → RawHistogramView + RawLuminanceHistogramView
```

## Error Handling & Edge Cases

* `libraw_dcraw_make_mem_image` returns `nil` or invalid `type/colors/bits/data_size` → throw `cannotProcess` before histogram (no histogram for failed decode, as today).
* Missing/corrupt sidecar → `loadHistogram` returns `nil` → fallback `DisplayHistogram` (shows rendered histogram from the thumb `cgImage`).
* `cgImage == nil` (still loading) → HUD shows "Loading..." rows, no histogram block.
* All-black or uniform image → `logMax` guard (`rawMax>0 ? rawMax : 1`) prevents divide-by-zero; flat grey 128 → peak at `bin 128` for `R/G/B` and `luma`.
* Backward compat: old `.hist.json` without `luminance` decodes with zeroed `luma` and old `sensorMax` (e.g. 16383); next import overwrites.

## Testing

Update existing tests; no new files required:

* `QuickCullCoreTests/RawHistogramTests.swift` — `testDisplayHistogramOfFlatGray` and `testDisplayHistogramLuminancePeakForFlatGray` unchanged (already rendered). `testCodableBackwardsCompatMissingLuminance` stays.
* `QuickCullCoreTests/LibRawDecoderTests.swift`:
  - `testHistogramComputedForRawFixtures` — update to expect rendered histogram: for each of the 8 fixtures **including** `fuji_e550`, `XCTUnwrap(bitmap.histogram)`, `bins.count==3`, each `count==256`, `sensorMax==255`, `hist.samples[0]==w*h && hist.samples[1]==w*h && hist.samples[2]==w*h` (each channel full-res), `luminance.count==256`, `hist.samples[3]==w*h`, `hist.luminance.reduce(0,+)==w*h`, `bins.flatMap{$0}.allSatisfy{$0>=0}`.
  - `testLuminanceComputedForBayerFixtures` — merge into above or update to assert `samples == w*h` per channel.
  - Remove/replace `testLuminanceNilForSuperCCDAndXTrans` — super-CCD now has histogram, assert `XCTNotNil(fuji.histogram)` and same `255` invariants.
* `QuickCullCoreTests/ImageCacheStoreTests.swift` — `testStoreAndLoadHistogram*` unchanged (round-trip includes `luminance` and `sensorMax 255`). Add assertion `loaded.sensorMax==255` if desired.
* `QuickCullCoreTests/DecodeEngineTests.swift` — fixture integration counts unchanged (`8 jpg + 8 hist.json`).

Build: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build` passes. Tests: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS'` passes (≈131 tests, 0 failures).

## Files

* Modify: `QuickCullCore/Metadata/RawHistogram.swift` — doc comment only (semantics rendered).
* Modify: `QuickCullCore/Decoding/LibRawDecoder.swift` — replace `rawHistogram` with `renderedHistogram(from: processed)` and move call site.
* No change: `QuickCullCore/Decoding/RawDecoding.swift` (`RawBitmap.histogram` stays optional), `QuickCullCore/Storage/ImageCacheStore.swift`, `QuickCullCore/Engine/DecodeEngine.swift`, `QuickCull/ImageDisplayView.swift` (except optional doc comment).
* Modify tests: `QuickCullCoreTests/LibRawDecoderTests.swift` (above); `QuickCullCoreTests/RawHistogramTests.swift` only if adjusting expectations.

## Acceptance Criteria

* HUD shows two stacked histograms for **every** file (including `fuji_e550` super-CCD and `JPEG/PNG/HEIC`) immediately while scrubbing, without re-decode.
* Histogram shape for a given RAW visually matches Lightroom/Capture One/Preview histogram for the same file (allow `log-y` vertical difference; X positions match). Peak for 18% grey at bin ~118, not 45.
* Clipping marker lights only when rendered `bin 255` fraction `>0.001`; all-black image shows no marker.
* Build and full test suite green; manual QA: `./start.sh`, import 8 RAWs+JPEG, scrub HUD, compare to Lightroom/Preview histogram — X-axis positions coincide.

No new targets. `ScrubView`, `Session`, `ImageWindow`, `FilmstripView`, `GridView` unchanged.
