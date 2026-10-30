# RAW Histogram in Metadata HUD — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compute a true linear RAW histogram during import (near-free pass after `libraw_unpack`), cache it as a JSON sidecar next to the cached JPEG, and render it as an RGB overlay in the metadata HUD with a display-histogram fallback for non-RAW files.

**Architecture:** `RawHistogram` (Codable/Sendable, 256 bins × 3 channels) is computed in `LibRawDecoder` post-unpack and returned on `RawBitmap`. `ImageCacheStore` stores/loads `<cacheKey>.hist.json`. `DecodeEngine` stores the sidecar after each JPEG. `MetadataHUDView` loads sidecar-or-fallback in its existing `.task(id:)` and renders via a SwiftUI `Canvas` view.

**Tech Stack:** Swift 5.10+, LibRaw C API (`libraw_data_t` pointee), SwiftUI `Canvas`, `JSONEncoder/Decoder`, Xcode 15, `xcodebuild`

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-18-raw-histogram-design.md` (approved 2026-08-18).
- Histogram counts pre-white-balance, pre-gamma linear sensor data from `rawdata.raw_image`; Bayer color mapping via dcraw `fcol`: `(filters >> (((row & 1) << 1 | (col & 1)) << 1)) & 3` with 0=R, 1=G, 2=B, 3=G2 merged into green (index 1).
- 256 bins per channel; `sensorMax` from `sizes.maximum` (fallback 16383 if 0); bin = `(v * 255) / sensorMax` clamped.
- `RawHistogram` is `Codable, Equatable, Sendable`; `bins: [[Int]]` count 3, each 256 wide; `clipping` uses `Double(b.last!) / Double(total + 1)`.
- `RawBitmap` gains `public let histogram: RawHistogram?` with default `nil` — all existing initializer call sites stay valid.
- Sidecar path: `cacheURL(for:).appendingPathExtension("hist").appendingPathExtension("json")` i.e. `<cacheKey>.hist.json`; atomic write (tmp + replace); `loadHistogram` returns `nil` for missing/corrupt.
- Histogram store failure must NOT fail the import (`try?` in `DecodeEngine`; decode outcome unchanged).
- Non-RAW fallback: `DisplayHistogram.compute(from: CGImage)` 256-bin RGB from rendered pixels (bins sum = pixel count per channel, 8-bit sensorMax 255).
- `MetadataHUDView` renders histogram block above key/value rows, height 72, `RawHistogramView` Canvas: additive RGB fills (`opacity 0.55`), log-y (`log10(1+count)` normalized to max), clipping marker line only when any channel `clipping > 0.001`; no axes/labels.
- No new targets; `ScrubView`, `Session`, `ImageWindow`, `FilmstripView`, `GridView` unchanged.
- Build: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build` must pass. Tests: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS'` must pass (existing 116 + new).

---

## File Structure

- **Create:** `QuickCullCore/Metadata/RawHistogram.swift` — `RawHistogram` struct + `DisplayHistogram` enum (fallback computer).
- **Create:** `QuickCullCoreTests/RawHistogramTests.swift` — model, codable, fallback tests.
- **Modify:** `QuickCullCore/Decoding/RawDecoding.swift` — `RawBitmap.histogram` default nil.
- **Modify:** `QuickCullCore/Decoding/LibRawDecoder.swift` — post-unpack histogram computation.
- **Modify:** `QuickCullCore/Storage/ImageCacheStore.swift` — sidecar store/load.
- **Modify:** `QuickCullCore/Engine/DecodeEngine.swift` — store histogram after JPEG.
- **Modify:** `QuickCull/ImageDisplayView.swift` — `MetadataHUDView` + `RawHistogramView`, pass `appState.cache`.
- **Modify:** `QuickCullCoreTests/DecodeEngineTests.swift`, `QuickCullCoreTests/ImageCacheStoreTests.swift`, `QuickCullCoreTests/TestDoubles.swift` — new cases / stub histogram support.

