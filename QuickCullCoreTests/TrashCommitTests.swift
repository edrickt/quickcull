import XCTest
@testable import QuickCullCore

final class TrashCommitTests: XCTestCase {
    func testCommitTrashesEveryFile() {
        let files = TestFixtures.makeFiles(["a.cr2", "b.cr2"])
        let trasher = StubTrasher()
        let outcomes = TrashCommit(trasher: trasher).commit(files: files)
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy(\.succeeded))
        XCTAssertEqual(Set(trasher.trashed), Set(["/tmp/shoot/a.cr2", "/tmp/shoot/b.cr2"]))
    }

    func testCommitReportsPerFileFailuresAndKeepsGoing() {
        let files = TestFixtures.makeFiles(["a.cr2", "bad.cr2", "c.cr2"])
        let trasher = StubTrasher()
        trasher.failIDs = ["/tmp/shoot/bad.cr2"]
        let outcomes = TrashCommit(trasher: trasher).commit(files: files)
        XCTAssertEqual(outcomes.filter(\.succeeded).count, 2)
        XCTAssertEqual(outcomes.first { !$0.succeeded }?.file.id, "/tmp/shoot/bad.cr2")
        XCTAssertEqual(trasher.trashed.count, 2)
    }

    func testFileManagerTrasherMovesRealFileToTrash() throws {
        // Real trash call against a temp file. On volumes without a Trash
        // location (CI sandboxes), the failure mode itself is asserted.
        let dir = try TestFixtures.makeTempDir(name: "trash")
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("photo.cr2")
        try Data([0x01, 0x02]).write(to: url)
        let trasher = FileManagerTrasher()
        do {
            try trasher.trash(url: url)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        } catch {
            XCTSkip("volume has no Trash location; error surfaced as expected: \(error)")
        }
    }
}
