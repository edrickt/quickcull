import Observation
import XCTest
@testable import QuickCullCore

@MainActor
final class SessionTests: XCTestCase {
    func testMoveClampsAtEdges() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.move(by: 10)
        XCTAssertEqual(session.currentIndex, 2)
        session.move(by: -10)
        XCTAssertEqual(session.currentIndex, 0)
    }

    func testToggleFlagOnAndOff() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2"]))
        session.toggleFlag()
        XCTAssertEqual(session.flaggedCount, 1)
        XCTAssertTrue(session.isFlagged(session.currentFile))
        session.toggleFlag()
        XCTAssertEqual(session.flaggedCount, 0)
    }

    func testFlagsKeyedByIdSurviveIndexChange() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.toggleFlag()          // flags index 0
        session.move(by: 1)
        session.toggleFlag()          // flags index 1
        session.move(by: -1)
        XCTAssertTrue(session.isFlagged(session.files[0]))
        XCTAssertEqual(session.flaggedCount, 2)
    }

    func testRemoveTrashedFilesClearsFlagsAndClampsIndex() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2", "d.cr2"]))
        session.setIndex(3)
        session.remove([session.files[3]])
        XCTAssertEqual(session.count, 3)
        XCTAssertEqual(session.currentIndex, 2)
        XCTAssertEqual(session.flaggedCount, 0)
    }

    func testRemoveAllLeavesEmptySession() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2"]))
        session.remove([session.files[0]])
        XCTAssertTrue(session.isEmpty)
    }

    func testRemoveBeforeCurrentShiftsIndex() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2", "d.cr2"]))
        session.setIndex(2)   // current = c
        session.remove([session.files[0], session.files[3]])   // remove a and d
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.currentIndex, 1)                // still on c
        XCTAssertEqual(session.files[session.currentIndex].url.lastPathComponent, "c.cr2")
    }

    func testRemoveBeforeCurrentKeepsPosition() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.setIndex(1)   // current = b
        session.remove([session.files[0]])   // remove a
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.currentIndex, 0)                // still on b
        XCTAssertEqual(session.files[session.currentIndex].url.lastPathComponent, "b.cr2")
    }

    func testFlaggedFilesReturnsInOrder() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.toggleFlag()
        session.move(by: 1)
        session.toggleFlag()
        XCTAssertEqual(session.flaggedFiles.map(\.id),
                       [session.files[0].id, session.files[1].id])
    }

    func testCurrentIndexChangeIsObservable() async {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2"]))
        var fired = false
        withObservationTracking {
            _ = session.currentIndex
        } onChange: {
            fired = true
        }
        session.move(by: 1)
        // onChange is delivered on a later runloop turn.
        for _ in 0..<10 where !fired {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(fired, "currentIndex change must fire observation (filmstrip border depends on it)")
    }

    func testFlagChangesAreObservable() async {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2"]))
        var fired = false
        withObservationTracking {
            _ = session.isFlagged(session.files[0])
        } onChange: {
            fired = true
        }
        session.toggleFlag()
        for _ in 0..<10 where !fired {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(fired, "flag changes must fire observation (badges depend on it)")
    }

}