---

### Task 1: RawHistogram model + DisplayHistogram fallback

**Files:**
- Create: `QuickCullCore/Metadata/RawHistogram.swift`
- Test: `QuickCullCoreTests/RawHistogramTests.swift`

**Interfaces:**
- Produces (used by Tasks 2-5):
  - `public struct RawHistogram: Codable, Equatable, Sendable` with `public static let binCount = 256`, `public let bins: [[Int]]`, `public let sensorMax: Int`, `public let samples: [Int]`, `public let clipping: [Double]`, `public init(bins: [[Int]], sensorMax: Int)`.
  - `public enum DisplayHistogram { public static func compute(from cgImage: CGImage) -> RawHistogram }`

- [ ] **Step 1: Write the failing tests**

Create `QuickCullCoreTests/RawHistogramTests.swift`:

```swift
import CoreGraphics
import XCTest
@testable import QuickCullCore

final class RawHistogramTests: XCTestCase {
    func testInitComputesSamplesAndClipping() {
        let bins = [
            [0, 10, 0, 5],   // red: total 15
            [1, 2, 3, 9],    // green: total 15, last=9 → clipping 9/16
            [0, 0, 0, 0],
        ]
        let h = RawHistogram(bins: bins, sensorMax: 255)
        XCTAssertEqual(h.samples, [15, 15, 0])
        XCTAssertEqual(h.binCount, 256)
        XCTAssertEqual(h.clipping[0], 10.0 / 16.0, accuracy: 1e-9)
        XCTAssertEqual(h.clipping[2], 0.0, accuracy: 1e-9)
        XCTAssertEqual(h.sensorMax, 255)
    }

    func testCodableRoundTrip() throws {
        let h = RawHistogram(bins: [[0, 1, 2], [3, 4, 5], [6, 7, 8]], sensorMax: 16383)
        let data = try JSONEncoder().encode(h)
        let decoded = try JSONDecoder().decode(RawHistogram.self, from: data)
        XCTAssertEqual(decoded, h)
    }

    func testDisplayHistogramOfFlatGrayImage() {
        let img = TestFixtures.makeCGImage(width: 32, height: 16, color: 128)
        let h = DisplayHistogram.compute(from: img)
        XCTAssertEqual(h.bins.count, 3)
        XCTAssertTrue(h.bins.allSatisfy { $0.count == RawHistogram.binCount })
        // flat gray: every channel pegged at 128
        let expectedBin = 128 * (RawHistogram.binCount - 1) / 255
        for channel in 0..<3 {
            XCTAssertEqual(h.bins[channel][expectedBin], 32 * 16)
            XCTAssertEqual(h.samples[channel], 32 * 16)
        }
        XCTAssertEqual(h.sensorMax, 255)
    }
}
```

Note: `TestFixtures.makeCGImage(width:height:color:)` exists in `QuickCullCoreTests/TestFixtures.swift` and returns an 8-bit RGB CGImage.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' -only-testing:QuickCullCoreTests/RawHistogramTests`
Expected: FAIL — compile error "cannot find 'RawHistogram' in scope".

- [ ] **Step 3: Implement RawHistogram.swift**

Create `QuickCullCore/Metadata/RawHistogram.swift`:

```swift
import CoreGraphics
import Foundation

/// Linear sensor histogram (256 bins × RGB) computed from LibRaw's
/// unpacked raw data, plus a display-histogram fallback for non-RAW files.
public struct RawHistogram: Codable, Equatable, Sendable {
    public static let binCount = 256
    /// Per-channel counts: [red, green, blue], 256 bins each.
    public let bins: [[Int]]
    /// Highest possible sensor level (e.g. 16383 for 14-bit).
    public let sensorMax: Int
    /// Total samples per channel (sum of bins).
    public let samples: [Int]
    /// Fraction of samples at the top bin per channel (0...1).
    public let clipping: [Double]

    public init(bins: [[Int]], sensorMax: Int) {
        self.bins = bins
        self.sensorMax = sensorMax
        self.samples = bins.map { $0.reduce(0, +) }
        self.clipping = bins.map { b in
            guard !b.isEmpty else { return 0 }
            return Double(b[b.count - 1]) / Double(b.reduce(0, +) + 1)
        }
    }
}

/// Histogram of a rendered CGImage (fallback for non-RAW files).
public enum DisplayHistogram {
    public static func compute(from cgImage: CGImage) -> RawHistogram {
        let width = cgImage.width
        let height = cgImage.height
        var bins = [[Int]](repeating: [Int](repeating: 0, count: RawHistogram.binCount), count: 3)
        guard width > 0, height > 0 else {
            return RawHistogram(bins: bins, sensorMax: 255)
        }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return RawHistogram(bins: bins, sensorMax: 255)
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            bins[0][pixels[i] * (RawHistogram.binCount - 1) / 255] += 1
            bins[1][pixels[i + 1] * (RawHistogram.binCount - 1) / 255] += 1
            bins[2][pixels[i + 2] * (RawHistogram.binCount - 1) / 255] += 1
        }
        return RawHistogram(bins: bins, sensorMax: 255)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' -only-testing:QuickCullCoreTests/RawHistogramTests`
Expected: PASS — 3/3.

- [ ] **Step 5: Commit**

```bash
git add QuickCullCore/Metadata/RawHistogram.swift QuickCullCoreTests/RawHistogramTests.swift
git commit -m "feat: raw histogram model with display fallback (256-bin RGB, codable)"
```

---

### Task 2: RawBitmap.histogram + LibRawDecoder computes it post-unpack

**Files:**
- Modify: `QuickCullCore/Decoding/RawDecoding.swift`
- Modify: `QuickCullCore/Decoding/LibRawDecoder.swift`
- Test: `QuickCullCoreTests/LibRawDecoderTests.swift`

**Interfaces:**
- Consumes: `RawHistogram` from Task 1; LibRaw C fields `handle.pointee.rawdata.raw_image` (`UnsafeMutablePointer<UInt16>?`), `handle.pointee.sizes.raw_width/raw_height/maximum` (`UInt32`), `handle.pointee.idata.filters` (`UInt32`).
- Produces: `RawBitmap.histogram: RawHistogram?` (default nil), populated by `LibRawDecoder`; consumed by Task 4 (DecodeEngine) and Task 5 (HUD).

- [ ] **Step 1: Add the defaulted field (no test yet — existing tests must still compile)**

Edit `QuickCullCore/Decoding/RawDecoding.swift`:

```swift
public struct RawBitmap {
    public let image: CGImage
    public let width: Int
    public let height: Int
    /// LibRaw flip value (0-7). Informational only: the pixel buffer is
    /// already upright (dcraw_process applied the flip).
    public let flip: Int
    /// Linear sensor histogram from the raw data (nil for non-RAW or
    /// formats without a Bayer raw_image, e.g. X3F).
    public let histogram: RawHistogram?

    public init(image: CGImage, width: Int, height: Int, flip: Int, histogram: RawHistogram? = nil) {
        self.image = image
        self.width = width
        self.height = height
        self.flip = flip
        self.histogram = histogram
    }
}
```

- [ ] **Step 2: Write the failing test**

Append to `QuickCullCoreTests/LibRawDecoderTests.swift`:

```swift
func testHistogramComputedForRawFixtures() throws {
    let cases: [(name: String, ext: String)] = [
        ("img_0062", "cr2"), ("mg_2233", "cr3"), ("dsc8140", "nef"), ("dsc0258", "arw"),
        ("fuji_e550", "raf"), ("olympus_c5050z", "orf"), ("p1000336", "rw2"), ("pentax_k01", "dng"),
    ]
    for c in cases {
        let bitmap = try decoder.decodeRaw(at: fixture(c.name, c.ext))
        let hist = try XCTUnwrap(bitmap.histogram, "\(c.name).\(c.ext) should have a raw histogram")
        XCTAssertEqual(hist.bins.count, 3, c.name)
        XCTAssertTrue(hist.bins.allSatisfy { $0.count == RawHistogram.binCount }, c.name)
        XCTAssertGreaterThan(hist.sensorMax, 0, c.name)
        // per-channel sums: R+G+B covers every Bayer pixel exactly once
        let total = hist.samples.reduce(0, +)
        let w = bitmap.width, h = bitmap.height
        XCTAssertEqual(total, w * h, "\(c.name) histogram must cover every pixel")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' -only-testing:QuickCullCoreTests/LibRawDecoderTests/testHistogramComputedForRawFixtures`
Expected: FAIL — `XCTUnwrap` fails: histogram is nil.

- [ ] **Step 4: Implement computation in LibRawDecoder**

Edit `QuickCullCore/Decoding/LibRawDecoder.swift` — after `libraw_unpack` succeeds (before params/`libraw_dcraw_process`):

```swift
let histogram = Self.rawHistogram(from: handle)
```

and change the return to:

```swift
return RawBitmap(image: image,
                 width: Int(p.width),
                 height: Int(p.height),
                 flip: Int(handle.pointee.sizes.flip),
                 histogram: histogram)
```

Add the static helper inside `LibRawDecoder`:

```swift
private static func rawHistogram(from handle: UnsafeMutablePointer<libraw_data_t>) -> RawHistogram? {
    let raw = handle.pointee.rawdata
    let sizes = handle.pointee.sizes
    let filters = handle.pointee.idata.filters
    guard let ptr = raw.raw_image, sizes.raw_width > 0, sizes.raw_height > 0 else { return nil }
    let maxLevel = Int(sizes.maximum != 0 ? sizes.maximum : 16383)
    var counts = [[Int]](repeating: [Int](repeating: 0, count: RawHistogram.binCount), count: 3)
    let w = Int(sizes.raw_width), h = Int(sizes.raw_height)
    for row in 0..<h {
        for col in 0..<w {
            // dcraw fcol: Bayer color at (row,col)
            let c = Int((filters >> (((row & 1) << 1 | (col & 1)) << 1)) & 3)
            // 0=R, 1=G, 2=B, 3=G2 → merge G2 into green (index 1)
            let channel = c == 3 ? 1 : c
            let v = Int(ptr[row * w + col])
            let bin = min(RawHistogram.binCount - 1, max(0, (v * (RawHistogram.binCount - 1)) / maxLevel))
            counts[channel][bin] += 1
        }
    }
    return RawHistogram(bins: counts, sensorMax: maxLevel)
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' -only-testing:QuickCullCoreTests/LibRawDecoderTests`
Expected: PASS — all 5 LibRawDecoderTests (4 existing + new). Existing tests still compile because `histogram` is defaulted.

- [ ] **Step 6: Commit**

```bash
git add QuickCullCore/Decoding/RawDecoding.swift QuickCullCore/Decoding/LibRawDecoder.swift QuickCullCoreTests/LibRawDecoderTests.swift
git commit -m "feat: compute raw histogram in LibRawDecoder post-unpack (Bayer fcol, 256-bin RGB)"
```

---

### Task 3: ImageCacheStore sidecar store/load

**Files:**
- Modify: `QuickCullCore/Storage/ImageCacheStore.swift`
- Test: `QuickCullCoreTests/ImageCacheStoreTests.swift`

**Interfaces:**
- Consumes: `RawHistogram` (Task 1), existing `cacheURL(for:)`.
- Produces (used by Tasks 4-5):
  - `public func histogramURL(for file: SessionFile) throws -> URL` — `cacheURL` + `.hist.json` suffix.
  - `public func storeHistogram(_ hist: RawHistogram, for file: SessionFile) throws` — atomic write.
  - `public func loadHistogram(for file: SessionFile) throws -> RawHistogram?` — nil when missing/corrupt.

- [ ] **Step 1: Write the failing tests**

