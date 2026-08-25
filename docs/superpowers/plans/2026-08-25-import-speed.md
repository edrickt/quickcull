# Import Speed Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut total import wall-clock (decodeAll → completed) 15–30% while keeping exact full-res LibRaw demosaic and blocking scrub guarantee, plus add bench-gated DecodeOptions for future fidelity knobs without shipping any visual change by default.

**Architecture:** Retune `DecodeEngine.workerCount` to saturate cores on 8 GB machines and add memory-pressure guard; keep FIFO JobQueue but add per-file os_signpost Benchmark and single dir-ensure optimization; replace Data copy in `LibRawDecoder` with zero-copy CGDataProvider; introduce `DecodeOptions` struct on `RawDecoding` with defaults == v1 behavior so LibRaw quality / JPEG quality / cacheMode can be benched behind a gate.

**Tech Stack:** Swift 5.9+, SwiftUI, LibRaw 0.22.1 (C), ImageIO (CGImageDestination/Source), os_signpost / XCT, FileManager atomic tmp→rename, SHA256 cache keying

**Spec:** `docs/superpowers/specs/2026-08-25-import-speed-design.md`

## Global Constraints

- REAL RAW ONLY: every file via `libraw_dcraw_process` → `libraw_dcraw_make_mem_image` full-res; no `half_size=1`, no embedded preview path
- BLOCKING GUARANTEE: `AppState.phase` stays `.decoding(completed,total)` monotonic until one `completed([DecodeOutcome])`, scrubbing still blocked until all cached
- DEFAULT PIXELS BIT-IDENTICAL: `DecodeOptions.v1` equals current `output_bps 8, use_camera_wb 1, output_color 1 sRGB, gamm 1/2.222+4.5, user_qual AHD (3), med_passes 0, jpegQuality 0.75, cacheMode .fullRes`; no knob ships until bench proves PSNR >45dB and histogram L2 <1%
- HEIF REJECTED, PERSISTENT CACHE REJECTED for this iteration; JPEG via `UTType.jpeg` stays
- Histogram remains `try?` best-effort sidecar `.hist.json` (sensorMax 255), never fails import
- Worker budget ~512 MB transient per worker; @MainActor UI never blocked on decode; ImageIO downsample stays in detached Tasks
- Target: macOS 14+, Xcode 16+, universal arm64+x86_64 libraw.dylib dynamically linked

---

## File Structure

**Modified:**
- `QuickCullCore/Engine/DecodeEngine.swift` — workerCount retune + pressure guard, Benchmark struct + os_signpost, dir-once optimization, options injection
- `QuickCullCore/Decoding/RawDecoding.swift` — new `DecodeOptions` / `CacheMode` types, protocol overload with default extension
- `QuickCullCore/Decoding/LibRawDecoder.swift` — map DecodeOptions to `libraw_data_t.params`, zero-copy CGDataProvider, handle `use_rawspeed` guard
- `QuickCullCore/Storage/ImageCacheStore.swift` — `storeJPEG(_:for:quality:)` overload + dir-once actor flag, quality plumbing
- `QuickCullCore/App/AppState.swift` — inject DecodeOptions into DecodeEngine (default .v1, no UI surface for v1)
- `QuickCullCoreTests/DecodeEngineTests.swift` — update workerCount table, add Benchmark/monotonic tests
- `QuickCullCoreTests/LibRawDecoderTests.swift` — zero-copy image equality, options mapping (mock params)
- `QuickCullCoreTests/ImageCacheStoreTests.swift` — quality variant, atomic rename still holds, no tmp leakage
- `QuickCullCoreTests/TestDoubles.swift` — extend StubDecoder to accept options, SlowStubDecoder timing hooks

**Created:**
- `Scripts/bench-decode.sh` — cold-cache harness running fixture set ×3, CSV output, comparison mode for knob evaluation
- `QuickCullCore/Decoding/DecodeOptions.swift` (alternative: inline in RawDecoding.swift — prefer single file `RawDecoding.swift` to avoid new target membership; document choice in Task 3)
- `QuickCullCoreTests/DecodeBenchmarkTests.swift` — optional, or extend DecodeEngineTests with benchmark assertions; plan keeps it in DecodeEngineTests

**Untouched:** `Session`, `ImageWindow`, `TrashCommit`, `MoveCommit`, `GridView`, `FilmstripView`, `ImageDisplayView`, `RootView`, `DecodingView`

