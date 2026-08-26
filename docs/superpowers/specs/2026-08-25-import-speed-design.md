# Import Speed Optimization — Design Spec

Date: 2026-08-25
Status: approved design (pre-plan) — covers performance paths 1 + 3
Related: `2026-08-16-quickcull-design.md` (v1 pipeline), `DecodeEngine.swift`, `LibRawDecoder.swift`, `ImageCacheStore.swift`

## Purpose

Make total import wall-clock (`importFiles → DecodeEngine.decodeAll → cache → scrubbing`) measurably faster while keeping both invariants that define QuickCull:

1. **Real raw decoded image only** — every file is a full-resolution demosaic via `libraw_dcraw_process` → `libraw_dcraw_make_mem_image`; no embedded preview or half-size path is shipped.
2. **Decode-first guarantee preserved** — `AppState.phase == .decoding` blocks scrub until *every* file has a cached q75 JPEG. Phase 1 still emits monotonic `progress` then exactly one `completed([DecodeOutcome])`. We optimize time-to-completion, not time-to-first-pixel.

HEIF and persistent-cache wins are explicitly deferred (see Out of Scope).

## Product Decisions (validated 2026-08-25)

- Keep blocking model — option A. Progressive scrub (time-to-first-image) rejected for this iteration.
  **Superseded 2026-08-25** by `2026-08-25-progressive-scrub-design.md`: scrubbing now unlocks once 90 files
  are decoded (default; knob `decodeUnlockThreshold`), remaining files decode in the background, and
  undecoded files show the camera's embedded JPEG via `FastPreview` until the real decode replaces it.
- HEIF rejected: `ImageIO` HEVC encode is 2–4× slower than JPEG and 1.5–3× slower to decode for `ImageWindow`. File-size win does not offset CPU on modern SSDs.
- Persistent cache rejected for this iteration (biggest repeat-import win, but changes cache lifecycle, eviction, and stale-file UX). Revisit separately.
- Default pixels stay bit-identical until a fidelity knob is bench-proven lossless for culling (PSNR >45 dB, histogram L2 unchanged, blind A/B pass).

## Architecture

### 1. Concurrency & Pipeline Overlap — no pixel change (ship first)

**Current.** `DecodeEngine.workerCount(activeProcessors, physicalMemory, limit)` = `min(activeProcessors, max(1, physicalMemory / 2 GB))` capped by `limit ??`. On 8 GB / 8-core = 4 workers, half the cores idle. Each worker serially does `decodeRaw` (`libraw_open_file → libraw_unpack → rawHistogram → dcraw_process → make_mem_image → Data copy → CGImage`) → `cache.storeJPEG` (`CGImageDestinationCreateWithURL → Finalize → tmp→rename`) → `storeHistogram` (`try?`). `Data(bytes:ptr,count:)` copies ~135 MB for 45 MP. `createDirectory` + `attributesOfItem` per file hits FS hot path.

**After.**

- `workerCount` retuned to `min(activeProcessors, max(1, Int(physicalMemory / 1 GiB)))` with floor 1, plus memory-pressure guard: if `os_proc_available_memory()` reports < 1 GiB free, clamp to `max(1, byMemory - 1)`. Keeps the `~512 MB transient per worker` budget but saturates cores on 8 GB machines (4 → 8 workers, 16 GB /10-core 8→10). `init(workerLimit:)` injectable limit stays floor-1 for tests and low-RAM fallback.
- Keep one FIFO `JobQueue` and `withTaskGroup`-of-workers for v1. No separate I/O pool until bench proves `storeJPEG` FS flush is the bottleneck; measure first. Unblock workers by `await cache.storeJPEG` off the worker's critical path only if signposts show queued workers stalled on `Finalize`.
- Zero-copy path in `LibRawDecoder`: replace `Data(bytes:ptr,count:)` + `CGDataProvider(data:)` (2 copies) with single `CFDataCreate` wired to `CGDataProvider(dataInfo:size:releaseData:)` or documented `Data(bytesNoCopy:)` with `deallocator:.free` where safe. Must still `libraw_dcraw_clear_mem` after CGImage retains provider. Benchmark copy ms saved.
- FS hot-path: `ImageCacheStore` ensures `baseURL` dir once per `decodeAll` (actor-isolated flag), pre-hashes cache key without per-file `attributesOfItem` when size/mtime unavailable (already falls back), and reuses `cacheURL` for JPEG + histogram sidecar. Atomic tmp→rename retained.
- Telemetry: `DecodeEngine.Benchmark` per file `{ openMs, unpackMs, processMs, encodeMs, totalMs, width, height }` via `os_signpost` intervals (`.begin/.end`) and aggregated `totalImportMs, meanMsPerFile, p95`. New `Scripts/bench-decode.sh` runs fixtures (`QuickCullCoreTests/Fixtures/raws`) ×3, cold cache, reports CSV and asserts >10% win vs baseline on same machine.

