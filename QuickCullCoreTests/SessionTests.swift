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

    // MARK: Filter

    func testDefaultFilterIsAll() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2"]))
        XCTAssertEqual(session.filter, .all)
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.totalCount, 2)
    }

    func testFlaggedFilterProjectsFlaggedOnly() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.toggleFlag()              // flag a
        session.move(by: 2)
        session.toggleFlag()              // flag c
        session.setFilter(.flagged)
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.files.map(\.url.lastPathComponent), ["a.cr2", "c.cr2"])
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "c.cr2")   // current kept
    }

    func testKeepersFilterProjectsUnflagged() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.toggleFlag()              // flag a
        session.setFilter(.keepers)       // a no longer matches
        XCTAssertEqual(session.files.map(\.url.lastPathComponent), ["b.cr2", "c.cr2"])
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "b.cr2")   // nearest match
    }

    func testFilterJumpTieResolvesForward() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2", "d.cr2"]))
        session.setIndex(2)               // current = c
        session.toggleFlag()              // flag c, so keepers excludes it
        session.setFilter(.keepers)       // b and d are equidistant
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "d.cr2")
    }

    func testFilterJumpPrefersNearestBackward() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2", "d.cr2", "e.cr2"]))
        session.setIndex(2)               // current = c
        session.toggleFlag()              // flag c
        session.move(by: 1)
        session.toggleFlag()              // flag d
        session.setIndex(2)               // current = c again
        session.setFilter(.keepers)       // b is nearer than e
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "b.cr2")
        session.setFilter(.flagged)       // back to flagged: c, current by id
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "c.cr2")
    }

    func testFilterMatchingNothingShowsEmpty() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2"]))
        session.setFilter(.flagged)       // nothing is flagged
        XCTAssertEqual(session.filter, .flagged)
        XCTAssertEqual(session.count, 0)
        XCTAssertTrue(session.isEmpty)
        XCTAssertEqual(session.currentIndex, 0)
    }

    func testFilterEmptyProjectionShowsEmpty() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2", "d.cr2", "e.cr2"]))
        session.setIndex(2)               // current = c
        session.toggleFlag()              // flag c
        session.setFilter(.flagged)       // [c], current = c
        session.toggleFlag()              // unflag c: projection empties -> All, current = c
        XCTAssertEqual(session.filter, .all)
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "c.cr2")
        session.setFilter(.flagged)       // still nothing flagged: empty placeholder
        XCTAssertEqual(session.filter, .flagged)
        XCTAssertEqual(session.count, 0)
        XCTAssertTrue(session.isEmpty)
    }

    // MARK: Filter interplay

    func testToggleFlagInFlaggedModeAdvances() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.toggleFlag()              // flag a
        session.move(by: 1)
        session.toggleFlag()              // flag b
        session.setFilter(.flagged)       // [a, b], current = b
        session.toggleFlag()              // unflag b: drops out, a takes over
        XCTAssertEqual(session.count, 1)
        XCTAssertEqual(session.files.map(\.url.lastPathComponent), ["a.cr2"])
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "a.cr2")
        XCTAssertTrue(session.isFlagged(session.currentFile))
    }

    func testToggleFlagInKeepersModeAdvances() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.toggleFlag()              // flag a
        session.setFilter(.keepers)       // [b, c], current = b
        session.toggleFlag()              // flag b: drops out, c takes over
        XCTAssertEqual(session.count, 1)
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "c.cr2")
        XCTAssertEqual(session.flaggedCount, 2)
    }

    func testUnflaggingLastVisibleResetsToAll() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2"]))
        session.toggleFlag()              // flag a
        session.setFilter(.flagged)       // [a]
        session.toggleFlag()              // unflag a: projection empties
        XCTAssertEqual(session.filter, .all)
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "a.cr2")  // kept by id
        XCTAssertEqual(session.flaggedCount, 0)
    }

    func testRemoveUnderKeepersFilterKeepsCurrent() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        let all = session.files
        session.toggleFlag()              // flag a
        session.setFilter(.keepers)       // [b, c], current = b
        session.remove([all[0]])          // trash flagged a (not visible)
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.files.map(\.url.lastPathComponent), ["b.cr2", "c.cr2"])
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "b.cr2")
        XCTAssertEqual(session.totalCount, 2)
    }

    func testRemoveAllVisibleUnderFlaggedFilterResetsToAll() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        let all = session.files
        session.toggleFlag()              // flag a
        session.move(by: 1)
        session.toggleFlag()              // flag b
        session.setFilter(.flagged)       // [a, b], current = b
        session.remove([all[0], all[1]])  // commit trashes both flagged
        XCTAssertEqual(session.filter, .all)
        XCTAssertEqual(session.count, 1)
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "c.cr2")  // first remaining
    }

    func testFlaggedFilesComesFromFullListUnderKeepers() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2"]))
        let all = session.files
        session.toggleFlag()              // flag a
        session.setFilter(.keepers)       // a is not visible
        XCTAssertEqual(session.flaggedFiles.map(\.id), [all[0].id])
    }

    func testRemoveCurrentLandsOnNextSurvivor() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2", "d.cr2"]))
        session.setIndex(2)               // current = c
        session.remove([session.files[2]])
        XCTAssertEqual(session.count, 3)
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "d.cr2")
    }

    func testRemoveCurrentAtEndLandsOnLastSurvivor() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.setIndex(2)               // current = c
        session.remove([session.files[2]])
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "b.cr2")
    }

    // MARK: Batch flag (grid)

    func testToggleFlagsSingleInAllMode() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        let changed = session.toggleFlags(ids: [session.files[1].id])
        XCTAssertFalse(changed, "All mode never changes projection size")
        XCTAssertEqual(session.count, 3)
        XCTAssertTrue(session.isFlagged(session.files[1]))
    }

    func testToggleFlagsBatchInAllMode() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        let ids = Set([session.files[0].id, session.files[2].id])
        let changed = session.toggleFlags(ids: ids)
        XCTAssertFalse(changed)
        XCTAssertEqual(session.flaggedCount, 2)
        XCTAssertTrue(session.isFlagged(session.files[0]))
        XCTAssertTrue(session.isFlagged(session.files[2]))
    }

    func testToggleFlagsBatchDropsOutInKeepersMode() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2", "d.cr2"]))
        session.setFilter(.keepers) // [a,b,c,d] all keepers, current a
        let ids = Set([session.files[0].id, session.files[1].id]) // flag a,b
        let changed = session.toggleFlags(ids: ids)
        XCTAssertTrue(changed)
        XCTAssertEqual(session.files.map(\.url.lastPathComponent), ["c.cr2", "d.cr2"])
        // current was a (now flagged, no longer keeper): nearest match is c (dropped forward)
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "c.cr2")
    }

    func testToggleFlagsEmptyProjectionFallsBackToAll() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2"]))
        session.setFilter(.keepers) // both keepers
        let ids = Set(session.files.map(\.id)) // flag everything
        let changed = session.toggleFlags(ids: ids)
        XCTAssertEqual(session.filter, .all)
        XCTAssertEqual(session.count, 2)
        XCTAssertTrue(changed)
    }

    func testToggleFlagsIgnoresUnknownIds() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2"]))
        let changed = session.toggleFlags(ids: ["nope"])
        XCTAssertFalse(changed)
        XCTAssertEqual(session.flaggedCount, 0)
    }

    func testToggleFlagsKeepsCurrentWhenStillVisible() {
        let session = Session(files: TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.setIndex(1) // b current
        session.setFilter(.keepers)
        let ids = Set([session.files[2].id]) // flag c only, b stays keeper
        let changed = session.toggleFlags(ids: ids)
        XCTAssertTrue(changed) // projection shrank from 3 to 2
        XCTAssertEqual(session.currentFile.url.lastPathComponent, "b.cr2")
        XCTAssertEqual(session.currentIndex, 1)
    }

}