Append to `QuickCullCoreTests/ImageCacheStoreTests.swift`:

```swift
func testStoreAndLoadHistogramRoundTrip() async throws {
    let file = SessionFile(url: try TestFixtures.makeRawFile(named: "a.cr2", in: base))
    let hist = RawHistogram(bins: [[0, 1, 2], [3, 4, 5], [6, 7, 8]], sensorMax: 16383)
    try await store.storeHistogram(hist, for: file)
    let loaded = try await store.loadHistogram(for: file)
    XCTAssertEqual(loaded, hist)
}

func testLoadHistogramMissingReturnsNil() async throws {
    let file = SessionFile(url: try TestFixtures.makeRawFile(named: "b.cr2", in: base))
    let loaded = try await store.loadHistogram(for: file)
    XCTAssertNil(loaded)
}

func testLoadHistogramCorruptReturnsNil() async throws {
    let file = SessionFile(url: try TestFixtures.makeRawFile(named: "c.cr2", in: base))
    let url = try await store.histogramURL(for: file)
    try Data("not json".utf8).write(to: url)
    let loaded = try await store.loadHistogram(for: file)
    XCTAssertNil(loaded)
}

func testHistogramURLSharesCacheKey() async throws {
    let file = SessionFile(url: try TestFixtures.makeRawFile(named: "d.cr2", in: base))
    let jpg = try await store.cacheURL(for: file)
    let hist = try await store.histogramURL(for: file)
    XCTAssertEqual(hist.deletingPathExtension().deletingPathExtension().lastPathComponent,
                   jpg.lastPathComponent)
    XCTAssertTrue(hist.lastPathComponent.hasSuffix(".hist.json"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' -only-testing:QuickCullCoreTests/ImageCacheStoreTests`
Expected: FAIL — compile errors: `storeHistogram`, `loadHistogram`, `histogramURL` not found.

- [ ] **Step 3: Implement sidecar in ImageCacheStore**

Edit `QuickCullCore/Storage/ImageCacheStore.swift` — add after `storeJPEG`:

```swift
    /// Sidecar URL for the raw histogram: same cache key, `.hist.json`.
    public func histogramURL(for file: SessionFile) throws -> URL {
        try cacheURL(for: file)
            .appendingPathExtension("hist")
            .appendingPathExtension("json")
    }

    /// Store the raw histogram as an atomic JSON sidecar next to the JPEG.
    public func storeHistogram(_ hist: RawHistogram, for file: SessionFile) throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let destination = try histogramURL(for: file)
        let tmp = destination.appendingPathExtension("tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let data = try JSONEncoder().encode(hist)
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: destination)
        }
    }

    /// Load the raw histogram sidecar; nil when missing or corrupt.
    public func loadHistogram(for file: SessionFile) throws -> RawHistogram? {
        let url = try histogramURL(for: file)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let hist = try? JSONDecoder().decode(RawHistogram.self, from: data) else {
            return nil
        }
        return hist
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' -only-testing:QuickCullCoreTests/ImageCacheStoreTests`
Expected: PASS — 11/11 (7 existing + 4 new).

- [ ] **Step 5: Commit**

```bash
git add QuickCullCore/Storage/ImageCacheStore.swift QuickCullCoreTests/ImageCacheStoreTests.swift
git commit -m "feat: histogram sidecar store/load in ImageCacheStore (atomic JSON)"
```

---

### Task 4: DecodeEngine stores histogram sidecar after JPEG

**Files:**
- Modify: `QuickCullCore/Engine/DecodeEngine.swift`
- Modify: `QuickCullCoreTests/TestDoubles.swift`
- Modify: `QuickCullCoreTests/DecodeEngineTests.swift`

**Interfaces:**
- Consumes: `RawBitmap.histogram` (Task 2), `ImageCacheStore.storeHistogram` (Task 3).
- Produces: sidecar written per file during import; import outcome never fails because of histogram.

