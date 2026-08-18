# RAW Histogram in Metadata HUD — Design

Date: 2026-08-18
Status: approved design (pre-plan)

## Purpose

Add a true RAW sensor histogram to the metadata HUD. Photographers see real highlight headroom and channel clipping (FastRawViewer-style) without leaving the culling flow. The histogram is computed from linear sensor data during the existing import decode (near-free extra pass), cached as a JSON sidecar next to the cached JPEG, and rendered as an RGB overlay in the HUD sidebar. Non-RAW files (JPEG/PNG/HEIC) fall back to a display histogram computed from the decoded image so every file shows one.

## Background

Today: `LibRawDecoder.decodeRaw` calls `libraw_open_file` → `libraw_unpack` → sets params (`output_bps`, `use_camera_wb`, `output_color`, `gamm`) → `libraw_dcraw_process` → `libraw_dcraw_make_mem_image`, returning `RawBitmap(image:width:height:flip:)`. `DecodeEngine.decodeAll` stores a q75 JPEG via `ImageCacheStore.storeJPEG` keyed by path+size+mtime. `MetadataHUDView` (in `QuickCull/ImageDisplayView.swift`) renders key/value rows from `ImageMetadataProvider.metadata(for:cgImage:)` inside a 240pt sidebar (`hudVisible`, hoisted in `ScrubView`). `MetadataHUDView` already receives `file: SessionFile` and `cgImage: CGImage?` (the display-resolution image) and loads metadata via `.task(id: "\(file.id)-\(dims)")` with `Task.detached(priority: .utility)`.

The raw data is available for free at exactly one moment: right after `libraw_unpack`, before demosaic. Counting sensor values there costs one O(N) pass (~50-100ms for 45MP), negligible against demosaic+JPEG encode. Storing the result once means the HUD never re-decodes while scrubbing.

## Approach (approved)

**Option A — compute during existing unpack, cache sidecar JSON.**

- `LibRawDecoder.decodeRaw` counts linear sensor values from `handle.pointee.rawdata.raw_image` (post-unpack, pre-demosaic) into a `RawHistogram` and returns it on `RawBitmap`.
- `ImageCacheStore` stores `<cacheKey>.hist.json` alongside the JPEG and loads it back.
- `MetadataHUDView` renders a histogram block above the key/value rows: `RawHistogramView` (SwiftUI `Canvas`), RGB channels overlaid with additive fills, log-y, vertical clipping marker at `sensorMax`.
- Non-RAW fallback: `DisplayHistogram.compute(from: cgImage)` counts the rendered image's pixels on demand in the same detached task; shown when `RawHistogram` is nil (JPEG/PNG/HEIC, X3F/Foveon with no `raw_image`, missing sidecar).

Rejected: (B) On-demand LibRaw reopen per image — 0.5-2s per scrub with HUD open; (C) JPEG-embedded metadata — hacky, pollutes cache semantics.

## Model

New file `QuickCullCore/Metadata/RawHistogram.swift`:

```swift
/// Linear sensor histogram computed from LibRaw's unpacked raw data,
/// plus a display-histogram fallback for non-RAW files.
public struct RawHistogram: Codable, Equatable, Sendable {
    public static let binCount = 256
    /// Per-channel counts, 256 bins each. Values are linear sensor
    /// levels mapped from 0...sensorMax onto the bins. Red, green, blue.
    public let bins: [[Int]]
    /// Highest possible sensor level (e.g. 16383 for 14-bit); used for
    /// the clipping marker and x-axis scale.
    public let sensorMax: Int
    /// Total samples counted per channel (sum of bins).
    public let samples: [Int]
    /// Fraction of samples at sensorMax (0...1) per channel.
    public let clipping: [Double]

    public init(bins: [[Int]], sensorMax: Int) {
        self.bins = bins
        self.sensorMax = sensorMax
        self.samples = bins.map { $0.reduce(0, +) }
        self.clipping = bins.map { b in
            b.isEmpty ? 0 : Double(b.last!) / Double(b.reduce(0, +) + 1)
        }
    }
}

public enum DisplayHistogram {
    /// 256-bin RGB histogram of a rendered CGImage (fallback path).
    public static func compute(from cgImage: CGImage) -> RawHistogram
}
```

- `RawHistogram` is `Codable` for the sidecar JSON; `Sendable` to cross the detached-task boundary.
- `RawBitmap` gains `public let histogram: RawHistogram?` (default `nil`); `ImageIODecoder` returns `nil` (fallback path), `LibRawDecoder` returns the computed histogram.

## Computation — `QuickCullCore/Decoding/LibRawDecoder.swift`

