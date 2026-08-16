import XCTest
@testable import QuickCullCore

@MainActor
final class SessionTests: XCTestCase {
    private func makeFiles(_ names: [String]) -> [SessionFile] {
        names.map { SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/\($0)")) }
    }

    func testMoveClampsAtEdges() {
        let session = Session(files: makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.move(by: 10)
        XCTAssertEqual(session.currentIndex, 2)
        session.move(by: -10)
        XCTAssertEqual(session.currentIndex, 0)
    }

    func testToggleFlagOnAndOff() {
        let session = Session(files: makeFiles(["a.cr2", "b.cr2"]))
        session.toggleFlag()
        XCTAssertEqual(session.flaggedCount, 1)
        XCTAssertTrue(session.isFlagged(session.currentFile))
        session.toggleFlag()
        XCTAssertEqual(session.flaggedCount, 0)
    }

    func testFlagsKeyedByIdSurviveIndexChange() {
        let session = Session(files: makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.toggleFlag()          // flags index 0
        session.move(by: 1)
        session.toggleFlag()          // flags index 1
        session.move(by: -1)
        XCTAssertTrue(session.isFlagged(session.files[0]))
        XCTAssertEqual(session.flaggedCount, 2)
    }

    func testRemoveTrashedFilesClearsFlagsAndClampsIndex() {
        let session = Session(files: makeFiles(["a.cr2", "b.cr2", "c.cr2", "d.cr2"]))
        session.setIndex(3)
        session.remove([session.files[3]])
        XCTAssertEqual(session.count, 3)
        XCTAssertEqual(session.currentIndex, 2)
        XCTAssertEqual(session.flaggedCount, 0)
    }

    func testRemoveAllLeavesEmptySession() {
        let session = Session(files: makeFiles(["a.cr2"]))
        session.remove([session.files[0]])
        XCTAssertTrue(session.isEmpty)
    }

    func testRemoveBeforeCurrentShiftsIndex() {
        let session = Session(files: makeFiles(["a.cr2", "b.cr2", "c.cr2", "d.cr2"]))
        session.setIndex(2)   // current = c
        session.remove([session.files[0], session.files[3]])   // remove a and d
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.currentIndex, 1)                // still on c
        XCTAssertEqual(session.files[session.currentIndex].url.lastPathComponent, "c.cr2")
    }

    func testRemoveBeforeCurrentKeepsPosition() {
        let session = Session(files: makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.setIndex(1)   // current = b
        session.remove([session.files[0]])   // remove a
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.currentIndex, 0)                // still on b
        XCTAssertEqual(session.files[session.currentIndex].url.lastPathComponent, "b.cr2")
    }

    func testFlaggedFilesReturnsInOrder() {
        let session = Session(files: makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.toggleFlag()
        session.move(by: 1)
        session.toggleFlag()
        XCTAssertEqual(session.flaggedFiles.map(\.id),
                       [session.files[0].id, session.files[1].id])
    }
}
