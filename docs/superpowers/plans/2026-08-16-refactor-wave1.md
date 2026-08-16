# Refactor Wave 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Behavior-preserving consolidation and hardening of QuickCull: unify the two duplicated window classes into one `ImageWindow`, slim `AppState`, fix the parked robustness items (atomic cache replace, commit off the main actor, cancellation-safe waits, cooperative engine cancellation), bound decode workers by memory, and consolidate duplicated test helpers.

**Architecture:** One new core type (`ImageWindow`) replaces `SlidingWindow` + `DisplayImageProvider` with identical invariants; `AppState` keeps its public property names so all views are untouched. `TrashCommit` moves off the main actor via a `Sendable` `Trashing` protocol. `DecodeEngine` gains an injectable worker limit (auto rule: `min(cores, physicalMemory / 512MB)`) and cooperative cancellation.

**Tech Stack:** Swift 5 language mode on Xcode 26, SwiftUI + Observation (macOS 14), XCTest. No new dependencies.

## Global Constraints

- **The 65-test suite stays green after every task** (it may grow; never shrink or weaken).
- No UI/UX changes: visuals, keys, flow identical. Views compile unchanged (`AppState.thumbWindow` / `displayImages` property names and their `image(at:)`/`setCurrent(_:)` APIs survive).
- No new features, no format changes, no behavior changes outside the listed items.
- Sandbox harness facts: every xcodebuild needs `-derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'`; tests run via `xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest`; never `xcodebuild test`.
- Working tree: `/Users/oslo/Files/github/quickcull`, branch `main`. Commit per task with the given messages.

---

### Task 1: ImageWindow — unify the window layer, slim AppState

**Files:**
- Create: `QuickCullCore/Window/ImageWindow.swift` (replaces both classes from `QuickCullCore/Window/SlidingWindow.swift`)
- Delete: `QuickCullCore/Window/SlidingWindow.swift`
- Modify: `QuickCullCore/App/AppState.swift` (installWindows, remove loader factories)
- Delete: `QuickCullCoreTests/SlidingWindowTests.swift`
- Create: `QuickCullCoreTests/ImageWindowTests.swift`
- Test: `QuickCullCoreTests/WindowPolicyTests.swift` (unchanged)

**Interfaces:**
- Consumes: `SessionFile`, `ImageCacheStore` (cacheURL), `WindowPolicy` (unchanged pure math), CGImage/ImageIO.
- Produces (used by Task 3 and all views):
  - `@MainActor @Observable final class ImageWindow` — `init(radius: Int, count: Int, loader: @escaping (Int) async -> CGImage?)`, `setCurrent(_ index: Int)`, `image(at index: Int) -> CGImage?`, `waitUntilSettled(timeout: TimeInterval? = nil) async`, `public private(set) var images: [Int: CGImage]`
  - `ImageWindow.thumbnails(files: [SessionFile], cache: ImageCacheStore) -> ImageWindow` (radius 30, maxPixel 320)
  - `ImageWindow.display(files: [SessionFile], cache: ImageCacheStore) -> ImageWindow` (radius 1, maxPixel = 2× screen long edge)
  - `AppState.thumbWindow: ImageWindow?`, `AppState.displayImages: ImageWindow?` (names unchanged)

- [ ] **Step 1: Write the failing replacement tests** — `QuickCullCoreTests/ImageWindowTests.swift` (re-targets every SlidingWindowTests assertion at the new type, plus the two new behaviors). The helper `writeJPEG`/`makeLoader`/fixture-dir machinery is copied from the old test file for now (Task 5 consolidates it):