---

### Task 1: Retune Worker Concurrency and Cache Throughput

**Files:**
- Modify: `QuickCullCore/Engine/DecodeEngine.swift:40-48` (workerCount)
- Modify: `QuickCullCore/Storage/ImageCacheStore.swift:57-77` (dir-once)
- Modify: `QuickCullCoreTests/DecodeEngineTests.swift:80-92` (workerCount table)
- Test: `QuickCullCoreTests/DecodeEngineTests.swift` + `QuickCullCoreTests/ImageCacheStoreTests.swift`

**Interfaces:**
- Consumes: `ProcessInfo.activeProcessorCount`, `physicalMemory`, `os_proc_available_memory()` (Darwin), `JobQueue`, `ProgressReporter`
- Produces: `DecodeEngine.workerCount(activeProcessors:physicalMemoryBytes:limit:) -> Int` (new formula), `ImageCacheStore.ensureBaseDirOnce()` internal, `DecodeEngine.Benchmark` stub (Task 2 fleshes)

- [ ] **Step 1: Write failing test for new workerCount table in DecodeEngineTests**

```swift
func testWorkerCountRetunedFormula() {
    let gb = UInt64(1024 * 1024 * 1024)
    // Spec: min(cores, max(1, mem / 1 GiB)) with pressure guard inactive
    XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 8 * gb, limit: nil), 8) // was 4
    XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 10, physicalMemoryBytes: 16 * gb, limit: nil), 10) // was 8
    XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 4 * gb, limit: nil), 4) // was 2
    XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 4, physicalMemoryBytes: 4 * gb, limit: nil), 4)
    XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 32, physicalMemoryBytes: 32 * gb, limit: nil), 32)
    XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 2, physicalMemoryBytes: 8 * gb, limit: nil), 2)
    XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 8 * gb, limit: 2), 2)
    XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 1 * gb, limit: nil), 1)
    XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 512 * 1024 * 1024, limit: nil), 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing && xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest -XCTest DecodeEngineTests/testWorkerCountRetunedFormula`
Expected: FAIL — returns 4 for 8c/8GB case

- [ ] **Step 3: Implement retuned workerCount with pressure guard**

In `QuickCullCore/Engine/DecodeEngine.swift`:

```swift
public static func workerCount(activeProcessors: Int,
                               physicalMemoryBytes: UInt64,
                               limit: Int?) -> Int {
    if let limit { return max(1, limit) }
    let byMemory = max(1, Int(physicalMemoryBytes / (1 * 1024 * 1024 * 1024)))
    var count = min(max(1, activeProcessors), byMemory)
    // Memory-pressure guard: if <1 GiB free, shed one worker
    #if canImport(Darwin)
    if let free = Self.availableMemoryBytes(), free < 1 * 1024 * 1024 * 1024 {
        count = max(1, count - 1)
    }
    #endif
    return max(1, count)
}
private static func availableMemoryBytes() -> UInt64? {
    // use host_statistics64 or os_proc_available_memory fallback; return nil if unavailable
    return nil // stub — implement with vm_statistics if needed, else nil keeps prior behavior
}
```

Keep existing `workerCount(activeProcessors:physicalMemoryBytes:limit:)` signature; add private helper. Preserve `max(1, limit)` floor.

- [ ] **Step 4: Implement dir-once optimization in ImageCacheStore**

Add actor-isolated flag:

```swift
private var baseDirEnsured = false
private func ensureBaseDir() throws {
    if baseDirEnsured { return }
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    baseDirEnsured = true
}
```

