import Foundation
import XCTest
@testable import QuickCullCore

/// The import-failure banner's sentence. The classification is the point: a
/// cache/disk failure must not read as a broken photo, and an unsupported
/// format must not read as a decode failure.
final class ImportFailureSummaryTests: XCTestCase {
    private func outcome(_ name: String, _ error: DecodeError?) -> DecodeOutcome {
        DecodeOutcome(file: SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/\(name)")),
                      error: error)
    }

    func testEmptyFailuresProduceNoSentence() {
        XCTAssertEqual(ImportFailureSummary.text(for: []), "")
    }

    func testDecodeFailureKeepsTheOriginalWordingAndTheReason() {
        let text = ImportFailureSummary.text(for: [outcome("a.cr2", .cannotUnpack("unsupported data"))])
        XCTAssertEqual(text, "1 file could not be decoded (unsupported data): a.cr2")
    }

    func testCacheFailureNamesTheDiskNotThePhoto() {
        let text = ImportFailureSummary.text(for: [
            outcome("a.cr2", .cannotStorePreview("CacheError.cannotEncode")),
            outcome("b.cr2", .cannotStorePreview("CacheError.cannotEncode")),
        ])
        XCTAssertEqual(text, "2 files could not be cached (check free disk space): a.cr2, b.cr2")
        XCTAssertFalse(text.contains("decoded"), "a cache failure is not a decode failure")
    }

    func testUnsupportedFormatIsNotReportedAsADecodeFailure() {
        let text = ImportFailureSummary.text(for: [
            outcome("clip.mov", .cannotOpen(ImportFailureSummary.unsupportedMessage)),
        ])
        XCTAssertEqual(text, "1 file unsupported format: clip.mov")
    }

    func testMixedFailuresAreGroupedInAStableOrder() {
        let text = ImportFailureSummary.text(for: [
            outcome("a.cr2", .cannotProcess("demosaic failed")),
            outcome("b.txt", .cannotOpen(ImportFailureSummary.unsupportedMessage)),
            outcome("c.cr2", .cannotStorePreview("disk full")),
            outcome("d.cr2", .cannotStorePreview("disk full")),
        ])
        XCTAssertEqual(text, "1 file unsupported format, 1 file could not be decoded (demosaic failed), "
                             + "2 files could not be cached (check free disk space): "
                             + "a.cr2, b.txt, c.cr2, …")
    }

    func testLongListsAreTruncatedAfterThreeNames() {
        let failures = (0..<5).map { outcome("f\($0).cr2", .cannotUnpack("nope")) }
        let text = ImportFailureSummary.text(for: failures)
        XCTAssertEqual(text, "5 files could not be decoded (nope): f0.cr2, f1.cr2, f2.cr2, …")
    }

    /// The banner is fed `importFailures`, which never carries a nil error; the
    /// summary must still not invent one if it did.
    func testSuccessfulOutcomesContributeNothing() {
        XCTAssertEqual(ImportFailureSummary.text(for: [outcome("ok.cr2", nil)]), "")
    }
}