- [ ] **Step 1: Extend the stub decoder with an optional histogram**

Edit `QuickCullCoreTests/TestDoubles.swift` — `StubDecoder` gains a property:

```swift
    let failIDs: Set<String>
    let histogram: RawHistogram?

    init(failIDs: Set<String> = [], histogram: RawHistogram? = nil) {
        self.failIDs = failIDs
        self.histogram = histogram
    }
```

and its `decodeRaw` return becomes:

```swift
        return RawBitmap(image: image, width: width, height: height, flip: 0,
                         histogram: histogram)
```

- [ ] **Step 2: Write the failing test**

Append to `QuickCullCoreTests/DecodeEngineTests.swift`:

```swift
func testHistogramSidecarWrittenWhenBitmapHasHistogram() async throws {
    let files = TestFixtures.makeFiles(["a.cr2", "b.cr2"])
    let hist = RawHistogram(bins: [[0, 1], [2, 3], [4, 5]], sensorMax: 255)
    let (cache, base) = try await TestFixtures.makeTempCache()
    defer { try? FileManager.default.removeItem(at: base) }
    let engine = DecodeEngine(decoder: StubDecoder(histogram: hist), cache: cache)

    _ = await collect(engine.decodeAll(files: files))
    // 2 JPEGs + 2 sidecars
    let contents = try FileManager.default.contentsOfDirectory(atPath: base.path)
    XCTAssertEqual(contents.filter { $0.hasSuffix(".jpg") }.count, 2)
    XCTAssertEqual(contents.filter { $0.hasSuffix(".hist.json") }.count, 2)
    for file in files {
        XCTAssertEqual(try await cache.loadHistogram(for: file), hist)
    }
}

func testNoHistogramSidecarWhenBitmapHasNone() async throws {
    let files = TestFixtures.makeFiles(["a.cr2", "b.cr2"])
    let (cache, base) = try await TestFixtures.makeTempCache()
    defer { try? FileManager.default.removeItem(at: base) }
    let engine = DecodeEngine(decoder: StubDecoder(), cache: cache)

    _ = await collect(engine.decodeAll(files: files))
    let contents = try FileManager.default.contentsOfDirectory(atPath: base.path)
    XCTAssertEqual(contents.count, 2)
    XCTAssertTrue(contents.allSatisfy { $0.hasSuffix(".jpg") })
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' -only-testing:QuickCullCoreTests/DecodeEngineTests/testHistogramSidecarWrittenWhenBitmapHasHistogram -only-testing:QuickCullCoreTests/DecodeEngineTests/testNoHistogramSidecarWhenBitmapHasNone`
Expected: FAIL — first test: 0 `.hist.json` files.

- [ ] **Step 4: Implement store in DecodeEngine**

Edit `QuickCullCore/Engine/DecodeEngine.swift` — in the worker loop, after `storeJPEG`:

```swift
                                do {
                                    let bitmap = try self.decoder.decodeRaw(at: file.url)
                                    try await self.cache.storeJPEG(bitmap, for: file)
                                    // Histogram sidecar is best-effort: its failure
                                    // must never fail the import.
                                    if let hist = bitmap.histogram {
                                        try? await self.cache.storeHistogram(hist, for: file)
                                    }
                                    outcome = DecodeOutcome(file: file, error: nil)
                                } catch let error as DecodeError {
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' -only-testing:QuickCullCoreTests/DecodeEngineTests`
Expected: PASS — 9/9 including both new tests.

- [ ] **Step 6: Fix the integration test count and run the full suite**

`testRealDecoderIntegrationWithFixtures` currently asserts `contents.count == 8`; with real LibRawDecoder each of the 8 fixtures now also writes a `.hist.json`, so the directory holds 16 entries. Edit that assertion in `QuickCullCoreTests/DecodeEngineTests.swift`:

```swift
        let contents = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(contents.filter { $0.hasSuffix(".jpg") }.count, 8)
        XCTAssertEqual(contents.filter { $0.hasSuffix(".hist.json") }.count, 8)
```

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS'`
Expected: PASS — 124 tests total (116 existing + 3 RawHistogram + 1 LibRaw + 4 ImageCacheStore; 2 DecodeEngine new = 126; verify by actual count in output and expect 0 failures).

- [ ] **Step 7: Commit**

```bash
git add QuickCullCore/Engine/DecodeEngine.swift QuickCullCoreTests/TestDoubles.swift QuickCullCoreTests/DecodeEngineTests.swift
git commit -m "feat: store histogram sidecar during import (best-effort, never fails decode)"
```

---

### Task 5: HUD renders histogram block with RawHistogramView

**Files:**
- Modify: `QuickCull/ImageDisplayView.swift`

**Interfaces:**
- Consumes: `RawHistogram` + `DisplayHistogram` (Task 1), `ImageCacheStore.loadHistogram` (Task 3), `appState.cache` via `@Environment(AppState.self)`.
- Produces: `MetadataHUDView(file:cgImage:cache:)` signature change; `RawHistogramView(histogram:)` private view.

- [ ] **Step 1: Verify current HUD signature and call sites**

```bash
rg -n "MetadataHUDView" QuickCull/ImageDisplayView.swift
```
Expected: definition `private struct MetadataHUDView` (2 properties: `file`, `cgImage`) + 2 call sites inside `ImageDisplayView.body` (Split branch `hudVisible` block and Single branch `hudVisible` block).

- [ ] **Step 2: Update MetadataHUDView with cache + histogram loading**

Edit `QuickCull/ImageDisplayView.swift`:

```swift
private struct MetadataHUDView: View {
    let file: SessionFile
    let cgImage: CGImage?
    let cache: ImageCacheStore
    @State private var metadata: ImageMetadata?
    @State private var histogram: RawHistogram?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let hist = histogram {
                    RawHistogramView(histogram: hist)
                        .frame(height: 72)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                }
                ForEach(rows, id: \.label) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.label).font(.caption2).foregroundStyle(.secondary)
                        Text(row.value).font(.caption).foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(row.label == "File" ? (metadata?.filePath ?? row.value) : row.value)
                    }
                }
            }
            .padding(10)
        }
        .task(id: "\(file.id)-\(cgImage?.width ?? 0)x\(cgImage?.height ?? 0)") {
            metadata = await Task.detached(priority: .utility) {
                ImageMetadataProvider.metadata(for: file, cgImage: cgImage)
            }.value
            // Raw histogram sidecar first; display fallback for non-RAW/missing.
            histogram = await Task.detached(priority: .utility) {
                (try? await cache.loadHistogram(for: file)) ?? cgImage.map { DisplayHistogram.compute(from: $0) }
            }.value
        }
    }
    // ... rows property unchanged ...
}
```

- [ ] **Step 3: Add RawHistogramView**

Append to `QuickCull/ImageDisplayView.swift` (after `MetadataHUDView`):

```swift
/// RGB histogram overlay with log-y scaling and a clipping marker at
/// sensorMax. 256 bins span the width; channels are additive fills.
private struct RawHistogramView: View {
    let histogram: RawHistogram

    var body: some View {
        Canvas { ctx, size in
            let binCount = RawHistogram.binCount
            guard size.width > 0, size.height > 0 else { return }
            let logMax = histogram.bins
                .flatMap { $0 }
                .map { log10(Double($0) + 1) }
                .max() ?? 1
            func yFor(_ count: Int) -> Double {
                size.height * (1 - log10(Double(count) + 1) / logMax)
            }
            let binW = size.width / Double(binCount)
            let colors: [Color] = [.red.opacity(0.55), .green.opacity(0.55), .blue.opacity(0.55)]
            for channel in 0..<3 {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for bin in 0..<binCount {
                    let x = Double(bin) * binW
                    let y = yFor(histogram.bins[channel][bin])
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                ctx.fill(path, with: .color(colors[channel]))
            }
            if histogram.clipping.contains(where: { $0 > 0.001 }) {
                var line = Path()
                line.move(to: CGPoint(x: size.width - 1, y: 0))
                line.addLine(to: CGPoint(x: size.width - 1, y: size.height))
                ctx.stroke(line, with: .color(.white), lineWidth: 1)
            }
        }
        .background(.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("RAW histogram")
    }
}
```