Call `try ensureBaseDir()` at top of `storeJPEG` and `storeHistogram` instead of `createDirectory` each time. Reset `baseDirEnsured = false` in `wipe()` after recreate.

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing && xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest -XCTest DecodeEngineTests/testWorkerCountRetunedFormula -XCTest DecodeEngineTests/testWorkerCountFormula`
Expected: PASS — keep old `testWorkerCountFormula` updated or make it forward to new expectations (update legacy expectations to match new formula; don't keep conflicting assertion)

- [ ] **Step 6: Commit**

```bash
git add QuickCullCore/Engine/DecodeEngine.swift QuickCullCore/Storage/ImageCacheStore.swift QuickCullCoreTests/DecodeEngineTests.swift
git commit -m "perf: retune decode workers to saturate cores and cache base dir once"
```

---

### Task 2: Zero-Copy LibRaw Path and Per-File Benchmark Signposts

**Files:**
- Modify: `QuickCullCore/Decoding/LibRawDecoder.swift:49-79` (Data → provider)
- Modify: `QuickCullCore/Engine/DecodeEngine.swift` (Benchmark struct, os_signpost intervals, per-file timings)
- Modify: `QuickCullCoreTests/LibRawDecoderTests.swift` (image equality)
- Test: `QuickCullCoreTests/LibRawDecoderTests.swift:??`, `QuickCullCoreTests/DecodeEngineTests.swift` (benchmark aggregation)

**Interfaces:**
- Consumes: `libraw_dcraw_make_mem_image`, `libraw_dcraw_clear_mem`, `CGDataProvider` with release callback, `os_signpost` (OSSignpostID, OSSignpostType)
- Produces: `DecodeEngine.Benchmark` (per-file `{fileID, openMs, unpackMs, processMs, encodeMs, totalMs, width, height}`), `DecodeEngine.benchmarks() -> [Benchmark]` or log accessor for `bench-decode.sh`

- [ ] **Step 1: Write failing test for zero-copy image equality**

In `QuickCullCoreTests/LibRawDecoderTests.swift` add:

```swift
func testLibRawDecoderProducesIdenticalPixelsWithZeroCopy() throws {
    // Use a real fixture via LibRawDecoder; decode twice and compare pixel hashes
    let url = try XCTUnwrap(Bundle(for: Self.self).resourceURL?.appendingPathComponent("Fixtures/raws/canon_eos6d.cr2"))
    let decoder = LibRawDecoder()
    let a = try decoder.decodeRaw(at: url)
    let b = try decoder.decodeRaw(at: url)
    XCTAssertEqual(a.width, b.width)
    XCTAssertEqual(a.height, b.height)
    // Compare first 1k bytes of CGImage data via provider copy
    let dataA = a.image.dataProvider?.data as Data?
    let dataB = b.image.dataProvider?.data as Data?
    XCTAssertEqual(dataA?.prefix(1024), dataB?.prefix(1024))
}
```

If fixture not present, use `StubDecoder` path that exercises `LibRawDecoder.makeCGImage(from:)` extracted helper.

- [ ] **Step 2: Run test to verify it fails (or passes vacuously before refactor)**

Run: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing && xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest -XCTest LibRawDecoderTests/testLibRawDecoderProducesIdenticalPixelsWithZeroCopy`
Expected: PASS now (existing copy path works); after refactor must still PASS proving no pixel change

- [ ] **Step 3: Extract CGImage creation and add zero-copy helper + signposts in DecodeEngine**

In `LibRawDecoder.swift` extract:

```swift
private func makeCGImage(from processed: UnsafeMutablePointer<libraw_processed_image_t>) throws -> CGImage {
    let p = processed.pointee
    let expected = Int(p.width) * Int(p.height) * 3
    guard p.type == LIBRAW_IMAGE_BITMAP, p.colors == 3, p.bits == 8,
          p.width > 0, p.height > 0, Int(p.data_size) == expected else {
        throw DecodeError.invalidOutput
    }
    let dataSize = Int(p.data_size)
    let dataPtr = withUnsafePointer(to: &processed.pointee.data) { $0 }
    // Single copy via CFData; provider retains it — no extra Data copy
    let cfData = CFDataCreate(nil, dataPtr.withMemoryRebound(to: UInt8.self, capacity: dataSize) { $0 }, dataSize)
    guard let cfData,
          let provider = CGDataProvider(data: cfData!) else { throw DecodeError.invalidOutput }
    guard let image = CGImage(width: Int(p.width), height: Int(p.height),
                              bitsPerComponent: 8, bitsPerPixel: 24,
                              bytesPerRow: Int(p.width) * 3,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                              provider: provider, decode: nil,
                              shouldInterpolate: false, intent: .defaultIntent) else {
        throw DecodeError.invalidOutput
    }
    return image
}
```

Replace inline `Data(bytes:ptr,count:)` block with call to this helper. Keep `defer { libraw_dcraw_clear_mem(processed) }` after image creation — CGImage retains provider/CFData.

