import XCTest
@testable import QuickCullCore

final class RawFileIdentityTests: XCTestCase {
    func testSupportedExtensions() {
        for ext in ["cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
                    "rw2", "dng", "pef", "3fr", "fff", "iiq", "x3f", "srw",
                    "dcr", "kdc", "erf"] {
            let url = URL(fileURLWithPath: "/tmp/shoot/IMG_0001.\(ext)")
            XCTAssertTrue(RawFileIdentity.isSupported(url), "\(ext) should be supported")
        }
    }

    func testUnsupportedAndCaseInsensitive() {
        XCTAssertFalse(RawFileIdentity.isSupported(URL(fileURLWithPath: "/a/x.jpg")))
        XCTAssertTrue(RawFileIdentity.isSupported(URL(fileURLWithPath: "/a/x.CR2")))
    }

    func testFileIDIsStandardizedPath() {
        let url = URL(fileURLWithPath: "/Users/x/../x/photo.cr2")
        XCTAssertEqual(RawFileIdentity.fileID(for: url), "/Users/x/photo.cr2")
    }
}
