# RAW Luminance Histogram — Design (Amendment to Raw Histogram)

Date: 2026-08-18
Status: approved design (pre-plan) — amends 2026-08-18-raw-histogram-design.md

## Purpose

Add a raw luminance histogram alongside the existing RGB overlay. Photographers see both channel clipping (RGB) and overall exposure (luminance) without leaving the HUD. Luminance is the single-channel count of every sensor value irrespective of Bayer color, computed in the same post-unpack pass as the RGB histogram and rendered as a second stacked histogram below the RGB block.

## Background

Today: `RawHistogram` (`QuickCullCore/Metadata/RawHistogram.swift`) holds 3×256 RGB bins + `sensorMax`/`samples`/`clipping`, computed in `LibRawDecoder.rawHistogram` from `rawdata.raw_image` with Bayer `fcol` after `libraw_unpack`. `DisplayHistogram.compute(from: CGImage)` is the fallback for non-RAW. `ImageCacheStore` stores `<cacheKey>.hist.json` atomically; `DecodeEngine` stores it best-effort; `MetadataHUDView` (`QuickCull/ImageDisplayView.swift`) renders a 72pt RGB `RawHistogramView` Canvas above the key/value rows with `cache: ImageCacheStore` passed from `ImageDisplayView` via `appState.cache`. The HUD task loads `cache.loadHistogram` or the display fallback.

## Approach (approved — Option A)

In the same post-unpack loop, increment a fourth `luminance` bin for every sensor value irrespective of color. No second pass, no extra LibRaw reopen.

## Model — `QuickCullCore/Metadata/RawHistogram.swift`

```swift
public struct RawHistogram: Codable, Equatable, Sendable {
    public static let binCount = 256
    /// Per-channel counts: [red, green, blue], 256 bins each.
    public let bins: [[Int]]
    /// Overall exposure: single channel counting every sensor value, 256 bins.
    public let luminance: [Int]
    public let sensorMax: Int
    /// Derived: total samples per channel (R,G,B,L) — not encoded.
    public var samples: [Int] { (bins + [luminance]).map { $0.reduce(0, +) } }
    /// Derived: fraction at top bin per channel (R,G,B,L) — not encoded.
    public var clipping: [Double] {
        (bins + [luminance]).map { b in
            guard !b.isEmpty else { return 0 }
            return Double(b[b.count - 1]) / Double(b.reduce(0, +) + 1)
        }
    }

    private enum CodingKeys: String, CodingKey { case bins, luminance, sensorMax }

    public init(bins: [[Int]], luminance: [Int], sensorMax: Int) {
        self.bins = bins
        self.luminance = luminance
        self.sensorMax = sensorMax
    }

    // Backwards compat: old sidecars without luminance decode with zeroed default
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bins = try c.decode([[Int]].self, forKey: .bins)
        sensorMax = try c.decode(Int.self, forKey: .sensorMax)
        luminance = try c.decodeIfPresent([Int].self, forKey: .luminance)
            ?? [Int](repeating: 0, count: Self.binCount)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bins, forKey: .bins)
        try c.encode(luminance, forKey: .luminance)
        try c.encode(sensorMax, forKey: .sensorMax)
    }
}
```

- `RawHistogram` remains `Codable`/`Equatable`/`Sendable`; custom `init(from:)` handles old sidecars without the `luminance` key (backwards-compatible).
- `DisplayHistogram.compute` gains `luminance` via Rec.709 `Y = 0.2126R + 0.7152G + 0.0722B` per pixel (rounded, binned) from the rendered `CGImage`. This matches the prior RGB computation path and Lightroom's rendered luminance.

## Computation — `QuickCullCore/Decoding/LibRawDecoder.swift`

In `rawHistogram(from:)` after the existing `counts` array, add `var luma = [Int](repeating: 0, count: RawHistogram.binCount)`. In the same `for row in 0..<h { for col in 0..<w }` loop, after computing `bin`, also do `luma[bin] += 1` (same bin, counts every value). Return `RawHistogram(bins: counts, luminance: luma, sensorMax: maxLevel)`. Non-Bayer (`filters 9/1`) and super-CCD (`left+w > rawW`) still return `nil` (no RGB, no luminance → HUD falls back).

## Storage — `QuickCullCore/Storage/ImageCacheStore.swift` / `QuickCullCore/Engine/DecodeEngine.swift`

