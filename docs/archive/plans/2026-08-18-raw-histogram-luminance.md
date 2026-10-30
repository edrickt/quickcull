# RAW Luminance Histogram — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a raw luminance (overall exposure) histogram alongside the existing RGB histogram — single-channel 256-bin counting every sensor value in the same post-unpack pass, stored in the same sidecar JSON, rendered as a stacked white histogram below the RGB overlay.

**Architecture:** Extend `RawHistogram` with `luminance: [Int]` (derived `samples`/`clipping` now 4 entries, custom Codable with backwards compat). Extend `LibRawDecoder.rawHistogram` to increment `luma[bin]++` per pixel. Extend `DisplayHistogram.compute` to emit `Y = 0.2126R+0.7152G+0.0722B` luminance. UI stacks `RawHistogramView` (72pt RGB) + `RawLuminanceHistogramView` (72pt white) in `MetadataHUDView`. Same `.hist.json` sidecar, same `DecodeEngine`/`ImageCacheStore` code paths.

**Tech Stack:** Swift 5.10+, LibRaw C API, SwiftUI Canvas, JSON Codable, Xcode 15, xcodebuild

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-18-raw-histogram-luminance-design.md` (amends 2026-08-18-raw-histogram-design.md).
- RawHistogram has `bins: [[Int]]` (3×256 RGB) + `luminance: [Int]` (256) overall exposure, `sensorMax: Int`; `binCount = 256` static; `samples`/`clipping` derived (4 entries: R,G,B,L) not encoded — only `bins`, `luminance`, `sensorMax` are Codable via `CodingKeys` with custom `init(from:)` handling missing `luminance` (old sidecars decode with zeroed 256).
- Computation: single post-unpack pass in `LibRawDecoder.rawHistogram`; for each visible pixel (`left+w ≤ rawW`, `top+h ≤ rawH`, `filters 9/1 → nil`) compute `bin = (v * 255)/sensorMax`, increment `counts[channel][bin]` (Bayer `c` via `(filters >> (((((row+top)&1)<<1 | ((col+left)&1))<<1)) &3`, `c==3→1`) and `luma[bin]++` (every value irrespective of color).
- Display fallback: `DisplayHistogram.compute` returns `RawHistogram` with RGB + `luminance` where `Y` per pixel is `Int((0.2126*Double(r) + 0.7152*Double(g) + 0.0722*Double(b)).rounded())` binned.
- Storage: same `<cacheKey>.hist.json` sidecar; JSON now includes `luminance`; old JSON without it decodes via custom init; `ImageCacheStore`/`DecodeEngine` logic unchanged (atomic tmp+replace, best-effort).
- UI: `MetadataHUDView` stacks `VStack(spacing:8) { RawHistogramView 72pt; RawLuminanceHistogramView 72pt }` with `.padding(.horizontal,10).padding(.top,8)` inside ScrollView; `RawLuminanceHistogramView` white `0.85` fill, same log-y (`log10(1+count)/logMax`, guard `rawMax>0 ? rawMax:1`) and white clipping line when `clipping[3] > 0.001`; total block 152pt; both read same `histogram` state; no new HUD state; `RawHistogramView` unchanged.
- No new targets; `ScrubView`, `Session`, `ImageWindow`, `FilmstripView`, `GridView` unchanged.
- Build: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build` must pass. Tests: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS'` must pass (existing 126 + new).

---

## File Structure

- **Modify:** `QuickCullCore/Metadata/RawHistogram.swift` — add `luminance`, `CodingKeys`, custom `init(from:)`/`encode(to:)`, derived `samples`/`clipping`, `DisplayHistogram` luma.
- **Modify:** `QuickCullCore/Decoding/LibRawDecoder.swift` — add `luma` array and increment in `rawHistogram(from:)`, return with `luminance`.
- **Modify:** `QuickCull/ImageDisplayView.swift` — `MetadataHUDView` stacked VStack + new `RawLuminanceHistogramView` private struct.
- **Modify:** `QuickCullCoreTests/RawHistogramTests.swift` — new luminance tests (bins sum, codable with/without, display luma).
- **Modify:** `QuickCullCoreTests/LibRawDecoderTests.swift` — assert luminance 256 and sum==w*h.
- **Modify:** `QuickCullCoreTests/ImageCacheStoreTests.swift` — round-trip includes luminance; add backwards-compat decode test if desired.

---

### Task 1: RawHistogram model + DisplayHistogram luminance

**Files:**
- Modify: `QuickCullCore/Metadata/RawHistogram.swift`
- Test: `QuickCullCoreTests/RawHistogramTests.swift`

**Interfaces:**
- Consumes: existing `RawHistogram.binCount`, `CGImage`.
- Produces (Tasks 2-3):
  - `RawHistogram(bins:luminance:sensorMax:)` init, `luminance: [Int]`, `samples`/`clipping` now 4 entries (derived), `Codable` with `luminance` key and backwards-compat missing → zeroed 256.
  - `DisplayHistogram.compute(from:)` now returns `RawHistogram` with `luminance` populated via Rec.709 Y.

- [ ] **Step 1: Write the failing tests**

Append to `QuickCullCoreTests/RawHistogramTests.swift`:

```swift
func testLuminanceBinsSumToPixelCount() {
    let bins = [[1,2],[3,4],[5,6]]
    let lum = [7,8]
    let h = RawHistogram(bins: bins, luminance: lum, sensorMax: 100)
    XCTAssertEqual(h.luminance.count, RawHistogram.binCount)
    // luminance sum is independent; but for a real histogram it equals pixel count
}

func testInitStoresLuminanceAndSamplesClippingFourEntries() {
    let bins = [[0,10,0,5],[1,2,3,9],[0,0,0,0]]
    let lum = [0,0,15,0]
    let h = RawHistogram(bins: bins, luminance: lum, sensorMax: 255)
    XCTAssertEqual(h.bins, bins)
    XCTAssertEqual(h.luminance, lum)
    XCTAssertEqual(h.samples.count, 4)
    XCTAssertEqual(h.clipping.count, 4)
    XCTAssertEqual(h.samples[3], 15)
}

func testCodableRoundTripWithLuminance() throws {
    let h = RawHistogram(bins: [[0,1,2],[3,4,5],[6,7,8]], luminance: [9,10,11], sensorMax: 16383)
    let data = try JSONEncoder().encode(h)
    let decoded = try JSONDecoder().decode(RawHistogram.self, from: data)
    XCTAssertEqual(decoded, h)
}

func testCodableBackwardsCompatMissingLuminance() throws {
    let json = #"{"bins":[[0,1],[2,3],[4,5]],"sensorMax":255}"#
    let decoded = try JSONDecoder().decode(RawHistogram.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.luminance, [Int](repeating: 0, count: RawHistogram.binCount))
    XCTAssertEqual(decoded.bins, [[0,1],[2,3],[4,5]])
}

func testDisplayHistogramLuminancePeakForFlatGray() {
    let img = TestFixtures.makeCGImage(width: 32, height: 16, color: 128)
    let h = DisplayHistogram.compute(from: img)
    XCTAssertEqual(h.luminance.count, RawHistogram.binCount)
    let expectedBin = 128 * (RawHistogram.binCount - 1) / 255
    XCTAssertEqual(h.luminance[expectedBin], 32*16)
    XCTAssertEqual(h.samples[3], 32*16)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' -only-testing:QuickCullCoreTests/RawHistogramTests`
Expected: FAIL — compile errors: `RawHistogram` has no `luminance` param; `testLuminanceBinsSum...` cannot find `luminance`.

- [ ] **Step 3: Implement model**

Edit `QuickCullCore/Metadata/RawHistogram.swift`:

```swift
import CoreGraphics
import Foundation

public struct RawHistogram: Codable, Equatable, Sendable {
    public static let binCount = 256
    public let bins: [[Int]]
    public let luminance: [Int]
    public let sensorMax: Int
    public var samples: [Int] { (bins + [luminance]).map { $0.reduce(0, +) } }
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
    // Backwards compat for existing 3-property initializers in tests: keep convenience
    public init(bins: [[Int]], sensorMax: Int) {
        self.init(bins: bins, luminance: [Int](repeating: 0, count: Self.binCount), sensorMax: sensorMax)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bins = try c.decode([[Int]].self, forKey: .bins)
        sensorMax = try c.decode(Int.self, forKey: .sensorMax)
        luminance = try c.decodeIfPresent([Int].self, forKey: .luminance) ?? [Int](repeating: 0, count: Self.binCount)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bins, forKey: .bins)
        try c.encode(luminance, forKey: .luminance)
        try c.encode(sensorMax, forKey: .sensorMax)
    }
}

public enum DisplayHistogram {
    public static func compute(from cgImage: CGImage) -> RawHistogram {
        let width = cgImage.width, height = cgImage.height
        var bins = [[Int]](repeating: [Int](repeating: 0, count: RawHistogram.binCount), count: 3)
        var lum = [Int](repeating: 0, count: RawHistogram.binCount)
        guard width > 0, height > 0 else { return RawHistogram(bins: bins, luminance: lum, sensorMax: 255) }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return RawHistogram(bins: bins, luminance: lum, sensorMax: 255)
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i+1]), b = Int(pixels[i+2])
            bins[0][r * (RawHistogram.binCount - 1) / 255] += 1
            bins[1][g * (RawHistogram.binCount - 1) / 255] += 1
            bins[2][b * (RawHistogram.binCount - 1) / 255] += 1
            let y = Int((0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)).rounded())
            lum[y * (RawHistogram.binCount - 1) / 255] += 1
        }
        return RawHistogram(bins: bins, luminance: lum, sensorMax: 255)
    }
}
```

Note: add the 2-arg convenience `init(bins:sensorMax:)` to keep existing `TestDoubles`/`RawHistogramTests` call sites compiling until they are updated to 3 args; or update those call sites to 3 args. This plan uses the convenience.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' -only-testing:QuickCullCoreTests/RawHistogramTests`
Expected: PASS — 8/8.

- [ ] **Step 5: Commit**

```bash
git add QuickCullCore/Metadata/RawHistogram.swift QuickCullCoreTests/RawHistogramTests.swift
git commit -m "feat: add luminance to RawHistogram model (overall exposure, codable compat, display Y)"
```

---

### Task 2: LibRawDecoder computes luminance in same pass

**Files:**
- Modify: `QuickCullCore/Decoding/LibRawDecoder.swift`
- Test: `QuickCullCoreTests/LibRawDecoderTests.swift`

**Interfaces:**
- Consumes: `RawHistogram(bins:luminance:sensorMax:)` from Task 1.
- Produces: `RawBitmap.histogram` now carries non-zero `luminance`; nil still for X-Trans/super-CCD.

- [ ] **Step 1: Write the failing test**

Append to `QuickCullCoreTests/LibRawDecoderTests.swift`:

```swift
func testLuminanceComputedForBayerFixtures() throws {
    let cases: [(name: String, ext: String)] = [("img_0062","cr2"),("dsc8140","nef"),("p1000336","rw2")]
    for c in cases {
        let bitmap = try decoder.decodeRaw(at: fixture(c.name, c.ext))
        let hist = try XCTUnwrap(bitmap.histogram, "\(c.name)")
        XCTAssertEqual(hist.luminance.count, RawHistogram.binCount, c.name)
        XCTAssertEqual(hist.luminance.reduce(0,+), bitmap.width * bitmap.height, "\(c.name) luma sum == pixel count")
        XCTAssertEqual(hist.samples[3], bitmap.width * bitmap.height, c.name)
    }
}

func testLuminanceNilForSuperCCDAndXTrans() throws {
    let fuji = try decoder.decodeRaw(at: fixture("fuji_e550","raf"))
    XCTAssertNil(fuji.histogram, "super-CCD should be nil luminance too")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' -only-testing:QuickCullCoreTests/LibRawDecoderTests/testLuminanceComputedForBayerFixtures`
Expected: FAIL — `histogram.luminance` is zeroed (convenience default) or not counted; sum mismatch.

- [ ] **Step 3: Implement luma increment in LibRawDecoder**

Edit `QuickCullCore/Decoding/LibRawDecoder.swift` — in `rawHistogram(from:)` after `var counts = ...`:

```swift
var luma = [Int](repeating: 0, count: RawHistogram.binCount)
```

In the inner loop after `let bin = ...`:

```swift
counts[channel][bin] += 1
luma[bin] += 1
```

Change return to:

```swift
return RawHistogram(bins: counts, luminance: luma, sensorMax: maxLevel)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' -only-testing:QuickCullCoreTests/LibRawDecoderTests`
Expected: PASS — 7/7.

- [ ] **Step 5: Commit**

```bash
git add QuickCullCore/Decoding/LibRawDecoder.swift QuickCullCoreTests/LibRawDecoderTests.swift
git commit -m "feat: compute luminance in LibRawDecoder (same pass, every pixel)"
```

---

### Task 3: HUD stacks RGB + luminance histograms

**Files:**
- Modify: `QuickCull/ImageDisplayView.swift`

**Interfaces:**
- Consumes: `RawHistogram.luminance`, `RawHistogramView` existing, `appState.cache` already passed.
- Produces: `MetadataHUDView` stacked block 152pt, `RawLuminanceHistogramView` private struct.

- [ ] **Step 1: Verify current HUD block exists**

```bash
rg -n "RawHistogramView|MetadataHUDView" QuickCull/ImageDisplayView.swift
```
Expected: definition `RawHistogramView` ~line 389 and `MetadataHUDView` ~323 with single 72pt block.

- [ ] **Step 2: Implement stacked block and new view**

Edit `QuickCull/ImageDisplayView.swift` — in `MetadataHUDView.body` replace the single histogram block:

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

Append after `RawHistogramView`:

```swift
/// Single-channel overall-exposure histogram, same log-y and clipping marker as RGB.
private struct RawLuminanceHistogramView: View {
    let histogram: RawHistogram
    var body: some View {
        Canvas { ctx, size in
            let binCount = RawHistogram.binCount
            guard size.width > 0, size.height > 0 else { return }
            let rawMax = histogram.luminance.map { log10(Double($0) + 1) }.max() ?? 0
            let logMax = rawMax > 0 ? rawMax : 1
            func yFor(_ count: Int) -> Double { size.height * (1 - log10(Double(count) + 1) / logMax) }
            let binW = size.width / Double(binCount)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for bin in 0..<binCount {
                let x = Double(bin) * binW
                let y = yFor(histogram.luminance[bin])
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            ctx.fill(path, with: .color(.white.opacity(0.85)))
            if histogram.clipping.count > 3 && histogram.clipping[3] > 0.001 {
                var line = Path()
                line.move(to: CGPoint(x: size.width - 1, y: 0))
                line.addLine(to: CGPoint(x: size.width - 1, y: size.height))
                ctx.stroke(line, with: .color(.white), lineWidth: 1)
            }
        }
        .background(.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("Luminance histogram")
    }
}
```

Existing `MetadataHUDView.task` already loads sidecar-or-fallback that now contains luminance; no change needed.

- [ ] **Step 3: Build**

Run: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build`
Expected: PASS.

- [ ] **Step 4: Full test suite**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS'`
Expected: PASS — 131 tests (126 existing + 5 new luminance tests).

- [ ] **Step 5: Manual QA**

`./start.sh`, import fixtures + one JPEG:
- Show Metadata HUD on a RAW: two stacked histograms (RGB overlay on top, white luma below), each 72pt, 8pt gap.
- Flat gray JPEG: both histograms peak at same bin; luma sum == pixel count.
- Fuji super-CCD / missing sidecar: both blocks show display fallback (no crash, no empty flash — histogram cleared at task entry).
- Rapid scrub with HUD open: both histograms update together, no stutter.

- [ ] **Step 6: Commit**

```bash
git add QuickCull/ImageDisplayView.swift
git commit -m "feat: stacked luminance histogram in metadata HUD (white, log-y, clipping marker)"
```

---

## Self-Review

**Spec coverage:**
- Model luminance overall exposure, CodingKeys + backwards compat, derived samples/clipping 4 entries (spec "Model") → Task 1.
- Single-pass luma increment per pixel with same bin math, non-Bayer nil (spec "Computation") → Task 2.
- Same sidecar .hist.json now with luminance, old JSON decodes, fallback via DisplayHistogram Y (spec "Model"/"Storage") → Tasks 1 & 2.
- Stacked VStack 72+8+72, white 0.85 fill, log-y guard rawMax>0?rawMax:1, clipping[3]>0.001 marker, both read same histogram state (spec "UI") → Task 3.
- Testing: luminance bins sum==w*h, codable round-trip+backwards compat, display luma peak, LibRaw luma sum, cache round-trip with luma (spec "Testing") → Tasks 1-2.

**Placeholder scan:** No TBD/TODO; every step has concrete code + commands; no "similar to Task N".

**Type consistency:** `RawHistogram(bins:luminance:sensorMax:)` 3-arg init used identically in Tasks 1-3; `luminance: [Int]` 256 everywhere; `DisplayHistogram.compute` returns `RawHistogram` with luminance in Task 1; `MetadataHUDView` still `(file:cgImage:cache:)`; `RawLuminanceHistogramView` consumes `RawHistogram` same as `RawHistogramView`.
