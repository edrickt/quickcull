# Rendered (Lightroom-matched) Histogram — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace linear sensor histogram with rendered sRGB 8-bit histogram (post-demosaic, post-WB, post-gamma) so HUD histograms visually match Lightroom/Capture One.

**Architecture:** Delete Bayer `raw_image` loop in `LibRawDecoder`; add `renderedHistogram(from: UnsafeMutablePointer<libraw_processed_image_t>)` that histograms the `mem_image` RGB buffer (`w*h*3` bytes, `sensorMax 255`, weighted Rec.709 `Y`). Compute after `libraw_dcraw_make_mem_image` so X-Trans/super-CCD now also have histograms. No storage/UI API changes; same `.hist.json` sidecar, same `RawHistogramView`/`RawLuminanceHistogramView`.

**Tech Stack:** Swift 5.10+, LibRaw C API (`libraw_processed_image_t`), SwiftUI Canvas, JSON Codable, xcodebuild

## Global Constraints

* Spec: `docs/superpowers/specs/2026-08-18-rendered-histogram-design.md` (amends 2026-08-18-raw-histogram-design.md + luminance).
* `RawHistogram` shape unchanged: `bins [[Int]] 3×256`, `luminance [Int] 256`, `sensorMax Int` (now always 255), derived `samples`/`clipping` 4 entries, `Codable` with `decodeIfPresent luminance` backwards compat.
* Computation: `LibRawDecoder.renderedHistogram(from: libraw_processed_image_t)` iterates `p.pointee.data_size` (`w*h*3`) via `&p.pointee.data` rebound to `UInt8`, counts `bins[0][r]`, `bins[1][g]`, `bins[2][b]`, `Y = Int((0.2126*R+0.7152*G+0.0722*B).rounded())` clamped `0...255` → `luma[Y]++`, returns `RawHistogram(bins:luminance:sensorMax:255)`. Compute AFTER `libraw_dcraw_make_mem_image` succeeds, BEFORE `CGImage` creation, while `processed` is live. Delete old `rawHistogram(from handle)` and `filters==9||1` nil guard (now all have histogram).
* Storage: same `<cacheKey>.hist.json`, atomic tmp+replace, `loadHistogram` nil on missing/corrupt, `DecodeEngine` best-effort `try? storeHistogram`.
* UI: `MetadataHUDView` stacked `VStack(spacing:8){ RawHistogramView 72pt; RawLuminanceHistogramView 72pt }` unchanged, log-y `log10(1+count)/logMax` guard `logMax>0?logMax:1`, clipping `>0.001` at `bin 255`.
* Build: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build` must pass. Tests: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS'` must pass (≈131 tests).
* No new targets; `ScrubView`, `Session`, `ImageWindow`, `FilmstripView`, `GridView` unchanged.

---

## File Structure

* **Modify:** `QuickCullCore/Metadata/RawHistogram.swift` — update doc comment to rendered semantics (1 line).
* **Modify:** `QuickCullCore/Decoding/LibRawDecoder.swift` — delete `rawHistogram(from handle)` (lines 81-112), add `renderedHistogram(from processed)`, move call site to after `make_mem_image`.
* **Modify:** `QuickCullCoreTests/LibRawDecoderTests.swift` — update `testHistogramComputedForRawFixtures` expectations to rendered (`sensorMax==255`, `samples per channel == w*h`, `luma sum == w*h`, include `fuji_e550` as non-nil), replace `testLuminanceNilForSuperCCDAndXTrans` with non-nil assertion.
* **No change (verification only):** `QuickCullCore/Storage/ImageCacheStore.swift`, `QuickCullCore/Engine/DecodeEngine.swift`, `QuickCull/ImageDisplayView.swift`, `QuickCullCoreTests/RawHistogramTests.swift`, `QuickCullCoreTests/ImageCacheStoreTests.swift`, `QuickCullCoreTests/DecodeEngineTests.swift`.

---

### Task 1: Rendered histogram computation in LibRawDecoder

**Files:**
* Modify: `QuickCullCore/Metadata/RawHistogram.swift:1-5` (doc comment)
* Modify: `QuickCullCore/Decoding/LibRawDecoder.swift:10-40` (decodeRaw method) + `81-113` (histogram helper)
* Test: `QuickCullCoreTests/LibRawDecoderTests.swift:71-110`

**Interfaces:**
* Consumes: `libraw_processed_image_t.pointee.data` (`UInt8` flexible array), `p.pointee.data_size`, `p.pointee.width/height`, `RawHistogram(bins:luminance:sensorMax:)`
* Produces: `RawBitmap.histogram: RawHistogram?` now always non-nil for successful decode (including X-Trans/super-CCD), `sensorMax==255`, `samples == w*h` per channel, `luminance` weighted Rec.709.

- [ ] **Step 1: Write the failing tests (update expectations to rendered)**

Edit `QuickCullCoreTests/LibRawDecoderTests.swift` — replace existing histogram tests with rendered expectations:

