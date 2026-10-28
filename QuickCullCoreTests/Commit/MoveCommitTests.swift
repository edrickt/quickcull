import XCTest
@testable import QuickCullCore

final class MoveCommitTests: XCTestCase {
    func testAutoRenamedDestinationNoCollision() throws {
        let dir = try TestFixtures.makeTempDir(name: "move-no-coll")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/a.jpg"))
        let dest = MoveCommit(mover: FileManagerMover()).autoRenamedDestination(for: a, in: dir)
        XCTAssertEqual(dest.lastPathComponent, "a.jpg")
    }
    func testAutoRenamedDestinationCollisionAddsSuffix() throws {
        let dir = try TestFixtures.makeTempDir(name: "move-coll")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.jpg"))
        let a = SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/a.jpg"))
        let dest = MoveCommit(mover: FileManagerMover()).autoRenamedDestination(for: a, in: dir)
        XCTAssertEqual(dest.lastPathComponent, "a 1.jpg")
        try Data("y".utf8).write(to: dir.appendingPathComponent("a 1.jpg"))
        let dest2 = MoveCommit(mover: FileManagerMover()).autoRenamedDestination(for: a, in: dir)
        XCTAssertEqual(dest2.lastPathComponent, "a 2.jpg")
    }
    func testAutoRenamedPreservesExtensionCase() throws {
        let dir = try TestFixtures.makeTempDir(name: "move-case")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("IMG.JPG"))
        let f = SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/IMG.JPG"))
        let dest = MoveCommit(mover: FileManagerMover()).autoRenamedDestination(for: f, in: dir)
        XCTAssertEqual(dest.lastPathComponent, "IMG 1.JPG")
    }
    func testAutoRenamedNoExtension() throws {
        let dir = try TestFixtures.makeTempDir(name: "move-noext")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("README"))
        let f = SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/README"))
        let dest = MoveCommit(mover: FileManagerMover()).autoRenamedDestination(for: f, in: dir)
        XCTAssertEqual(dest.lastPathComponent, "README 1")
    }
    func testCommitMovesFilesAndAutoRenames() throws {
        let srcDir = try TestFixtures.makeTempDir(name: "move-src")
        let dstDir = try TestFixtures.makeTempDir(name: "move-dst")
        defer { try? FileManager.default.removeItem(at: srcDir); try? FileManager.default.removeItem(at: dstDir) }
        let srcURL = srcDir.appendingPathComponent("a.jpg")
        try Data("src".utf8).write(to: srcURL)
        try Data("existing".utf8).write(to: dstDir.appendingPathComponent("a.jpg"))
        let file = SessionFile(url: srcURL)
        let outcomes = MoveCommit(mover: FileManagerMover()).commit(files: [file], to: dstDir)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertTrue(outcomes[0].succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("a 1.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: srcURL.path))
    }
    func testCommitReportsFailurePerFile() throws {
        struct FailMover: Moving { func move(from: URL, to: URL) throws { throw NSError(domain: "t", code: 1) } }
        let file = SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/a.jpg"))
        let outcomes = MoveCommit(mover: FailMover()).commit(files: [file], to: URL(fileURLWithPath: "/tmp/dst"))
        XCTAssertFalse(outcomes[0].succeeded)
        XCTAssertNotNil(outcomes[0].error)
    }
    func testCommitSourceNotFoundFails() throws {
        let dst = try TestFixtures.makeTempDir(name: "move-nf")
        defer { try? FileManager.default.removeItem(at: dst) }
        let file = SessionFile(url: URL(fileURLWithPath: "/nonexistent/a.jpg"))
        let outcomes = MoveCommit(mover: FileManagerMover()).commit(files: [file], to: dst)
        XCTAssertFalse(outcomes[0].succeeded)
    }

    func testMoveIntoTheSourceFolderIsANoOp() throws {
        let dir = try TestFixtures.makeTempDir(name: "move-self")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.jpg")
        try Data("src".utf8).write(to: source)
        let file = SessionFile(url: source)
        let outcomes = MoveCommit(mover: FileManagerMover()).commit(files: [file], to: dir)
        XCTAssertTrue(outcomes[0].succeeded)
        // Nothing renamed in place, and no "a 1.jpg" copy appeared.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.jpg"])
        XCTAssertEqual(try Data(contentsOf: source), Data("src".utf8))
    }

    /// The same folder reached through a symlink is the same folder: spelling is
    /// not identity. Comparing paths renamed every original in place, because the
    /// collision suffix then found the file itself at the destination.
    func testMoveIntoTheSourceFolderThroughASymlinkIsANoOp() throws {
        let dir = try TestFixtures.makeTempDir(name: "move-symlink-target")
        let linkParent = try TestFixtures.makeTempDir(name: "move-symlink-parent")
        defer { try? FileManager.default.removeItem(at: dir)
                try? FileManager.default.removeItem(at: linkParent) }
        let link = linkParent.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        let source = dir.appendingPathComponent("a.jpg")
        try Data("src".utf8).write(to: source)

        let outcomes = MoveCommit(mover: FileManagerMover())
            .commit(files: [SessionFile(url: source)], to: link)

        XCTAssertTrue(outcomes[0].succeeded)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.jpg"],
                       "no in-place rename through the alias")
        XCTAssertEqual(try Data(contentsOf: source), Data("src".utf8))
    }

    /// A destination spelled `..`-relative or with a trailing slash is still the
    /// same directory (the picker can return either shape).
    func testMoveIntoTheSourceFolderWithAnotherSpellingIsANoOp() throws {
        let parent = try TestFixtures.makeTempDir(name: "move-spelling")
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("a.jpg")
        try Data("src".utf8).write(to: source)

        let dotted = dir.appendingPathComponent("../shoot")
        let outcomes = MoveCommit(mover: FileManagerMover())
            .commit(files: [SessionFile(url: source)], to: dotted)
        XCTAssertTrue(outcomes[0].succeeded)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.jpg"])
    }
}