```swift
import CoreGraphics
import ImageIO
import Observation
import XCTest
@testable import QuickCullCore

@MainActor
final class ImageWindowTests: XCTestCase {
    private var fixtureDir: URL!
    private let count = 100

    override func setUp() async throws {
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-win-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        for index in 0..<count {
            try writeJPEG(color: UInt8(index % 256), to: url(for: index))
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    private func url(for index: Int) -> URL {
        fixtureDir.appendingPathComponent(String(format: "%03d.jpg", index))
    }

    private func writeJPEG(color: UInt8, to url: URL) throws {
        let width = 64, height = 40
        var bytes = [UInt8](repeating: color, count: width * height * 3)
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                            bitsPerPixel: 24, bytesPerRow: width * 3,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        let sink = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(sink, image, nil)
        CGImageDestinationFinalize(sink)
    }

    private func makeLoader() -> (Int) async -> CGImage? {
        { [fixtureDir = self.fixtureDir!] index in
            guard index >= 0, index < self.count else { return nil }
            let src = CGImageSourceCreateWithURL(self.url(for: index) as CFURL, nil)!
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
    }

    func testWindowNeverExceedsRadiusPlusOne() async {
        let window = ImageWindow(radius: 30, count: count, loader: makeLoader())
        for index in [0, 5, 50, 95, 99, 50, 0] {
            window.setCurrent(index)
            await window.waitUntilSettled()
            XCTAssertLessThanOrEqual(window.images.count, 61)
        }
    }

    func testCurrentImageLoadedFirst() async {
        var seen: [Int] = []
        let window = ImageWindow(radius: 30, count: count) { index in
            seen.append(index)
            return nil
        }
        window.setCurrent(50)
        await window.waitUntilSettled()
        XCTAssertEqual(seen.first, 50)
    }

    func testEvictionDropsFarEdges() async {
        let window = ImageWindow(radius: 2, count: count, loader: makeLoader())
        window.setCurrent(50)
        await window.waitUntilSettled()
        window.setCurrent(99)
        await window.waitUntilSettled()
        XCTAssertNil(window.image(at: 48))
        XCTAssertNotNil(window.image(at: 97))
    }

    func testDisplayRadiusKeepsAtMostThree() async {
        let window = ImageWindow(radius: 1, count: count, loader: makeLoader())
        for index in [0, 1, 2, 3, 10, 99] {
            window.setCurrent(index)
            await window.waitUntilSettled()
            XCTAssertLessThanOrEqual(window.images.count, 3)
        }
        window.setCurrent(50)
        await window.waitUntilSettled()
        XCTAssertNotNil(window.image(at: 50))
        XCTAssertNotNil(window.image(at: 49))
        XCTAssertNotNil(window.image(at: 51))
        XCTAssertNil(window.image(at: 48))
    }

    func testImagePopulationIsObservable() async {
        let window = ImageWindow(radius: 30, count: count, loader: makeLoader())
        var fired = false
        withObservationTracking {
            _ = window.image(at: 0)
        } onChange: {
            fired = true
        }
        window.setCurrent(0)
        await window.waitUntilSettled()
        for _ in 0..<10 where !fired {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(fired, "image population must fire observation")
    }

    func testWaitUntilSettledHonorsTimeout() async {
        let window = ImageWindow(radius: 30, count: 3) { _ in
            try? await Task.sleep(nanoseconds: 500_000_000)  // slow loader
            return nil
        }
        window.setCurrent(0)
        let start = Date()
        await window.waitUntilSettled(timeout: 0.05)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.4,
                          "timeout must return before the slow loader finishes")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the standard build-for-testing; expect BUILD FAILED with `cannot find 'ImageWindow' in scope`.

- [ ] **Step 3: Implement `ImageWindow`** — `QuickCullCore/Window/ImageWindow.swift`:

```swift
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Observation

/// Bounded in-memory window of rendered images keyed by position: current ±
/// radius, loaded current-first by an async loader. @Observable so the UI
/// re-renders when async loads populate `images`. One type serves both the
/// filmstrip (radius 30, thumbnails) and the main viewer (radius 1, display
/// size).
@MainActor
@Observable
public final class ImageWindow {
    public let radius: Int
    public let count: Int
    public private(set) var images: [Int: CGImage] = [:]

    private let loader: (Int) async -> CGImage?
    private var inFlight: Set<Int> = []
    private var currentIndex: Int = 0

    public init(radius: Int, count: Int, loader: @escaping (Int) async -> CGImage?) {
        self.radius = radius
        self.count = count
        self.loader = loader
    }

    public func setCurrent(_ index: Int) {
        currentIndex = min(max(index, 0), max(count - 1, 0))
        let policy = WindowPolicy(radius: radius)

        // Materialize the key set: mutating `images` while iterating its
        // keys is technically undefined.
        for i in Set(images.keys) where !policy.window(around: currentIndex, count: count).contains(i) {
            images.removeValue(forKey: i)
            inFlight.remove(i)
        }

        for i in policy.loadOrder(current: currentIndex, count: count)
        where images[i] == nil && !inFlight.contains(i) {
            inFlight.insert(i)
            Task { [weak self] in
                let image = await loader(i)
                guard let self else { return }
                self.inFlight.remove(i)
                guard policy.window(around: self.currentIndex, count: self.count).contains(i) else { return }
                if let image { self.images[i] = image }
            }
        }
        assert(images.count <= 2 * radius + 1, "window invariant violated")
    }