No new files or keys. Same `<cacheKey>.hist.json` now encodes the extra `luminance` array. `storeHistogram`/`loadHistogram` unchanged except the JSON includes the new field; old JSON decodes via the custom `init(from:)` with an empty default, but that sidecar will be overwritten on next import (cache wiped on launch, or file mtime bump on re-import). `DecodeEngine` best-effort store unchanged.

## UI — `QuickCull/ImageDisplayView.swift`

`MetadataHUDView`’s histogram block becomes:

```swift
if let hist = histogram {
    VStack(spacing: 8) {
        RawHistogramView(histogram: hist)
            .frame(height: 72)
        RawLuminanceHistogramView(histogram: hist)
            .frame(height: 72)
    }
    .padding(.horizontal, 10)
    .padding(.top, 8)
}
```

- `RawLuminanceHistogramView` (new private struct in same file, alongside `RawHistogramView`) draws the single-channel `histogram.luminance` as a white fill (`Color.white.opacity(0.85)`) with the same log-y (`log10(1+count)/logMax`) and a white clipping marker when `histogram.clipping[3] > 0.001` (luma is the 4th entry). Same background `.black.opacity(0.3)` + `RoundedRectangle(cornerRadius: 4)` + total block height 152pt (72+8+72) inside the 240pt HUD.
- `RawHistogramView` unchanged (RGB only).
- `MetadataHUDView.task` still loads the same `RawHistogram` sidecar; both views read the same `histogram` state.

## Data Flow

```
import → LibRawDecoder (unpack → count RGB + luma in one pass → RawHistogram with luminance)
      → ImageCacheStore.storeJPEG + storeHistogram (.hist.json now with luminance)
scrub HUD → loadHistogram sidecar → RawHistogramView + RawLuminanceHistogramView
         or DisplayHistogram sidecar miss → compute both from cgImage in same task
```

## Error Handling & Edge Cases

- Old sidecar without `luminance` → custom decode defaults to zeroed array; next import overwrites with a full histogram (or HUD fallback `DisplayHistogram` shows a real luma for the current session).
- All-black bins → `logMax` guard (`rawMax > 0 ? rawMax : 1`) as already fixed in final review, applies to both views.
- Non-RAW / X-Trans / super-CCD → `RawHistogram` nil → HUD fallback `DisplayHistogram` provides both RGB and luma from the rendered image, so both blocks appear.
- Missing/corrupt sidecar → `loadHistogram` returns nil → fallback.

## Testing

Extend existing `RawHistogramTests` / `LibRawDecoderTests` / `ImageCacheStoreTests`:

- `testLuminanceBinsSumToPixelCount` — for fixtures, `luminance.reduce(0,+) == width*height` and `luminance.count == 256`.
- `testLuminanceCodableRoundTripWithBackwardsCompat` — new JSON with luminance round-trips; old JSON without luminance decodes with empty default and re-encodes with luminance.
- `testDisplayHistogramLuminancePeak` — synthetic `CGImage` flat gray 128 → `luminance` peak at `128*255/255` same bin as RGB, sum = pixel count.
- `testCacheHistogramRoundTripWithLuminance` — store/load equality includes luminance.

Existing 126 tests stay green; `RawHistogram` initializer with defaulted luminance keeps `TestDoubles` unchanged (no histogram) valid.

## Files

- Modify: `QuickCullCore/Metadata/RawHistogram.swift` (add luminance)
- Modify: `QuickCullCore/Decoding/LibRawDecoder.swift` (extra luma increment)
- Modify: `QuickCullCore/Storage/ImageCacheStore.swift` (no logic change, but JSON now carries luminance; add a test helper if needed)
- Modify: `QuickCullCore/Engine/DecodeEngine.swift` (no change; histogram now carries luma)
- Modify: `QuickCull/ImageDisplayView.swift` (`RawLuminanceHistogramView`, stacked VStack)
- Modify/Add tests: `QuickCullCoreTests/RawHistogramTests.swift`, `LibRawDecoderTests`, `ImageCacheStoreTests`

No new targets. `ScrubView`, `Session`, `ImageWindow`, `FilmstripView`, `GridView` unchanged.

## Acceptance Criteria

- HUD shows two stacked histograms (RGB on top, luminance below) for every file immediately while scrubbing.
- Luminance is the single-channel overall exposure from the same raw pass; RGB and luma share `sensorMax` and summing invariants.
- Old cached sidecars still load; new sidecars include luminance; non-RAW shows display luma fallback.
- Build and 126+ new tests green.
