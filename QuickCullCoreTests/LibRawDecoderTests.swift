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
}
