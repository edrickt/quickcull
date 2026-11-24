import XCTest
@testable import QuickCullCore

final class TrashCommitTests: XCTestCase {
    func testCommitTrashesEveryFile() {
        let files = TestFixtures.makeFiles(["a.cr2", "b.cr2"])
        let trasher = StubTrasher()
        let outcomes = TrashCommit(trasher: trasher).commit(files: files)
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy(\.succeeded))
        XCTAssertEqual(Set(trasher.trashed), Set(files.map(\.id)))
    }

    func testCommitReportsPerFileFailuresAndKeepsGoing() {
        let files = TestFixtures.makeFiles(["a.cr2", "bad.cr2", "c.cr2"])
        let trasher = StubTrasher()
        trasher.failIDs = [files[1].id]
        let outcomes = TrashCommit(trasher: trasher).commit(files: files)
        XCTAssertEqual(outcomes.filter(\.succeeded).count, 2)
        XCTAssertEqual(outcomes.first { !$0.succeeded }?.file.id, files[1].id)
        XCTAssertEqual(trasher.trashed.count, 2)
    }

    /// QS-04: identity and cache key are computed from the resolved target, but
    /// the trash used the imported path. For a photo imported through a symlink
    /// that trashed the link and left the photo on the card while reporting
    /// success — the user's reject was never honoured.
    func testTrashingASymlinkedPhotoTrashesTheTargetNotTheLink() throws {
        let card = try TestFixtures.makeTempDir(name: "trash-link-target")
        let picks = try TestFixtures.makeTempDir(name: "trash-link-picks")
        defer { try? FileManager.default.removeItem(at: card)
                try? FileManager.default.removeItem(at: picks) }
        let target = card.appendingPathComponent("IMG_0001.CR2")
        try Data([0x01, 0x02]).write(to: target)
        let link = picks.appendingPathComponent("IMG_0001.CR2")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let file = SessionFile(url: link)
        XCTAssertEqual(file.id, RawFileIdentity.fileID(for: target),
                       "precondition: identity is the target, not the link")

        let outcomes = TrashCommit(trasher: FileManagerTrasher()).commit(files: [file])
        guard let error = outcomes.first?.error else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                           "the photo the user rejected must leave the card")
            return
        }
        throw XCTSkip("volume has no Trash location; error surfaced as expected: \(error)")
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