    public func image(at index: Int) -> CGImage? { images[index] }

    /// Awaits until all in-flight loads settle, the optional timeout
    /// expires, or the caller is cancelled (used by tests).
    public func waitUntilSettled(timeout: TimeInterval? = nil) async {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while !inFlight.isEmpty {
            if let deadline, Date() >= deadline { return }
            do { try await Task.sleep(nanoseconds: 5_000_000) }
            catch { return }   // cancelled: stop waiting
        }
    }

    // MARK: App factories

    /// Filmstrip window: radius 30, 320 px thumbnails.
    public static func thumbnails(files: [SessionFile], cache: ImageCacheStore) -> ImageWindow {
        ImageWindow(radius: 30, count: files.count) { [cache] index in
            guard index >= 0, index < files.count else { return nil }
            return loadJPEG(at: try? await cache.cacheURL(for: files[index]),
                            maxPixelSize: 320)
        }
    }

    /// Main-viewer window: radius 1, display size (2× screen long edge).
    public static func display(files: [SessionFile], cache: ImageCacheStore) -> ImageWindow {
        let pixels = displayPixelLimit()
        return ImageWindow(radius: 1, count: files.count) { [cache] index in
            guard index >= 0, index < files.count else { return nil }
            return loadJPEG(at: try? await cache.cacheURL(for: files[index]),
                            maxPixelSize: pixels)
        }
    }

    private static func displayPixelLimit() -> Int {
        Int(max(NSScreen.main?.frame.width ?? 1920,
                NSScreen.main?.frame.height ?? 1080) * 2)
    }

