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
        fixtureDir = try TestFixtures.makeTempDir(name: "win")
        for index in 0..<count {
            try TestFixtures.writeJPEG(color: UInt8(index % 256),
                                       to: fixtureDir.appendingPathComponent(String(format: "%03d.jpg", index)))
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    private func makeLoader() -> (Int) async -> CGImage? {
        { [fixtureDir = self.fixtureDir!] index in
            guard index >= 0, index < self.count else { return nil }
            let src = CGImageSourceCreateWithURL(
                fixtureDir.appendingPathComponent(String(format: "%03d.jpg", index)) as CFURL, nil)!
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

    func testEnsureLoadedBeyondRadius() async {
        let window = ImageWindow(radius: 1, count: count, loader: makeLoader())
        window.setCurrent(0) // loads 0,1
        await window.waitUntilSettled()
        window.ensureLoaded(indices: [90])
        await window.waitUntilSettled()
        XCTAssertNotNil(window.image(at: 90))
        XCTAssertNotNil(window.image(at: 0)) // scrub window still there
    }

    func testEnsureLoadedMultipleAndEviction() async {
        let window = ImageWindow(radius: 2, count: count, loader: makeLoader())
        window.setCurrent(50)
        await window.waitUntilSettled()
        window.ensureLoaded(indices: [0, 99])
        await window.waitUntilSettled()
        XCTAssertNotNil(window.image(at: 0))
        XCTAssertNotNil(window.image(at: 99))
        // Move far: ensured indices outside new window + ensures should not all survive if not re-ensured
        window.setCurrent(50)
        await window.waitUntilSettled()
        window.ensureLoaded(indices: [10])
        window.setCurrent(90)
        await window.waitUntilSettled()
        // 10 was ensured last time but not this time; it may be evicted (allowed). Just ensure current window intact:
        XCTAssertNotNil(window.image(at: 90))
    }

    func testEnsureLoadedIgnoresOutOfBounds() async {
        let window = ImageWindow(radius: 1, count: 3, loader: makeLoader())
        window.setCurrent(0)
        await window.waitUntilSettled()
        window.ensureLoaded(indices: [-1, 3, 99])
        await window.waitUntilSettled()
        XCTAssertLessThanOrEqual(window.images.count, 3)
    }

    // MARK: Full-resolution display window

    /// A 5000×2500 JPEG decodes at exactly its own dimensions through the
    /// full-res path. The old `displayPixelLimit` capped the main viewer at
    /// max(screen) × 2 (3840 on a 1080p display), which made the loupe's
    /// "100%" a downsample for large raws; the full-res path must never
    /// shrink an image.
    func testLoadJPEGFullResKeepsFullDimensions() throws {
        let url = fixtureDir.appendingPathComponent("big.jpg")
        try TestFixtures.writeJPEG(color: 128, width: 5000, height: 2500, to: url)
        let image = ImageWindow.loadJPEGFullRes(at: url)
        XCTAssertEqual(image?.width, 5000)
        XCTAssertEqual(image?.height, 2500)
    }

    /// The main-viewer window decodes cache JPEGs at full resolution: a
    /// stored 5000×2500 bitmap comes back 5000×2500 through the whole
    /// display chain, so the loupe's crop is true source-pixel 1:1.
    func testDisplayWindowDecodesFullResolution() async throws {
        let (cache, base) = try await TestFixtures.makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }

        let fileURL = fixtureDir.appendingPathComponent("big.jpg")
        try TestFixtures.writeJPEG(color: 128, width: 5000, height: 2500, to: fileURL)
        let file = SessionFile(url: fileURL)
        let bitmap = RawBitmap(image: TestFixtures.makeCGImage(width: 5000, height: 2500, color: 128),
                               width: 5000, height: 2500, flip: 0)
        _ = try await cache.storeJPEG(bitmap, for: file)

        let window = ImageWindow.display(files: [file], cache: cache)
        window.setCurrent(0)
        await window.waitUntilSettled()
        XCTAssertEqual(window.image(at: 0)?.width, 5000)
        XCTAssertEqual(window.image(at: 0)?.height, 2500)
    }

    /// The main-viewer window never exceeds `displayExtentBehind` +
    /// current + `displayExtentAhead` (default 10 + 1 + 20 = 31 images at
    /// most — the full-res tier sits inside this extent, the outer ring is
    /// half-size): full-res bitmaps are the app's biggest working set, so
    /// the window must stay bounded by the policy, never by shoot size.
    func testDisplayWindowRespectsFullResPolicy() async throws {
        let (cache, base) = try await TestFixtures.makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }

        var files: [SessionFile] = []
        for i in 0..<10 {
            let url = fixtureDir.appendingPathComponent("w\(i).jpg")
            try TestFixtures.writeJPEG(color: UInt8(i), width: 64, height: 40, to: url)
            let file = SessionFile(url: url)
            files.append(file)
            let bitmap = RawBitmap(image: TestFixtures.makeCGImage(width: 64, height: 40, color: UInt8(i)),
                                   width: 64, height: 40, flip: 0)
            _ = try await cache.storeJPEG(bitmap, for: file)
        }
        let expected = ImageWindow.displayExtentBehind + 1 + ImageWindow.displayExtentAhead
        let window = ImageWindow.display(files: files, cache: cache)
        for index in [0, 5, 9] {
            window.setCurrent(index)
            await window.waitUntilSettled()
            XCTAssertLessThanOrEqual(window.images.count, expected,
                                     "display window must not exceed extent + 1 (\(expected))")
        }
    }

    /// Tiered windows: indices outside the full tier load the reduced
    /// loader, and entering the tier (landing on the index) upgrades it to
    /// the full loader automatically.
    func testTieredWindowLoadsReducedOutsideTierAndUpgradesWhenCurrent() async {
        let full = TestFixtures.makeCGImage(width: 64, height: 64, color: 1)
        let reduced = TestFixtures.makeCGImage(width: 32, height: 32, color: 2)
        let window = ImageWindow(behind: 3, ahead: 3, count: 10,
                                 loader: { _ in full },
                                 reducedLoader: { _ in reduced },
                                 upgradePolicy: { index, current in abs(index - current) > 1 })
        window.setCurrent(5)   // window [2,8]; full tier [4,6]
        await window.waitUntilSettled()
        XCTAssertEqual(window.image(at: 5)?.width, 64, "current is full-res")
        XCTAssertEqual(window.image(at: 4)?.width, 64, "tier edge is full-res")
        XCTAssertEqual(window.image(at: 2)?.width, 32, "out-of-tier index loads reduced")
        XCTAssertEqual(window.image(at: 8)?.width, 32, "out-of-tier index loads reduced")

        window.setCurrent(2)   // 2 enters the tier → upgrade pass
        await window.waitUntilSettled()
        XCTAssertEqual(window.image(at: 2)?.width, 64, "landing must upgrade to full-res")
    }

    /// The display factory tiers its window: within the full-res tier the
    /// cache JPEG decodes at full dimensions, the outer ring at half; a
    /// ring index upgrades to full-res once it becomes current.
    func testDisplayWindowTiersFullAndHalfRes() async throws {
        let (cache, base) = try await TestFixtures.makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }

        var files: [SessionFile] = []
        for i in 0..<25 {
            let url = fixtureDir.appendingPathComponent("t\(i).jpg")
            try TestFixtures.writeJPEG(color: UInt8(i), width: 64, height: 40, to: url)
            let file = SessionFile(url: url)
            files.append(file)
            let bitmap = RawBitmap(image: TestFixtures.makeCGImage(width: 64, height: 40, color: UInt8(i)),
                                   width: 64, height: 40, flip: 0)
            _ = try await cache.storeJPEG(bitmap, for: file)
        }
        let behind = ImageWindow.displayFullResBehind
        let ahead = ImageWindow.displayFullResAhead
        let center = 12
        let ringAhead = center + ahead + 1

        let window = ImageWindow.display(files: files, cache: cache)
        window.setCurrent(center)
        await window.waitUntilSettled()
        XCTAssertEqual(window.image(at: center)?.width, 64, "current is full-res")
        XCTAssertEqual(window.image(at: center - behind)?.width, 64, "tier edge is full-res")
        XCTAssertEqual(window.image(at: ringAhead)?.width, 32, "outer ring is half-size")

        window.setCurrent(ringAhead)   // land on the ring
        await window.waitUntilSettled()
        XCTAssertEqual(window.image(at: ringAhead)?.width, 64, "landing upgrades the ring to full-res")
    }

    /// Landing on an index while its reduced load is still in flight must still
    /// upgrade it: the `setCurrent` upgrade pass skips in-flight indices, so the
    /// completion is the only place that can notice the tier moved.
    func testLandingOnAnInFlightReducedLoadUpgradesIt() async {
        let gate = AsyncGate()
        let full = TestFixtures.makeCGImage(width: 64, height: 64, color: 1)
        let reduced = TestFixtures.makeCGImage(width: 32, height: 32, color: 2)
        let window = ImageWindow(behind: 3, ahead: 3, count: 10,
                                 loader: { _ in full },
                                 reducedLoader: { _ in
                                     await gate.wait()   // hold the reduced decode open
                                     return reduced
                                 },
                                 upgradePolicy: { index, current in abs(index - current) > 1 })
        window.setCurrent(5)   // 4,5,6 full; 2,3,7,8 kick off reduced loads
        window.setCurrent(2)   // land on 2 while its reduced load is in flight
        await gate.open()
        await window.waitUntilSettled()
        XCTAssertEqual(window.image(at: 2)?.width, 64,
                       "the in-flight reduced load must be followed by a full-res upgrade")
    }

    /// The grid keeps the viewport the user reached, never the whole shoot:
    /// residency is bounded by the fixed cap, not by the file count.
    func testGridResidencyIsBoundedByTheFixedCap() async throws {
        let (cache, base) = try await TestFixtures.makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        var files: [SessionFile] = []
        for i in 0..<100 {
            let file = SessionFile(url: fixtureDir.appendingPathComponent(String(format: "%03d.jpg", i)))
            files.append(file)
            let destination = try cache.cacheURL(for: file)
            try TestFixtures.writeJPEG(color: UInt8(i % 256), to: destination)
        }
        let window = ImageWindow.gridThumbnails(files: files, cache: cache)
        window.ensureLoaded(indices: Array(0..<100))
        await window.waitUntilSettled()
        XCTAssertLessThanOrEqual(window.images.count, ImageWindow.residentThumbCap)
        XCTAssertNotNil(window.image(at: 99), "the most recently ensured cell stays resident")
    }

    /// The loupe labels itself from this: a reduced placeholder must not
    /// report source pixels, and landing on the index must flip it.
    func testFullResolutionReflectsTheResidentTier() async {
        let full = TestFixtures.makeCGImage(width: 64, height: 64, color: 1)
        let reduced = TestFixtures.makeCGImage(width: 32, height: 32, color: 2)
        let window = ImageWindow(behind: 3, ahead: 3, count: 10,
                                 loader: { _ in full },
                                 reducedLoader: { _ in reduced },
                                 upgradePolicy: { index, current in abs(index - current) > 1 })
        window.setCurrent(5)
        await window.waitUntilSettled()
        XCTAssertTrue(window.isFullResolution(at: 5))
        XCTAssertFalse(window.isFullResolution(at: 2), "a half-size ring slot is not 1:1")
        XCTAssertFalse(window.isFullResolution(at: 9), "no resident image, no pixels")
        window.setCurrent(2)
        await window.waitUntilSettled()
        XCTAssertTrue(window.isFullResolution(at: 2))
    }

    func testFullResTierKnobsAreClampedToTheWindowExtent() {
        UserDefaults.standard.set(200, forKey: "displayFullResBehind")
        UserDefaults.standard.set(200, forKey: "displayFullResAhead")
        defer {
            UserDefaults.standard.removeObject(forKey: "displayFullResBehind")
            UserDefaults.standard.removeObject(forKey: "displayFullResAhead")
        }
        XCTAssertEqual(ImageWindow.displayFullResBehind, ImageWindow.displayExtentBehind)
        XCTAssertEqual(ImageWindow.displayFullResAhead, ImageWindow.displayExtentAhead)
    }

    // MARK: Identity retargeting

    /// Thread-safe counter for loader/decode assertions.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ item: String) { lock.lock(); defer { lock.unlock() }; items.append(item) }
        var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return items }
        var count: Int { snapshot.count }
        func contains(_ item: String) -> Bool { snapshot.contains(item) }
    }

    private func firstByte(of image: CGImage?) -> UInt8? {
        guard let image, let data = image.dataProvider?.data else { return nil }
        return CFDataGetBytePtr(data)?[0]
    }

    private func identifiedWindow(ids: [String], radius: Int = 30,
                                  loader: @escaping (String) async -> CGImage?) -> ImageWindow {
        ImageWindow(policy: WindowPolicy(radius: radius), ids: ids, loader: loader)
    }

    /// Retargeting a window onto a reordered/shrunken identity list must move
    /// each decoded image with its identity, without decoding anything again.
    func testRetargetPreservesResidentImagesWithoutDecoding() async {
        let colors: [String: UInt8] = ["a": 10, "b": 20, "c": 30, "d": 40]
        let loads = Counter()
        let window = identifiedWindow(ids: ["a", "b", "c", "d"]) { id in
            loads.append(id)
            return TestFixtures.makeCGImage(width: 4, height: 4, color: colors[id] ?? 0)
        }
        window.setCurrent(0)
        await window.waitUntilSettled()
        XCTAssertEqual(window.images.count, 4)
        let loadsBefore = loads.count

        // Drop "b" and reverse the rest.
        window.retarget(ids: ["d", "c", "a"])
        window.setCurrent(0)
        await window.waitUntilSettled()

        XCTAssertEqual(window.count, 3)
        XCTAssertEqual(window.ids, ["d", "c", "a"])
        XCTAssertEqual(firstByte(of: window.image(at: 0)), 40, "d keeps its pixels at its new position")
        XCTAssertEqual(firstByte(of: window.image(at: 1)), 30, "c keeps its pixels")
        XCTAssertEqual(firstByte(of: window.image(at: 2)), 10, "a keeps its pixels")
        XCTAssertEqual(loads.count, loadsBefore, "a retarget must not re-decode resident images")
    }

    /// A load that completes after a retarget must land at the identity's new
    /// position, never at the stale one (which may now hold another photo).
    func testInFlightLoadLandsAtTheIdentitysNewPositionAfterRetarget() async {
        let gate = AsyncGate()
        let colors: [String: UInt8] = ["a": 10, "b": 20, "c": 30]
        let window = identifiedWindow(ids: ["a", "b", "c"], radius: 1) { id in
            await gate.wait()
            return TestFixtures.makeCGImage(width: 4, height: 4, color: colors[id] ?? 0)
        }
        window.setCurrent(0)          // loads a, b (radius 1) — both parked on the gate
        window.retarget(ids: ["c", "a"])
        window.setCurrent(0)          // window is c, a — a is still in flight from before
        await gate.open()
        await window.waitUntilSettled()

        XCTAssertEqual(window.ids, ["c", "a"])
        XCTAssertEqual(firstByte(of: window.image(at: 0)), 30, "c is at position 0")
        XCTAssertEqual(firstByte(of: window.image(at: 1)), 10,
                       "a's pre-retarget load must land at a's new position")
        XCTAssertNil(window.image(at: 2))
    }

    /// A queued load whose identity left the projection is cancelled, so it
    /// never spends the decode.
    func testRetargetCancelsQueuedLoadForDroppedIdentity() async {
        let decoded = Counter()
        let window = identifiedWindow(ids: ["keep", "drop"]) { id in
            // Cancellation-aware pause standing in for the decode: a cancelled
            // load returns here instead of spending the work.
            guard (try? await Task.sleep(nanoseconds: 150_000_000)) != nil else { return nil }
            decoded.append(id)
            return TestFixtures.makeCGImage(width: 4, height: 4, color: 1)
        }
        window.setCurrent(0)
        window.retarget(ids: ["keep"])
        await window.waitUntilSettled()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(decoded.contains("drop"),
                       "a load for a dropped identity must be cancelled before decoding")
        XCTAssertTrue(decoded.contains("keep"), "the surviving identity still loads")
        XCTAssertNotNil(window.image(at: 0))
    }
}

/// Async gate for tests: loaders park on it until the test opens it. Unlike a
/// `DispatchSemaphore` it suspends the task instead of blocking a thread.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