```swift
func testHistogramComputedForRawFixtures() throws {
    let cases: [(name: String, ext: String)] = [
        ("img_0062", "cr2"), ("mg_2233", "cr3"), ("dsc8140", "nef"), ("dsc0258", "arw"),
        ("fuji_e550", "raf"), ("olympus_c5050z", "orf"), ("p1000336", "rw2"), ("pentax_k01", "dng"),
    ]
    for c in cases {
        let bitmap = try decoder.decodeRaw(at: fixture(c.name, c.ext))
        let hist = try XCTUnwrap(bitmap.histogram, "\(c.name).\(c.ext) should have a rendered histogram")
        XCTAssertEqual(hist.bins.count, 3, c.name)
        XCTAssertTrue(hist.bins.allSatisfy { $0.count == RawHistogram.binCount }, c.name)
        XCTAssertEqual(hist.sensorMax, 255, c.name)
        XCTAssertEqual(hist.luminance.count, RawHistogram.binCount, c.name)
        XCTAssertEqual(hist.samples[0], bitmap.width * bitmap.height, "\(c.name) R count")
        XCTAssertEqual(hist.samples[1], bitmap.width * bitmap.height, "\(c.name) G count")
        XCTAssertEqual(hist.samples[2], bitmap.width * bitmap.height, "\(c.name) B count")
        XCTAssertEqual(hist.samples[3], bitmap.width * bitmap.height, "\(c.name) luma count")
        XCTAssertEqual(hist.luminance.reduce(0,+), bitmap.width * bitmap.height, "\(c.name) luma sum")
        // No bin negative, clipping in 0...1
        XCTAssertTrue(hist.clipping.allSatisfy{ $0 >= 0 && $0 <= 1 }, c.name)
    }
}

func testLuminanceComputedForBayerFixtures() throws {
    let cases: [(name: String, ext: String)] = [("img_0062","cr2"),("dsc8140","nef"),("p1000336","rw2")]
    for c in cases {
        let bitmap = try decoder.decodeRaw(at: fixture(c.name, c.ext))
        let hist = try XCTUnwrap(bitmap.histogram, "\(c.name)")
        XCTAssertEqual(hist.luminance.count, RawHistogram.binCount, c.name)
        XCTAssertEqual(hist.luminance.reduce(0,+), bitmap.width * bitmap.height, "\(c.name) luma sum == pixel count")
        XCTAssertEqual(hist.samples[3], bitmap.width * bitmap.height, c.name)
        XCTAssertEqual(hist.sensorMax, 255, c.name)
    }
}

func testSuperCCDAndXTransNowHaveHistogram() throws {
    let fuji = try decoder.decodeRaw(at: fixture("fuji_e550","raf"))
    let hist = try XCTUnwrap(fuji.histogram, "super-CCD should now have rendered histogram")
    XCTAssertEqual(hist.sensorMax, 255)
    XCTAssertEqual(hist.samples[0], fuji.width * fuji.height)
    XCTAssertEqual(hist.luminance.count, RawHistogram.binCount)
}
```

Delete old `if c.name == "fuji_e550" { XCTAssertNil ... continue }` branch and `testLuminanceNilForSuperCCDAndXTrans`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' -only-testing:QuickCullCoreTests/LibRawDecoderTests 2>&1 | tail -40`
Expected: FAIL — `XCTAssertEqual hist.sensorMax == 255` fails (actual `16383`), `XCTAssertEqual samples[0]==w*h` fails (actual `w*h/4` per channel due to Bayer), `XCTAssertNotNil fuji.histogram` fails (nil).

- [ ] **Step 3: Update RawHistogram doc comment**

Edit `QuickCullCore/Metadata/RawHistogram.swift:4-5`:

```swift
/// Rendered sRGB histogram (8-bit post-demosaic, post-WB, post-gamma) plus
/// weighted luminance (Rec.709 Y). sensorMax is 255 for rendered histograms.
```

- [ ] **Step 4: Implement rendered histogram in LibRawDecoder**

Edit `QuickCullCore/Decoding/LibRawDecoder.swift`:

a) In `decodeRaw(at:)` remove `let histogram = Self.rawHistogram(from: handle)` at line 26 (pre-process). Keep `handle.pointee.params` setup and `libraw_dcraw_process`/`libraw_dcraw_make_mem_image` as-is.

b) After `guard let processed = libraw_dcraw_make_mem_image(handle, &memError) else ...` and `defer { libraw_dcraw_clear_mem(processed) }` and after `let p = processed.pointee`, insert before `Data` creation:

```swift
let histogram = Self.renderedHistogram(from: processed)
```

c) Replace return's `histogram:` to use this `histogram`.

d) Delete old `private static func rawHistogram(from handle: UnsafeMutablePointer<libraw_data_t>) -> RawHistogram?` (lines 81-112, including `raw_image`, `filters`, `rawW/rawH`, `left/top`, `iwidth/iheight`, `fcol`, `counts`/`luma` linear loop, `maxLevel = color.maximum`).