**Invariants preserved.** `ProgressReporter` still serializes `completed` increments in actor; `AtomicOutcomeAccumulator` still NSLock-based snapshot; cancellation still cooperative at `JobQueue.dequeue` check.

### 2. Tunable Fidelity Knobs — bench-gated (ship only when proven)

**Constraint.** Still full-res demosaic. `half_size` must stay 0, no embedded-thumb path.

**New surface.** `QuickCullCore/Decoding/RawDecoding.swift`:

```swift
public struct DecodeOptions: Sendable, Equatable {
    public var demosaicQuality: Int        // libraw params.user_qual (0 Bilinear, 1 VNG, 2 PPG, 3 AHD default)
    public var medianPasses: Int           // params.med_passes (0..8, default 0)
    public var useRawSpeedIfAvailable: Bool
    public var jpegQuality: CGFloat        // 0.5...0.95, default ImageCacheStore.jpegQuality (0.75)
    public var cacheMode: CacheMode        // .fullRes (default) | .displayRes
    public enum CacheMode: Sendable, Equatable { case fullRes, displayRes }
    public static let v1 = DecodeOptions() // current behavior
}
public protocol RawDecoding {
    func decodeRaw(at url: URL, options: DecodeOptions) throws -> RawBitmap
    // default extension: decodeRaw(at:) → decodeRaw(at:options:.v1) for source compat
}
```

`LibRawDecoder` maps `DecodeOptions` to `handle.pointee.params.{user_qual, med_passes, use_rawspeed}` (guard `LIBRAW_VERSION` macro). `ImageCacheStore.storeJPEG(_:for:quality:)` gains `quality` param; `DecodeEngine` injects `DecodeOptions` at init, defaults to `.v1`.

**Knobs to bench (one at a time):**

- `med_passes 0→0` is already default (fast); confirm any regression if vendor changes default. Do not ship `>0` without +PSNR lock.
- `user_qual 3 (AHD) vs 0 (Bilinear)` — bilinear is ~25–35% faster `dcraw_process` but PSNR drop 32–38 dB on edges; benchmark and blind A/B before shipping. Default stays AHD.
- `use_rawspeed` where LibRaw built with RawSpeed — open/unpack speed only, no pixel delta; safe if compile-time flag present.
- `jpegQuality 0.75 → 0.70` — encode ~8–12% faster, cache ~15% smaller; visual threshold for 2×screen scrub needs blind pass.
- `cacheMode .displayRes` — encode already-downsampled image to `ImageWindow.displayPixelLimit()` (6–8 MP) instead of full 45 MP: saves 60–70% encode + disk + later thumbnail decode, but loses archival full-res cache. Keep `.fullRes` default; `.displayRes` only behind a hidden `defaults write` / debug menu with explicit "culling cache only" label.

**Gate.** No knob ships until `Scripts/bench-decode.sh --compare baseline --knobs <set>` shows total win >10% and visual check passes (`PSNR >45 dB`, `RawHistogram` L2 < 1%, manual `./start.sh` 50-RAW scrub at 100% loupe identical). Tests assert defaults still produce current histogram bins (`sensorMax 255`).

### 3. Errors, Lifecycle & Rollout

- Phases unchanged: import → `.decoding` → `finishDecoding(files: session.files)` → `installWindows` → `.scrubbing`. `AppState.importFiles` still dedupes by `standardizedFileURL`, filters `isSupported`, creates `Session(files:)`, and removes failed files only. No progressive window.
- Error handling: per-file `DecodeError` captured; one failure never aborts queue. `storeHistogram` remains `try?` best-effort (failure never fails import). New `DecodeOptions` values clamped; invalid `jpegQuality` outside 0.5…0.95 clamps to nearest; unknown `user_qual` clamps to AHD.
- Cancellation: workers check `Task.isCancelled` at dequeue; `AsyncStream.onTermination` cancels group. No new cancellation points needed.
- Backward compat: protocol extension keeps `decodeRaw(at:)` source-compatible; tests inject `DecodeOptions.v1`.
- Rollout: land concurrency change alone (Section 1) behind no flag — it is a throughput fix, pixels unchanged. Land Section 2 as opt-in code path defaulting to `.v1`; enabling any non-default requires explicit `DecodeOptions` and bench evidence.
- Out of scope for this spec: persistent/incremental cache (separate spec), HEIF, GPU decode, XPC isolation, thumbnail-only fast path, persistent flags, folder-scan import.