    /// Downsamples a cached JPEG (thumbnail API = memory-bounded).
    private static func loadJPEG(at url: URL?, maxPixelSize: Int) -> CGImage? {
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
```

Note: `waitUntilSettled` keeps the poll loop (bounded 5 ms sleeps) with two fixes — a deadline check and cancellation-safe sleep. A tracked-task list was considered but grows unboundedly across `setCurrent` calls; poll + deadline + cancel-on-error delivers the same contract with no accumulation. This is a mechanism refinement of the spec, same behavior.

- [ ] **Step 4: Slim `AppState`** — replace the window-construction section. Delete `makeThumbLoader`, `makeDisplayLoader`, `displayPixelLimit`, `loadJPEG` (all moved into `ImageWindow`). Replace `finishDecoding` and `rebuildWindows` with one shared installer:

```swift
    private func finishDecoding(files: [SessionFile]) {
        installWindows(for: files)
        phase = .scrubbing
    }

    private func installWindows(for files: [SessionFile]) {
        thumbWindow = ImageWindow.thumbnails(files: files, cache: cache)
        displayImages = ImageWindow.display(files: files, cache: cache)
        syncWindows()
    }
```

and in `confirmCommit`'s non-empty branch, replace `rebuildWindows()` with `installWindows(for: session.files)`, then delete `rebuildWindows` (keep `syncWindows`, `dismissImportFailures`, and everything else unchanged).

- [ ] **Step 5: Delete `QuickCullCore/Window/SlidingWindow.swift` and `QuickCullCoreTests/SlidingWindowTests.swift`**

- [ ] **Step 6: Run the full suite**

Expected: `Executed 71 tests, with 0 failures` (65 − 7 old window tests + 6 new ImageWindow tests + 7 — count the actual; every pre-existing assertion must survive in re-targeted form).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: unify SlidingWindow and DisplayImageProvider into ImageWindow"
```

---

### Task 2: Atomic cache replace

**Files:**
- Modify: `QuickCullCore/Storage/ImageCacheStore.swift`
- Test: `QuickCullCoreTests/ImageCacheStoreTests.swift`

**Interfaces:**
- Unchanged: `storeJPEG(_:for:) throws -> URL` signature. Internally: `FileManager.replaceItemAt` instead of remove-then-move.

- [ ] **Step 1: Write the failing test** — add to `ImageCacheStoreTests`:

```swift
    func testStoreJPEGReplacesExistingEntryAtomically() async throws {
        let file = try makeFile("a.cr2")
        let first = try await store.storeJPEG(makeBitmap(), for: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        // Overwrite; the entry must still exist and stay decodable.
        let second = try await store.storeJPEG(makeBitmap(), for: file)
        XCTAssertEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        guard let source = CGImageSourceCreateWithURL(second as CFURL, nil) else {
            return XCTFail("replaced entry not decodable")
        }
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })
    }
```

- [ ] **Step 2: Run test to verify it fails**

Expected: current implementation fails (or passes by luck — verify it exercises the replace: with the OLD code the test passes trivially, so also assert no `.tmp` leftovers and that a re-encode after deletion of the destination succeeds; if the old code passes, the meaningful regression is the atomicity property — see Step 4's note). If the test passes on old code, keep it as the regression net and verify the implementation change directly in Step 4's code review.

- [ ] **Step 3: Implement the atomic replace**

In `ImageCacheStore.storeJPEG`, replace:

```swift
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
```

with:

```swift
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: destination)
        }
```

- [ ] **Step 4: Run the suite**

Expected: all ImageCacheStore tests pass (13 total across the suite stays green; the new test passes and pins the no-loss property).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: atomic cache entry replacement in storeJPEG"
```

---

### Task 3: Commit off the main actor

**Files:**
- Modify: `QuickCullCore/Commit/TrashCommit.swift` (`Trashing: Sendable`)
- Modify: `QuickCullCore/App/AppState.swift` (`confirmCommit() async`, `isCommitting`)
- Modify: `QuickCull/ScrubView.swift` (commit button Task + progress state)
- Modify: `QuickCullCoreTests/TestDoubles.swift` (`StubTrasher` Sendable)
- Modify: `QuickCullCoreTests/AppStateTests.swift` (await confirmCommit)

**Interfaces:**
- `public protocol Trashing: Sendable`
- `public func confirmCommit() async`
- `AppState.isCommitting: Bool` (public private(set), @Observable)

- [ ] **Step 1: Write the failing test** — the commit tests must await the async API; add a state test:

```swift
    func testCommitSetsCommittingState() async throws {
        let a = try makeRaw("a.cr2")
        let b = try makeRaw("b.cr2")
        let trasher = StubTrasher()
        let state = makeState(trasher: trasher)
        state.importFiles(urls: [a, b])
        await waitForScrubbing(state)

        state.handle(.toggleFlag)
        state.requestCommit()
        XCTAssertFalse(state.isCommitting)
        await state.confirmCommit()
        XCTAssertFalse(state.isCommitting)
        XCTAssertEqual(state.session?.count, 1)
        XCTAssertEqual(trasher.trashed.count, 1)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Expected: BUILD FAILED — `confirmCommit` is not async yet (`'async' call in an autoclosure that does not support concurrency` or missing member).

- [ ] **Step 3: Implement**

`TrashCommit.swift`:

```swift
public protocol Trashing: Sendable {
    func trash(url: URL) throws
}
```

`AppState.swift` — add `public private(set) var isCommitting: Bool = false`; replace `confirmCommit`:

```swift
    public func confirmCommit() async {
        guard let session, !isCommitting else { return }
        let flagged = session.flaggedFiles
        isCommitting = true
        let outcomes = await Task.detached(priority: .userInitiated) {
            TrashCommit(trasher: trasher).commit(files: flagged)
        }.value
        let succeeded = outcomes.filter(\.succeeded).map(\.file)
        session.remove(succeeded)
        commitFailures = outcomes.filter { !$0.succeeded }
        pendingCommitCount = 0
        isCommitting = false
        if session.isEmpty {
            session = nil
            thumbWindow = nil
            displayImages = nil
            phase = .empty
        } else {
            installWindows(for: session.files)
        }
    }
```

Note: `Task.detached` runs the trash moves off the main actor; outcomes are applied back on the main actor because `confirmCommit` is `@MainActor`. Swift 5 mode tolerates the `Error?` in `TrashOutcome` crossing the boundary (warning-free in 5.0; do not "fix" with Sendable wrappers in this wave).

`ScrubView.swift` — the commit button:

```swift
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.requestCommit()
                    showCommitConfirm = true
                } label: {
                    Label("Move Flagged to Trash", systemImage: "trash")
                }
                .disabled(appState.session?.flaggedCount == 0 || appState.isCommitting)
            }
```

and the confirmation alert's destructive button:

```swift
            Button("Move to Trash", role: .destructive) {
                Task { await appState.confirmCommit() }
            }
```

Optionally show progress while committing by swapping the label for `ProgressView().controlSize(.small)` when `appState.isCommitting`.

`TestDoubles.swift` — `StubTrasher` becomes `final class StubTrasher: Trashing, @unchecked Sendable` (it is already a locked class).

`AppStateTests.swift` — every `state.confirmCommit()` becomes `await state.confirmCommit()` (tests are already async).

- [ ] **Step 4: Run the full suite**

Expected: all commit tests pass with the awaited API (65 + 1 new − re-pointed; count the actual).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: trash commit runs off the main actor"
```

---

### Task 4: DecodeEngine — cooperative cancellation + memory-bounded workers

**Files:**
- Modify: `QuickCullCore/Engine/DecodeEngine.swift`
- Test: `QuickCullCoreTests/DecodeEngineTests.swift`

**Interfaces:**
- `DecodeEngine.init(decoder: RawDecoding, cache: ImageCacheStore, workerLimit: Int? = nil)`
- `DecodeEngine.workerCount(activeProcessors: Int, physicalMemoryBytes: UInt64, limit: Int?) -> Int` (static, pure — the auto rule `min(cores, max(1, bytes / 512MB))` with explicit limit `max(1, limit)`)

- [ ] **Step 1: Write the failing tests**

```swift
    func testWorkerCountFormula() {
        let gb = UInt64(1024 * 1024 * 1024)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 8 * gb, limit: nil), 4)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 16, physicalMemoryBytes: 16 * gb, limit: nil), 8)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 32, physicalMemoryBytes: 32 * gb, limit: nil), 16)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 2, physicalMemoryBytes: 8 * gb, limit: nil), 2)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 8 * gb, limit: 2), 2)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 8 * gb, limit: 0), 1)
    }

    func testCancellationStopsWorkers() async throws {
        let files = makeFiles((0..<20).map { "img_\($0).cr2" })
        let decoder = SlowStubDecoder(delay: 50_000_000)   // 50 ms per decode
        let (cache, base) = try await makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: decoder, cache: cache, workerLimit: 2)

        let consumer = Task {
            var events: [DecodeEngine.Event] = []
            for await event in engine.decodeAll(files: files) { events.append(event) }
            return events
        }
        // Let a couple of files decode, then cancel the consumer.
        try? await Task.sleep(nanoseconds: 150_000_000)
        consumer.cancel()
        _ = await consumer.value
        // Workers stop early: far fewer than 20 files decoded.
        XCTAssertLessThan(decoder.callCount(), 20, "cancellation must stop the worker pool")
    }