After `libraw_unpack` succeeds and before `libraw_dcraw_process`:

```swift
let hist = Self.rawHistogram(from: handle)
```

```swift
private static func rawHistogram(from handle: UnsafeMutablePointer<libraw_data_t>) -> RawHistogram? {
    let raw = handle.pointee.rawdata
    let sizes = handle.pointee.sizes
    let filters = handle.pointee.idata.filters
    guard let ptr = raw.raw_image, sizes.raw_width > 0, sizes.raw_height > 0 else { return nil }
    let maxLevel = Int(handle.pointee.sizes.maximum != 0 ? handle.pointee.sizes.maximum : 16383)
    var counts = [[Int]](repeating: [Int](repeating: 0, count: RawHistogram.binCount), count: 3)
    let w = Int(sizes.raw_width), h = Int(sizes.raw_height)
    for row in 0..<h {
        for col in 0..<w {
            // Bayer color at (row,col): dcraw fcol convention
            let c = Int((filters >> (((row & 1) << 1 | (col & 1)) << 1)) & 3)
            // merge G1/G2 into green (index 1); red=0, blue=2
            let channel = c == 3 ? 2 : (c == 1 ? 1 : 0) // 0=R,1=G,2=B,3=G2
            let v = Int(ptr[row * w + col])
            let bin = min(RawHistogram.binCount - 1, max(0, (v * (RawHistogram.binCount - 1)) / maxLevel))
            counts[channel][bin] += 1
        }
    }
    return RawHistogram(bins: counts, sensorMax: maxLevel)
}
```

- Color mapping follows dcraw's `fcol`: `(filters >> (((row & 1) << 1 | (col & 1)) << 1)) & 3`, values 0=R, 1=G, 2=B, 3=G2; G1/G2 merge into the green channel.
- `raw_image` nil (Foveon/X3F path) → `nil` → display fallback.
- Histogram counts pre-white-balance, pre-gamma linear data — true RAW histogram.
- Orientation/flip does not affect counts; no transformation needed.

## Storage — `QuickCullCore/Storage/ImageCacheStore.swift`

- `histogramURL(for file: SessionFile) throws -> URL` — same key as `cacheURL`, with `.hist.json` extension appended.
- `storeHistogram(_ hist: RawHistogram, for file: SessionFile) throws` — `JSONEncoder` → `Data`, write atomically (tmp + replace) like `storeJPEG`.
- `loadHistogram(for file: SessionFile) throws -> RawHistogram?` — `JSONDecoder`, `nil` if missing/corrupt.
- `DecodeEngine.decodeAll` worker: after `storeJPEG(bitmap, for: file)`, if `let h = bitmap.histogram { try? await cache.storeHistogram(h, for: file) }` — histogram write failure must not fail the import (decode outcome unchanged).
- Launch wipe (`ImageCacheStore.wipe`) covers sidecars automatically (whole directory).

## UI — `QuickCull/ImageDisplayView.swift` (MetadataHUDView)

- `MetadataHUDView` gains a histogram block at the top of its `ScrollView`, above the key/value rows:

```swift
if let hist = histogram {
    RawHistogramView(histogram: hist)
        .frame(height: 72)
        .padding(.horizontal, 10)
        .padding(.top, 8)
}
```

- `@State private var histogram: RawHistogram?` loaded inside the existing `.task(id:)`:

```swift
.task(id: "\(file.id)-\(cgImage?.width ?? 0)x\(cgImage?.height ?? 0)") {
    metadata = await Task.detached(priority: .utility) {
        ImageMetadataProvider.metadata(for: file, cgImage: cgImage)
    }.value
    // Histogram: raw sidecar first, display fallback for non-RAW
    if let hist = await Task.detached(priority: .utility) {
        ImageCacheStore(baseURL: ImageCacheStore.defaultBaseURL()).loadHistogram(for: file)
            ?? { DisplayHistogram.compute(from: cgImage) }()
    }.value {
        histogram = hist
    }
}
```

Wait — `ImageCacheStore` is an actor; the HUD needs the app's cache instance. Better: pass `cache: ImageCacheStore` (or a `histogramProvider` closure) into `MetadataHUDView` from `ImageDisplayView`, which reads `appState.cache` (already available via `@Environment(AppState.self)`). `ImageDisplayView` passes `appState.cache` into `MetadataHUDView(file:cgImage:cache:)`. Both call sites (Single and Split HUD) pass it.

- `RawHistogramView` (new private struct in same file, or `QuickCull/RawHistogramView.swift`):

