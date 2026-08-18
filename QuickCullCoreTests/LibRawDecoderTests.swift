import XCTest
@testable import QuickCullCore

final class LibRawDecoderTests: XCTestCase {
    private let decoder = LibRawDecoder()

    private func fixture(_ name: String, _ ext: String) -> URL {
        Bundle(for: Self.self).url(forResource: name, withExtension: ext,
                                   subdirectory: "Fixtures/raws")!
    }

    func testPositiveFixturesDecode() throws {
        let cases: [(name: String, ext: String, width: Int, height: Int, flip: Int)] = [
            ("img_0062", "cr2", 3522, 2348, 0),
            ("mg_2233", "cr3", 6024, 4020, 0),
            ("dsc8140", "nef", 3904, 2604, 0),
            ("dsc0258", "arw", 3881, 2607, 0),
            ("fuji_e550", "raf", 2894, 2177, 0),
            ("olympus_c5050z", "orf", 1926, 2576, 5),
            ("p1000336", "rw2", 4912, 3688, 0),
            ("pentax_k01", "dng", 4936, 3272, 0),
        ]
        for c in cases {
            let bitmap = try decoder.decodeRaw(at: fixture(c.name, c.ext))
            XCTAssertEqual(bitmap.width, c.width, c.name)
            XCTAssertEqual(bitmap.height, c.height, c.name)
            XCTAssertEqual(bitmap.flip, c.flip, c.name)
            XCTAssertEqual(bitmap.image.width, c.width, c.name)
        }
    }

    func testNegativeFixturesThrow() {
        for (name, ext) in [("bad_truncated", "cr2"), ("bad_truncated", "raf"), ("bad_truncated", "iiq")] {
            XCTAssertThrowsError(try decoder.decodeRaw(at: fixture(name, ext)), "\(name).\(ext) should fail")
        }
    }

    func testMissingFileThrowsCannotOpen() {
        XCTAssertThrowsError(try decoder.decodeRaw(at: URL(fileURLWithPath: "/nonexistent/photo.cr2")))
    }

    /// End-to-end orientation check: dcraw_process already rotates the raw
    /// (olympus decodes to 1926x2576 upright portrait with flip=5), so the
    /// cached JPEG must carry no orientation tag — loading it the way
    /// ImageWindow.loadJPEG does (thumbnail + transform) must NOT rotate again.
    func testOrientedRawStaysUprightThroughCacheRoundTrip() async throws {
        let url = fixture("olympus_c5050z", "orf")
        let bitmap = try decoder.decodeRaw(at: url)
        XCTAssertEqual(bitmap.flip, 5)

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-orient-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ImageCacheStore(baseURL: base)
        let cached = try await store.storeJPEG(bitmap, for: SessionFile(url: url))

        guard let source = CGImageSourceCreateWithURL(cached as CFURL, nil) else {
            return XCTFail("cached JPEG not decodable")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return XCTFail("thumbnail creation failed")
        }
        XCTAssertEqual(thumb.width, 1926)
        XCTAssertEqual(thumb.height, 2576)
    }

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
}