```

Add `SlowStubDecoder` next to `StubDecoder` in `TestDoubles.swift` (same shape, optional `delay: UInt64` — `try? await Task.sleep(nanoseconds: delay)` before returning the bitmap; thread-safe call log).

- [ ] **Step 2: Run tests to verify they fail**

Expected: BUILD FAILED — `workerCount` and the new init parameter do not exist.

- [ ] **Step 3: Implement**

In `DecodeEngine`:

```swift
    private let workerCount: Int

    public init(decoder: RawDecoding, cache: ImageCacheStore, workerLimit: Int? = nil) {
        self.decoder = decoder
        self.cache = cache
        self.workerCount = Self.workerCount(
            activeProcessors: ProcessInfo.processInfo.activeProcessorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            limit: workerLimit)
    }

    /// Memory-bounded worker rule: one worker per 512 MB of physical RAM
    /// (LibRaw unpack + demosaic + mem image + JPEG encode for a 45 MP raw),
    /// capped by core count; explicit limits are floor-1.
    public static func workerCount(activeProcessors: Int,
                                   physicalMemoryBytes: UInt64,
                                   limit: Int?) -> Int {
        if let limit {
            return max(1, limit)
        }
        let byMemory = max(1, Int(physicalMemoryBytes / (512 * 1024 * 1024)))
        return min(max(1, activeProcessors), byMemory)
    }
```

In `decodeAll`, use `workerCount` instead of `activeProcessorCount`; in the worker loop, check cancellation between files:

```swift
                        group.addTask {
                            while let file = await queue.dequeue() {
                                if Task.isCancelled { break }
                                // ... existing decode/store/outcome/progress body ...
                            }
                        }
```

- [ ] **Step 4: Run the full suite**

Expected: all DecodeEngine tests pass (formula + cancellation + existing). Note: the existing tests construct `DecodeEngine(decoder:cache:)` — the new parameter is optional, so they compile unchanged; they now run with the auto rule, which is fine on this machine (≥ 8 GB → ≥ 4 workers for ≤ 20 files).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: memory-bounded decode workers and cooperative cancellation"
```