```swift
private struct RawHistogramView: View {
    let histogram: RawHistogram
    var body: some View {
        Canvas { ctx, size in
            // log-y: log10(1+count) normalized to max
            // x: bin -> size.width * (bin+1)/binCount
            // draw additive R, G, B fills + clipping marker at sensorMax bin
        }
        .background(.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
```

- Visual: 256-bin x-axis spanning full width; per-channel additive fills (`Color.red.opacity(0.55)`, `green`, `blue`); log-y (`log10(1+count)` / max) so shadows aren't a flat line; vertical white line at the `sensorMax` bin (right edge) only when `clipping` > 0.001 for any channel (else no marker); no axes/labels (glanceable, fits 240pt).
- No histogram state in `ScrubView`; the block lives inside the existing HUD scroll content.

## Data Flow

```
import → DecodeEngine worker → LibRawDecoder (unpack → count → histogram on RawBitmap)
      → ImageCacheStore.storeJPEG + storeHistogram (sidecar .hist.json)
scrub with HUD open → MetadataHUDView.task(id: file.id-dims)
      → loadHistogram(sidecar) ?? DisplayHistogram.compute(cgImage)
      → RawHistogramView Canvas
```

## Error Handling & Edge Cases

- `raw_image == nil` (X3F/Foveon, some cameras) → `RawBitmap.histogram = nil` → display fallback.
- Sidecar missing/corrupt (crash between store, older cache) → `loadHistogram` returns nil → display fallback; no crash.
- Non-RAW (ImageIO) → histogram nil → display fallback computed from the HUD's `cgImage` (thumb-resolution upgrade re-runs via existing compound task id).
- Histogram store failure → `try?` — import outcome unaffected; HUD falls back.
- All-black/empty bins → `RawHistogramView` draws nothing (log of 1 normalizes to 0); no divide-by-zero (`samples + 1` guard).
- Split view: HUD is left-pane only; right pane has no HUD (unchanged).
- `cgImage` nil (loading) → HUD shows "Loading…" rows as today; histogram block absent until loaded.

## Testing

`QuickCullCoreTests/RawHistogramTests.swift` (new) + extend `LibRawDecoderTests`/`ImageCacheStoreTests`:

- `testRawHistogramComputedForFixtures` — for each pinned raw fixture, `bitmap.histogram != nil`, `bins.count == 3`, each 256 wide, `samples[i] == raw_width * raw_height` per channel (sum of R+G+B = pixels), `sensorMax > 0`.
- `testHistogramCodableRoundTrip` — encode → decode equality.
- `testDisplayHistogramFallback` — synthetic `CGImage` (e.g. 32×16 flat gray 128) → bins sum = pixel count, peak at expected bin; `DisplayHistogram.compute` returns non-nil bins.
- `testCacheHistogramRoundTrip` — `storeHistogram` → `loadHistogram` equals; missing file → nil; corrupt JSON → nil.
- `testDecodeEngineStoresHistogram` — existing DecodeEngine test doubles: assert `storeHistogram` called for a bitmap with histogram, not called for nil-histogram bitmaps (add to `DecodeEngineTests` with a stub decoder).
- Existing 116 tests unaffected (`RawBitmap` gains a defaulted field; `ImageIODecoder` unchanged).

## Files

- Create: `QuickCullCore/Metadata/RawHistogram.swift` (struct + display fallback)
- Create: `QuickCullCoreTests/RawHistogramTests.swift`
- Modify: `QuickCullCore/Decoding/RawDecoding.swift` (`RawBitmap.histogram`, default nil)
- Modify: `QuickCullCore/Decoding/LibRawDecoder.swift` (compute histogram post-unpack)
- Modify: `QuickCullCore/Storage/ImageCacheStore.swift` (store/load sidecar)
- Modify: `QuickCullCore/Engine/DecodeEngine.swift` (store histogram with JPEG)
- Modify: `QuickCull/ImageDisplayView.swift` (`MetadataHUDView` + `RawHistogramView`, pass `appState.cache`)
- Modify: `QuickCullCoreTests/DecodeEngineTests.swift`, `ImageCacheStoreTests.swift` (new cases)

No new targets. `ScrubView`, `Session`, `ImageWindow`, `FilmstripView`, `GridView` unchanged.

## Acceptance Criteria

- RAW histogram appears in HUD for every LibRaw file immediately while scrubbing (no re-decode).
- RGB overlay + log-y + clipping marker at sensorMax; non-RAW files show display fallback.
- Import time unchanged (histogram pass negligible); sidecars wiped on launch like JPEGs.
- Build passes; all tests green including new histogram tests.