- [ ] **Step 4: Update both call sites to pass cache**

In `ImageDisplayView.body` Split branch (`MetadataHUDView(file: file, cgImage: lcg)`):

```swift
MetadataHUDView(file: file, cgImage: lcg, cache: appState.cache)
```

In Single branch (`MetadataHUDView(file: file, cgImage: cgImage)`):

```swift
MetadataHUDView(file: file, cgImage: cgImage, cache: appState.cache)
```

- [ ] **Step 5: Build and run full test suite**

Run: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build`
Expected: PASS (warnings pre-existing).

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS'`
Expected: PASS — 0 failures.

- [ ] **Step 6: Manual QA**

`./start.sh`, import the fixture set + a JPEG:
- HUD (Show Metadata) on a RAW: histogram block appears above rows, RGB fill shapes vary per image, right-edge white marker appears on a clipped shot (e.g. `olympus_c5050z` or a blown-highlight raw).
- Scrub rapidly with HUD open: histogram updates with each file, no stutter, no re-decode delay.
- JPEG/PNG: display-histogram fallback shows (flat gray if uniform).
- X3F (if available) or a file whose sidecar is deleted: fallback, no crash.
- Split view with HUD: left pane HUD shows histogram; right pane unchanged.
- Cache dir after import contains `.hist.json` files; relaunch wipes them with the cache.

- [ ] **Step 7: Commit**

```bash
git add QuickCull/ImageDisplayView.swift
git commit -m "feat: raw histogram block in metadata HUD (RGB overlay, log-y, clip marker, display fallback)"
```

---

## Self-Review

**Spec coverage:**
- Model `RawHistogram` + `DisplayHistogram` (spec "Model") → Task 1.
- LibRaw post-unpack computation with Bayer fcol + G2 merge + sensorMax (spec "Computation") → Task 2.
- `RawBitmap.histogram` default nil (spec "Model") → Task 2 Step 1.
- Sidecar store/load/atomic/missing→nil (spec "Storage") → Task 3.
- DecodeEngine best-effort store, never fails import (spec "Storage"/"Data Flow") → Task 4.
- HUD block above rows, 72pt, additive RGB, log-y, clip marker >0.001, fallback via existing task id, cache passed from appState (spec "UI") → Task 5.
- Error handling: nil raw_image, missing/corrupt sidecar, non-RAW fallback, all-black bins (spec "Error Handling") → Tasks 2/3/5 + tests.
- Acceptance: no re-decode while scrubbing (sidecar read), import unchanged, wipe covers sidecars, build+tests green → Tasks 4/5/6 verification steps.

**Placeholder scan:** No TBD/TODO; every step has concrete code + commands; no "similar to Task N".

**Type consistency:** `RawHistogram(bins:sensorMax:)` init used identically in Tasks 1-4; `bins.count == 3`, `binCount == 256` everywhere; `histogramURL` = cacheURL + `.hist.json` (Task 3 test asserts); `storeHistogram(_:for:)`/`loadHistogram(for:)` signatures match DecodeEngine (Task 4) and HUD (Task 5) usage; `MetadataHUDView(file:cgImage:cache:)` matches both call sites in Task 5. `StubDecoder(histogram:)` param matches `TestDoubles` edit and DecodeEngineTests usage.

**Test-count note:** After all tasks the suite is 126 tests (116 existing + 3 + 1 + 4 + 2); DecodeEngine integration fixture-count assertion is explicitly updated in Task 4 Step 6 (8 JPEGs + 8 sidecars). The plan tells the implementer to verify by actual output, not to hard-code 126 in any assertion.