e) Add new helper inside `LibRawDecoder`:

```swift
private static func renderedHistogram(from p: UnsafeMutablePointer<libraw_processed_image_t>) -> RawHistogram {
    var bins = [[Int]](repeating: [Int](repeating: 0, count: RawHistogram.binCount), count: 3)
    var luma = [Int](repeating: 0, count: RawHistogram.binCount)
    let total = Int(p.pointee.data_size)
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

Ensure `withUnsafePointer(to: &p.pointee.data)` is valid — `data` is `UInt8` scalar flexible array; this matches existing `Data(bytes: ptr, ...)` pattern at line 59.

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' -only-testing:QuickCullCoreTests/LibRawDecoderTests 2>&1 | tail -20`
Expected: PASS — 7/7 (4 decode + 3 histogram). No failures.

- [ ] **Step 6: Commit**

```bash
git add QuickCullCore/Metadata/RawHistogram.swift QuickCullCore/Decoding/LibRawDecoder.swift QuickCullCoreTests/LibRawDecoderTests.swift
git commit -m "feat: rendered sRGB histogram post-demosaic (Lightroom-matched, 255, weighted luma)"
```

---

### Task 2: Full suite verification and build

**Files:**
* Verify: `QuickCullCoreTests/RawHistogramTests.swift`, `QuickCullCoreTests/ImageCacheStoreTests.swift`, `QuickCullCoreTests/DecodeEngineTests.swift`
* Build: `QuickCull.xcodeproj`

**Interfaces:**
* Consumes: `RawHistogram` with `sensorMax 255`, `ImageCacheStore`, `DecodeEngine`, `DisplayHistogram`
* Produces: Green build + 0 test failures.

- [ ] **Step 1: Run full QuickCullCore test suite**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' 2>&1 | grep -E "(PASS|FAIL|Executed|error:)" | tail -30`
Expected: PASS — ~131 tests, 0 failures. Specifically:
* `RawHistogramTests/testDisplayHistogramOfFlatGray` still passes (bins[128]==512, sensorMax 255).
* `ImageCacheStoreTests/testStoreAndLoadHistogramWithLuminance` passes (luma round-trip).
* `DecodeEngineTests/testRealDecoderIntegrationWithFixtures` still asserts `8 jpg + 8 hist.json` (now all 8 have histogram including fuji).

- [ ] **Step 2: Build the app**

Run: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build 2>&1 | tail -20`
Expected: PASS (warnings pre-existing only).

- [ ] **Step 3: Manual QA (optional but recommended)**

Run: `./start.sh` → import fixture set `QuickCullCoreTests/Fixtures/raws/` + one `JPEG`:
* Show Metadata HUD on `img_0062.cr2`: two stacked histograms (RGB additive, white luma) each 72pt; shape matches Lightroom/Preview histogram for same file (X positions, clipping marker at right edge only when blown).
* `olympus_c5050z.orf` (previously clipped linear at far left) now shows highlight peak near `bin 255` with white marker.
* `fuji_e550.raf` (previously missing histogram) now shows both histograms.
* Flat gray JPEG 128 → both histograms peak at `bin 128`.
* Rapid scrub with HUD open: histograms update per file, no re-decode stutter.
* Cache dir `~/Library/Application Support/QuickCull/cache` contains `.hist.json` with `"sensorMax":255` and `"luminance"` array.

- [ ] **Step 4: Commit (if any doc/test touch-ups)**

```bash
git status
# if no changes, no commit needed; otherwise:
git add -A
git commit -m "test: verify rendered histogram full suite green"
```

Note: This task has no code changes expected; failures here indicate Task 1 incomplete — return to Task 1.

---

## Self-Review

**Spec coverage:**
* Model `RawHistogram` doc rendered, `sensorMax 255`, weighted luma — Task 1 Step 3.
* Computation rendered from `mem_image` `w*h*3` sRGB 8-bit, `Y` weighted, covers X-Trans/super-CCD — Task 1 Steps 4-5.
* Storage same sidecar, best-effort, wipe covers — Task 2 verification.
* UI stacked 72+8+72, log-y, clipping `>0.001` at 255 — unchanged, verified Task 2.
* Testing: per-channel `w*h`, luma `w*h`, `sensorMax 255`, super-CCD non-nil, flat grey 128, round-trip — Task 1 + Task 2.

**Placeholder scan:** No TBD/TODO; every step has concrete Swift code + exact `xcodebuild` commands; no "similar to Task N" without code.

**Type consistency:** `RawHistogram(bins:luminance:sensorMax:)` 3-arg init used in `renderedHistogram`; `sensorMax` `255` everywhere; `bins.count 3×256`, `luminance 256`; `renderedHistogram(from: UnsafeMutablePointer<libraw_processed_image_t>)` signature matches call site `Self.renderedHistogram(from: processed)`; `RawBitmap.histogram` optional unchanged; `XCTUnwrap` expectations align.

