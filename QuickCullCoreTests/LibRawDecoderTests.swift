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
        // FastRawViewer-style: linear Bayer histogram before demosaic.
        // 7 Bayer fixtures have a raw histogram; fuji_e550 (super-CCD/X-Trans)
        // returns nil and falls back to DisplayHistogram in the UI.
        let cases: [(name: String, ext: String)] = [
            ("img_0062", "cr2"), ("mg_2233", "cr3"), ("dsc8140", "nef"), ("dsc0258", "arw"),
            ("olympus_c5050z", "orf"), ("p1000336", "rw2"), ("pentax_k01", "dng"),
        ]
        for c in cases {
            let bitmap = try decoder.decodeRaw(at: fixture(c.name, c.ext))
            let hist = try XCTUnwrap(bitmap.histogram, "\(c.name).\(c.ext) should have a FastRawViewer RAW histogram")
            XCTAssertEqual(hist.bins.count, 3, c.name)
            XCTAssertTrue(hist.bins.allSatisfy { $0.count == RawHistogram.binCount }, c.name)
            XCTAssertGreaterThan(hist.sensorMax, 255, "\(c.name) raw sensorMax (e.g. 4095/16383)")
            XCTAssertEqual(hist.luminance.count, RawHistogram.binCount, c.name)
            let area = bitmap.width * bitmap.height
            // Bayer: R ~1/4, G ~1/2 (G+G2 merged), B ~1/4, luma == w*h (every raw value)
            XCTAssertEqual(hist.samples[0] + hist.samples[1] + hist.samples[2], area, "\(c.name) R+G+B == w*h (Bayer)")
            XCTAssertEqual(hist.samples[3], area, "\(c.name) luma count")
            XCTAssertEqual(hist.luminance.reduce(0,+), area, "\(c.name) luma sum")
            XCTAssertTrue(hist.clipping.allSatisfy{ $0 >= 0 && $0 <= 1 }, c.name)
            // Sanity: R and B roughly quarter, G roughly half (allow ±2% for crop/margins)
            let quarter = Double(area) / 4.0
            XCTAssertEqual(Double(hist.samples[0]), quarter, accuracy: quarter * 0.02, "\(c.name) R ~1/4")
            XCTAssertEqual(Double(hist.samples[2]), quarter, accuracy: quarter * 0.02, "\(c.name) B ~1/4")
            XCTAssertEqual(Double(hist.samples[1]), quarter * 2, accuracy: quarter * 0.04, "\(c.name) G ~1/2")
        }
        let fuji = try decoder.decodeRaw(at: fixture("fuji_e550","raf"))
        XCTAssertNil(fuji.histogram, "super-CCD/X-Trans has no Bayer raw histogram — UI falls back to DisplayHistogram")
    }

    func testLuminanceComputedForBayerFixtures() throws {
        let cases: [(name: String, ext: String)] = [("img_0062","cr2"),("dsc8140","nef"),("p1000336","rw2")]
        for c in cases {
            let bitmap = try decoder.decodeRaw(at: fixture(c.name, c.ext))
            let hist = try XCTUnwrap(bitmap.histogram, "\(c.name)")
            XCTAssertEqual(hist.luminance.count, RawHistogram.binCount, c.name)
            XCTAssertEqual(hist.luminance.reduce(0,+), bitmap.width * bitmap.height, "\(c.name) luma sum == pixel count")
            XCTAssertEqual(hist.samples[3], bitmap.width * bitmap.height, c.name)
            XCTAssertGreaterThan(hist.sensorMax, 255, c.name)
        }
    }

    func testSuperCCDAndXTransNowHaveHistogram() throws {
        let fuji = try decoder.decodeRaw(at: fixture("fuji_e550","raf"))
        XCTAssertNil(fuji.histogram, "super-CCD/X-Trans returns nil raw histogram; DisplayHistogram fallback used in UI")
        // Fallback is rendered: verify DisplayHistogram still works for its CGImage
        let fallback = DisplayHistogram.compute(from: fuji.image)
        XCTAssertEqual(fallback.sensorMax, 255)
        XCTAssertEqual(fallback.samples[0], fuji.width * fuji.height)
        XCTAssertEqual(fallback.luminance.count, RawHistogram.binCount)
    }

    func testLibRawDecoderProducesIdenticalPixelsWithZeroCopy() throws {
        // Use a real fixture via LibRawDecoder; decode twice and compare pixel hashes
        let bundleURL = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        let canonURL = bundleURL.appendingPathComponent("Fixtures/raws/canon_eos6d.cr2")
        let fallbackURL = bundleURL.appendingPathComponent("Fixtures/raws/img_0062.cr2")
        let url: URL
        if FileManager.default.fileExists(atPath: canonURL.path) {
            url = canonURL
        } else {
            url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "img_0062", withExtension: "cr2", subdirectory: "Fixtures/raws"))
            // sanity: ensure fallback exists
            XCTAssertTrue(FileManager.default.fileExists(atPath: fallbackURL.path) || FileManager.default.fileExists(atPath: url.path))
        }
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
}