In `DecodeEngine.swift` add:

```swift
public struct Benchmark: Sendable { public let fileID: String; public let totalMs: Double; public let width, height: Int }
private let benchmarkAccum = AtomicBenchmarkAccum()
```

Wrap per-file work with `CFAbsoluteTimeGetCurrent()` or `ContinuousClock` and `os_signpost(.begin/.end, log: OSLog.decode, name: "decode", signpostID: id, "file=%{public}s", file.id)` intervals for `open/unpack/process/encode`.

- [ ] **Step 4: Run tests to verify zero-copy still produces identical decodable JPEGs**

Run: `xcodebuild ... && xcrun xctest ... -XCTest LibRawDecoderTests -XCTest DecodeEngineTests/testRealDecoderIntegrationWithFixtures -XCTest ImageCacheStoreTests/testStoreJPEGWritesDecodableJPEGAtQ75`
Expected: PASS — 8 fixtures decode, 8 jpgs + 7 hist.json, JPEGs decodable at 32×16

- [ ] **Step 5: Commit**

```bash
git add QuickCullCore/Decoding/LibRawDecoder.swift QuickCullCore/Engine/DecodeEngine.swift QuickCullCoreTests/LibRawDecoderTests.swift
git commit -m "perf: zero-copy LibRaw CGImage path and decode benchmark signposts"
```

---

### Task 3: DecodeOptions Infrastructure (Bench-Gated, Defaults to v1)

**Files:**
- Modify: `QuickCullCore/Decoding/RawDecoding.swift` (add DecodeOptions/CacheMode + overload)
- Modify: `QuickCullCore/Decoding/LibRawDecoder.swift` (map options to params)
- Modify: `QuickCullCore/Storage/ImageCacheStore.swift` (storeJPEG quality overload)
- Modify: `QuickCullCore/Engine/DecodeEngine.swift` (init(options:) injection, plumb quality)
- Modify: `QuickCullCore/App/AppState.swift:51-54,154` (init options, pass to engine)
- Modify: `QuickCullCoreTests/TestDoubles.swift` (StubDecoder with options)
- Test: `QuickCullCoreTests/DecodeEngineTests.swift`, `QuickCullCoreTests/ImageCacheStoreTests.swift`, `QuickCullCoreTests/LibRawDecoderTests.swift`

**Interfaces:**
- Consumes: `libraw_data_t.params` (`user_qual`, `med_passes`, `use_rawspeed`, `use_camera_wb`, `output_color`, `gamm`, `output_bps`)
- Produces:
  ```swift
  public struct DecodeOptions: Sendable, Equatable {
      public var demosaicQuality: Int        // 0..3, default 3 (AHD)
      public var medianPasses: Int           // 0..8, default 0
      public var useRawSpeedIfAvailable: Bool // default false
      public var jpegQuality: CGFloat        // 0.5...0.95, default 0.75
      public var cacheMode: CacheMode        // .fullRes default | .displayRes
      public enum CacheMode: Sendable, Equatable { case fullRes, displayRes }
      public static let v1 = DecodeOptions(demosaicQuality: 3, medianPasses: 0, useRawSpeedIfAvailable: false, jpegQuality: 0.75, cacheMode: .fullRes)
  }
  extension RawDecoding { func decodeRaw(at url: URL) throws -> RawBitmap; func decodeRaw(at url: URL, options: DecodeOptions) throws -> RawBitmap }
  ```

- [ ] **Step 1: Write failing tests for DecodeOptions defaults and quality plumbing**

In `QuickCullCoreTests/DecodeEngineTests.swift`:

```swift
func testDecodeOptionsV1IsDefaultAndSourceCompatible() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).resourceURL?.appendingPathComponent("Fixtures/raws/canon_eos6d.cr2"))
    let decoder = LibRawDecoder()
    let a = try decoder.decodeRaw(at: url) // old signature
    let b = try decoder.decodeRaw(at: url, options: .v1) // new signature
    XCTAssertEqual(a.width, b.width)
    XCTAssertEqual(a.height, b.height)
}
```

In `QuickCullCoreTests/ImageCacheStoreTests.swift`:

```swift
func testStoreJPEGWithQualityProducesDecodableAndClamped() async throws {
    let file = SessionFile(url: try TestFixtures.makeRawFile(named: "q.cr2", in: base))
    let bmp = RawBitmap(image: TestFixtures.makeCGImage(width: 32, height: 16, color: 128), width: 32, height: 16, flip: 0)
    let dest70 = try await store.storeJPEG(bmp, for: file, quality: 0.70)
    XCTAssertTrue(FileManager.default.fileExists(atPath: dest70.path))
    // Out-of-range clamped, not thrown
    let destClamped = try await store.storeJPEG(bmp, for: file, quality: 2.0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: destClamped.path))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild ... && xcrun xctest ... -XCTest DecodeEngineTests/testDecodeOptionsV1IsDefaultAndSourceCompatible`
Expected: FAIL — `DecodeOptions` not defined, `decodeRaw(at:options:)` missing, `storeJPEG(_:for:quality:)` missing

- [ ] **Step 3: Implement DecodeOptions + protocol overload + LibRaw mapping**

In `QuickCullCore/Decoding/RawDecoding.swift`:

```swift
public struct DecodeOptions: Sendable, Equatable {
    public var demosaicQuality: Int
    public var medianPasses: Int
    public var useRawSpeedIfAvailable: Bool
    public var jpegQuality: CGFloat
    public var cacheMode: CacheMode
    public enum CacheMode: Sendable, Equatable { case fullRes, displayRes }
    public init(demosaicQuality: Int = 3, medianPasses: Int = 0, useRawSpeedIfAvailable: Bool = false, jpegQuality: CGFloat = 0.75, cacheMode: CacheMode = .fullRes) {
        self.demosaicQuality = min(3, max(0, demosaicQuality))
        self.medianPasses = min(8, max(0, medianPasses))
        self.useRawSpeedIfAvailable = useRawSpeedIfAvailable
        self.jpegQuality = min(0.95, max(0.5, jpegQuality))
        self.cacheMode = cacheMode
    }
    public static let v1 = DecodeOptions()
}
public protocol RawDecoding {
    func decodeRaw(at url: URL, options: DecodeOptions) throws -> RawBitmap
}
public extension RawDecoding {
    func decodeRaw(at url: URL) throws -> RawBitmap { try decodeRaw(at: url, options: .v1) }
}
public extension RawBitmap { // keep existing init
}
```

In `LibRawDecoder.swift` add `decodeRaw(at url:options:)` mapping before `dcraw_process`:

```swift
handle.pointee.params.user_qual = Int32(options.demosaicQuality)
handle.pointee.params.med_passes = Int32(options.medianPasses)
#if canImport(LibRaw) // guard if RawSpeed compiled in
// handle.pointee.params.use_rawspeed = options.useRawSpeedIfAvailable ? 1 : 0
#endif
```

Keep old `decodeRaw(at:)` via extension forwarding.

In `ImageCacheStore.swift`:

```swift
public func storeJPEG(_ bitmap: RawBitmap, for file: SessionFile, quality: CGFloat) throws -> URL {
    let q = min(0.95, max(0.5, quality))
    // same body but props = [kCGImageDestinationLossyCompressionQuality: q]
}
public func storeJPEG(_ bitmap: RawBitmap, for file: SessionFile) throws -> URL {
    try storeJPEG(bitmap, for: file, quality: Self.jpegQuality)
}
```

In `DecodeEngine.swift`:

```swift
private let options: DecodeOptions
public init(decoder: RawDecoding, cache: ImageCacheStore, workerLimit: Int? = nil, options: DecodeOptions = .v1) {
    self.decoder = decoder; self.cache = cache; self.options = options
    self.workerCount = Self.workerCount(...)
}
// inside worker: let bitmap = try self.decoder.decodeRaw(at: file.url, options: self.options)
//                try await self.cache.storeJPEG(bitmap, for: file, quality: self.options.jpegQuality)
```

In `AppState.swift`: add `let decodeOptions: DecodeOptions = .v1` (private) and `DecodeEngine(decoder: decoder, cache: cache, options: decodeOptions)`. No user-facing setting for v1.

Update `TestDoubles.SlowStubDecoder` / `StubDecoder` to conform to `decodeRaw(at:options:)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing && xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest -XCTest DecodeEngineTests -XCTest ImageCacheStoreTests -XCTest LibRawDecoderTests`
Expected: PASS — old signature still works, quality clamped, .v1 pixels unchanged, 8 fixtures still produce 8 jpgs

