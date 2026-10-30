import XCTest
@testable import QuickCullCore

final class RawFileIdentityTests: XCTestCase {
    func testSupportedExtensions() {
        for ext in ["cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
                    "rw2", "dng", "pef", "3fr", "fff", "iiq", "x3f", "srw",
                    "dcr", "kdc", "erf", "jpg", "jpeg", "png", "heic", "heif"] {
            let url = URL(fileURLWithPath: "/tmp/shoot/IMG_0001.\(ext)")
            XCTAssertTrue(RawFileIdentity.isSupported(url), "\(ext) should be supported")
        }
    }

    func testDecoderKindRouting() {
        XCTAssertEqual(RawFileIdentity.decoderKind(for: URL(fileURLWithPath: "/a/x.cr2")), .libraw)
        XCTAssertEqual(RawFileIdentity.decoderKind(for: URL(fileURLWithPath: "/a/x.nef")), .libraw)
        XCTAssertEqual(RawFileIdentity.decoderKind(for: URL(fileURLWithPath: "/a/x.jpg")), .imageIO)
        XCTAssertEqual(RawFileIdentity.decoderKind(for: URL(fileURLWithPath: "/a/x.JPEG")), .imageIO)
        XCTAssertEqual(RawFileIdentity.decoderKind(for: URL(fileURLWithPath: "/a/x.png")), .imageIO)
        XCTAssertEqual(RawFileIdentity.decoderKind(for: URL(fileURLWithPath: "/a/x.heic")), .imageIO)
        XCTAssertEqual(RawFileIdentity.decoderKind(for: URL(fileURLWithPath: "/a/x.heif")), .imageIO)
        XCTAssertNil(RawFileIdentity.decoderKind(for: URL(fileURLWithPath: "/a/x.txt")))
    }

    func testUnsupportedAndCaseInsensitive() {
        XCTAssertFalse(RawFileIdentity.isSupported(URL(fileURLWithPath: "/a/x.txt")))
        XCTAssertTrue(RawFileIdentity.isSupported(URL(fileURLWithPath: "/a/x.CR2")))
    }

    func testFileIDIsStandardizedPath() {
        let url = URL(fileURLWithPath: "/Users/x/../x/photo.cr2")
        XCTAssertEqual(RawFileIdentity.fileID(for: url), "/Users/x/photo.cr2")
    }

    func testFileIDResolvesSymlinksSoAnAliasIsNotADuplicate() throws {
        let dir = try FileManager.default.url(for: .itemReplacementDirectory,
                                              in: .userDomainMask, appropriateFor: URL(fileURLWithPath: "/tmp"),
                                              create: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.cr2")
        try Data(repeating: 7, count: 16).write(to: target)
        let link = dir.appendingPathComponent("link.cr2")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(RawFileIdentity.fileID(for: link), RawFileIdentity.fileID(for: target),
                        "a symlinked alias must share the target's identity or it enters a session twice")
    }
}