## Data Flow (after)

```
importFiles(urls)
  → dedupe + isSupported → Session(files)
  → phase=.decoding(0,total)
  → DecodeEngine(options:.v1, workerCount: min(cores, mem/1 GiB) with pressure guard)
      JobQueue FIFO → workers withTaskGroup
        while dequeue:
          check cancelled
          t0 libraw_open_file + libraw_unpack            // disk-bound
          rawHistogram (Bayer count)                       // near-free
          libraw_dcraw_process (AHD, sRGB, gamm 2.222)     // CPU-bound, zero-copy provider
          make_mem_image → CGImage (single copy)
          cache.storeJPEG(bitmap, for:file, quality:opts.jpegQuality) // tmp+rename, dir ensured once
          try? cache.storeHistogram(histogram)
          AtomicOutcomeAccumulator.append; ProgressReporter.reportProgress()
      → completed([DecodeOutcome]) + Benchmark CSV via os_signpost
  → importFailures = unsupported + decode errors
  → session.remove(failed) → finishDecoding → installWindows → phase=.scrubbing
```

## Files Touched

- `QuickCullCore/Engine/DecodeEngine.swift` — workerCount retune, pressure guard, Benchmark/signpost hooks, init(options:), dir-once optimization.
- `QuickCullCore/Decoding/RawDecoding.swift` — `DecodeOptions` + `CacheMode` + protocol overload.
- `QuickCullCore/Decoding/LibRawDecoder.swift` — params mapping, zero-copy `CGDataProvider`, handle `use_rawspeed`.
- `QuickCullCore/Storage/ImageCacheStore.swift` — `storeJPEG(_:for:quality:)` overload, dir-once guard, quality plumbing.
- `QuickCullCore/App/AppState.swift` — inject `DecodeOptions` from settings/debug into `DecodeEngine` (default `.v1`, no UI for v1).
- `QuickCullCoreTests/DecodeEngineTests.swift`, `LibRawDecoderTests.swift`, `ImageCacheStoreTests.swift` — workerCount table, zero-copy image equality, quality + cacheMode coverage.
- `Scripts/bench-decode.sh` — new; `Scripts/fetch-fixtures.sh` reused.

Untouched: `Session`, `ImageWindow`, `TrashCommit/MoveCommit`, `GridView/FilmstripView`, `ImageDisplayView`, `RootView`, `DecodingView` (progress UI unchanged, just faster).

## Testing

- Unit: `workerCount` matrix (8 GB/8c → 8, 16 GB/10c → 10, 4 GB/4c → 4, limit:2 →2), memory-pressure clamp, `storeJPEG` atomic rename idempotent.
- Integration: `DecodeEngine` with stub decoders assert monotonic progress, exactly one `completed`, failed files don't block queue, `Benchmark` per-file totals sum ≈ `totalImportMs`.
- Performance: `bench-decode.sh` cold-cache runs on `Fixtures/raws` (8 RAWs) ×3 plus synthetic 50-file JPEG/RAW mix; asserts Section 1 alone >10% vs baseline without histogram or PSNR regression; knobs measured individually.
- Visual: manual `QA — ./start.sh`, import 50 RAWs (CR2/NEF/ARW/RAF), scrub at 100% loupe + histogram overlay, compare AHD vs bilinear vs q70 vs displayRes — no visible delta for default.
- CI: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -destination platform=macOS build-for-testing` + `xcrun xctest ...` stays green; add `Code Signing Allowed NO`.

## Risks & Mitigations

- More workers → higher peak RAM (8 × ~512 MB ≈ 4 GB). Guard with available-memory check and `workerLimit` injectability; test on 8 GB Air with 200-RAW stress.
- Zero-copy provider lifetime vs `libraw_dcraw_clear_mem` — guard with `CFData` retain and explicit test that CGImage survives after clear.
- `displayRes` temptation — explicitly gated, default fullRes, label warns "not archival".

## Open Questions (resolved)

- HEIF: measured slower, deferred. Persistent cache: deferred to separate spec.