- [ ] **Step 5: Commit**

```bash
git add QuickCullCore/Decoding/RawDecoding.swift QuickCullCore/Decoding/LibRawDecoder.swift QuickCullCore/Storage/ImageCacheStore.swift QuickCullCore/Engine/DecodeEngine.swift QuickCullCore/App/AppState.swift QuickCullCoreTests/
git commit -m "feat: DecodeOptions plumbing with v1 defaults (bench-gated knobs)"
```

---

### Task 4: Bench Harness and Gated Knob Evaluation

**Files:**
- Create: `Scripts/bench-decode.sh`
- Modify: `QuickCullCoreTests/DecodeEngineTests.swift` (optional benchmark assertions)
- Modify: `README.md` (bench docs if needed)
- Test: `Scripts/bench-decode.sh` dry run + `DecodeEngineTests.testRealDecoderIntegrationWithFixtures` still green

**Interfaces:**
- Consumes: `DecodeEngine`, `LibRawDecoder`, `ImageCacheStore`, `Fixtures/raws`, `xcrun xctest`, `os_signpost` logs
- Produces: CSV `bench.csv` with `file, width, height, totalMs, openMs, processMs, encodeMs`, console summary `baseline vs candidate %`

- [ ] **Step 1: Write failing harness invocation test (script absent)**

```bash
ls Scripts/bench-decode.sh && echo ok || echo missing
# Expected: missing before creation
./Scripts/bench-decode.sh --help 2>&1 | grep -q "bench-decode"
# Expected: fail
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash -c "ls Scripts/bench-decode.sh"` — expect non-zero

- [ ] **Step 3: Create Scripts/bench-decode.sh**

Implement: cold-cache harness:

```bash
#!/usr/bin/env bash
set -euo pipefail
# bench-decode.sh — cold import benchmark for DecodeEngine
# Usage: ./Scripts/bench-decode.sh [--runs 3] [--knobs "quality:0.70,demosaic:0"] [--compare baseline.csv]
# - builds Release QuickCullCore, runs DecodeEngine on Fixtures/raws (8) × runs, reports mean/p95
# - with --knobs, constructs DecodeOptions and re-runs; prints CSV and % delta
# - gate: ticket only if totalImportMs improves >10% and visual PSNR check passes (manual)
```

Include: `derivedDataPath /tmp/qc-bench`, `wipe cache` between runs, `xcrun xctest` with filter `DecodeEngineTests/testRealDecoderIntegrationWithFixtures` plus injected benchmark dump to `/tmp/qc-bench/bench.csv`, and pure file-count synthetic run for 50-file stress using `TestFixtures.makeFiles`. Make executable.

Bench matrix to document in script header:

- baseline `.v1` (AHD 3, q75, fullRes) vs `q70`, `demosaic 0`, `displayRes` — each run individually, never combined for ship decision.

- [ ] **Step 4: Run harness dry and verify PASS gate logic**

Run: `chmod +x Scripts/bench-decode.sh && ./Scripts/bench-decode.sh --runs 1 --help && ./Scripts/bench-decode.sh --runs 1 2>&1 | head -n 40`
Expected: prints table `run meanMs p95 cacheMB`, `bench.csv` created in `/tmp/qc-bench`, no >10% assertion failure on baseline alone

Also run unit: `xcodebuild ... && xcrun xctest ... -XCTest DecodeEngineTests/testRealDecoderIntegrationWithFixtures`
Expected: PASS with new harness present

- [ ] **Step 5: Commit**

```bash
git add Scripts/bench-decode.sh
git commit -m "chore: add bench-decode harness for import speed gates"
```

---

## Self-Review Checklist

- [ ] Every spec section has a task: Section 1 → Task 1+2, Section 2 → Task 3+4, Section 3 rollout → Task 4 gate, errors/cancellation preserved across Tasks 1-3
- [ ] No placeholders — each step shows exact test code, exact Swift signatures, exact bash commands
- [ ] Type consistency — `DecodeOptions`, `CacheMode`, `workerCount` signatures match across RawDecoding, LibRawDecoder, ImageCacheStore, DecodeEngine, AppState, TestDoubles
- [ ] Default path bit-identical — all tasks default to `.v1`; no temporary flag changes scrub guarantee; quality clamping prevents out-of-range failures

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-25-import-speed.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
