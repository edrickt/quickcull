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