---

### Task 5: Consolidate duplicated test helpers

**Files:**
- Create: `QuickCullCoreTests/TestFixtures.swift`
- Modify: `QuickCullCoreTests/ImageCacheStoreTests.swift`, `DecodeEngineTests.swift`, `TrashCommitTests.swift`, `AppStateTests.swift`, `ImageIODecoderTests.swift`, `ImageWindowTests.swift` (each drops its local copies)

**Interfaces:**
- `enum TestFixtures` (internal static helpers):
  - `static func makeTempDir(name: String) throws -> URL`
  - `static func makeCGImage(width: Int, height: Int, color: UInt8) -> CGImage`
  - `static func writeJPEG(color: UInt8, width: Int = 64, height: Int = 40, to url: URL) throws`
  - `static func makeRawFile(named: String, in dir: URL, size: Int = 100) throws -> URL`
  - `static func makeFiles(_ names: [String]) -> [SessionFile]` (paths under `/tmp/shoot/`, matching StubDecoder usage)
  - `static func makeTempCache() async throws -> (ImageCacheStore, URL)`

- [ ] **Step 1: Create `TestFixtures.swift`** — implement the helpers by moving the existing per-file copies verbatim (each helper's body already exists in one of the test files; relocate, don't redesign).

- [ ] **Step 2: Re-point every test file** — delete each file's private duplicates (`makeTempCache`, `makeFiles`, `makeFile`, `makeBitmap`, `makeRaw`, `writeJPEG`, `url(for:)`, fixture-dir setup) and use `TestFixtures.*`. Keep file-specific logic in place: `AppStateTests.makeState/waitForScrubbing/waitForEmpty`, `ImageIODecoderTests.writeImage` (UTType map), `StubDecoder`/`StubTrasher`/`SlowStubDecoder` in TestDoubles.

- [ ] **Step 3: Run the full suite**

Expected: same test count as Task 4's end state (65 + 1 atomic-replace + 1 committing-state + 2 engine = 69 + any re-pointed; verify no assertion was dropped: `git diff` shows only helper relocations, no test-body changes except helper call sites).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: consolidate duplicated test helpers into TestFixtures"
```

---

### Task 6: Docs sync + clean-state verification

**Files:**
- Modify: `README.md` (nothing user-visible changed — verify; adjust only if a wording is now wrong)
- Modify: `docs/superpowers/plans/2026-08-16-quickcull-v1.md` (Tasks 5/9 code blocks: `SlidingWindow`/`DisplayImageProvider` → `ImageWindow`; AppState blocks; engine init)
- Modify: `docs/superpowers/specs/2026-08-16-refactor-wave1-design.md` (mark implemented; note the waitUntilSettled mechanism refinement)

- [ ] **Step 1: Sync the plan doc** — replace the Task 5 window-class code blocks with the `ImageWindow` file; update the Task 9 AppState blocks (installWindows, async confirmCommit); update the Task 7 engine block (workerCount). Keep every code block byte-accurate to the merged code.

- [ ] **Step 2: Clean-state verification**

```bash
rm -rf Build /tmp/qc-dd
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Release \
  -destination 'platform=macOS' -derivedDataPath Build/Release \
  OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build
./start.sh   # then confirm the process stays alive ~5 s; ./stop.sh
```

Expected: full LibRaw rebuild (few minutes), suite green with the wave's final count, app builds, launches, stays running.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs: sync refactor wave 1 into plan and spec"
```

---

## Self-Review Notes

- **Spec coverage:** all four workstreams map 1:1 to tasks; parked items covered (window eviction Set + waitUntilSettled in Task 1, atomic replace Task 2, commit-off-main Task 3, cancellation Task 4, worker bound Task 4, test helpers Task 5, docs Task 6).
- **Test-count arithmetic:** Task 1: 65 − 7 (old window tests) + 6 (new ImageWindow) = 64 + 1 (timeout) = 65? The old SlidingWindowTests had 6 tests (5 original + ... count at implementation time; the plan's counts are guidance — the invariant is *no assertion lost*: every old window test exists re-targeted).
- **Type consistency:** `ImageWindow.images` replaces `thumbnails`/`images` (old two types); views use `image(at:)`/`setCurrent` — unchanged names; `AppState.confirmCommit() async` — single call site updated in Task 3's ScrubView change; `Trashing: Sendable` — StubTrasher conforms.
- **Placeholder scan:** no TBDs; every code block complete.
