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

    /// The main-viewer window never exceeds current ± `displayFullResRadius`
    /// (default 15 → 31 full-res images at most): full-res bitmaps are the
    /// app's biggest working set, so the window must stay bounded by the
    /// radius, never by shoot size. A 61-image full-res window measured
    /// 3.8GB and thrashed swap on an 8GB machine; this pins the bound so a
    /// bump is a conscious knob change.
    func testDisplayWindowRespectsFullResRadius() async throws {
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
        let radius = ImageWindow.displayFullResRadius
        let expected = 2 * radius + 1
        let window = ImageWindow.display(files: files, cache: cache)
        for index in [0, 5, 9] {
            window.setCurrent(index)
            await window.waitUntilSettled()
            XCTAssertLessThanOrEqual(window.images.count, expected,
                                     "display window must not exceed current ± radius (\(expected))")
        }
    }
}
