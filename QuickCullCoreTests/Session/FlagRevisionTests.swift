import Foundation
import XCTest
@testable import QuickCullCore

/// `Session.flagRevision` — the monotonic counter the filmstrip keys its
/// cells by. Every flag mutation bumps it exactly once; index and filter
/// changes must NOT bump it (they don't alter flag state).
@MainActor
final class FlagRevisionTests: XCTestCase {
    private func makeSession(_ names: [String] = ["a.cr2", "b.cr2", "c.cr2", "d.cr2"]) -> Session {
        Session(files: TestFixtures.makeFiles(names))
    }

    func testStartsAtZeroAndMoveAndIndexDoNotBump() {
        let session = makeSession()
        XCTAssertEqual(session.flagRevision, 0)
        session.move(by: 1)
        session.setIndex(2)
        XCTAssertEqual(session.flagRevision, 0, "scrubbing must not re-key the strip via flagRevision")
    }

    func testToggleFlagBumpsOnce() {
        let session = makeSession()
        session.toggleFlag(color: .red)
        XCTAssertEqual(session.flagRevision, 1)
        let after = session.flagRevision
        // Same color again clears the flag — still a flag mutation.
        session.toggleFlag(color: .red)
        XCTAssertEqual(session.flagRevision, after + 1)
    }

    func testToggleFlagsBumpsOncePerCallNotPerID() {
        let session = makeSession()
        let ids = Set(session.allFiles.map(\.id))
        session.toggleFlags(ids: ids, color: .green)
        XCTAssertEqual(session.flagRevision, 1, "batch toggle is one flag mutation")
    }

    func testRemoveBumps() {
        let session = makeSession()
        session.toggleFlag(color: .yellow)
        let flagged = session.flaggedFiles(.yellow)
        session.remove(flagged)
        XCTAssertEqual(session.flagRevision, 2, "remove clears flags — a flag mutation")
    }

    func testSetFilterDoesNotBump() {
        let session = makeSession()
        session.toggleFlag(color: .red)
        let after = session.flagRevision
        session.setFilter(.red)
        XCTAssertEqual(session.flagRevision, after, "filter changes don't alter flag state")
    }

    func testIDPositionsTrackRemoval() {
        let session = makeSession(["a.cr2", "b.cr2", "c.cr2"])
        session.remove([session.allFiles[0]])
        XCTAssertEqual(session.allFiles.map(\.id), TestFixtures.makeFiles(["b.cr2", "c.cr2"]).map(\.id))
        // Position map rebuilt: first survivor lookup must not misindex.
        session.toggleFlag(color: .red)
        session.setFilter(.red)
        XCTAssertEqual(session.currentFile.id, TestFixtures.makeFiles(["b.cr2"]).first?.id)
    }
}
