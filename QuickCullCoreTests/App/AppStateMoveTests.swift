import Foundation
import XCTest
@testable import QuickCullCore

@MainActor
final class AppStateMoveTests: XCTestCase {
    private var tempDir: URL!
    private var cache: ImageCacheStore!
    override func setUp() async throws {
        tempDir = try TestFixtures.makeTempDir(name: "move-state")
        cache = ImageCacheStore(baseURL: tempDir.appendingPathComponent("cache", isDirectory: true))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private func makeState(mover: Moving = StubMover()) -> AppState {
        AppState(decoder: StubDecoder(), cache: cache, trasher: StubTrasher(), mover: mover)
    }
    private func waitForScrubbing(_ s: AppState) async {
        for _ in 0..<200 { if s.phase == .scrubbing { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("never scrubbing")
    }
    // StubMover with gate and failIDs like StubTrasher
    private class StubMover: Moving, @unchecked Sendable {
        var failIDs: Set<String> = []
        var gate: DispatchSemaphore?
        var moved: [URL] = []
        func move(from: URL, to: URL) throws {
            if let g = gate { g.wait() }
            if failIDs.contains(RawFileIdentity.fileID(for: from)) { throw NSError(domain: "t", code: 1) }
            moved.append(from)
        }
    }

    func testRequestAndCancelMove() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let s = makeState()
        s.importFiles(urls: [a]); await waitForScrubbing(s)
        s.handle(.toggleFlag(.red))
        let dest = URL(fileURLWithPath: "/tmp/dest")
        s.requestMove(to: dest)
        XCTAssertEqual(s.pendingMoveCount, 1)
        XCTAssertEqual(s.pendingMoveDestination, dest)
        s.cancelMove()
        XCTAssertEqual(s.pendingMoveCount, 0)
        XCTAssertNil(s.pendingMoveDestination)
    }

    func testConfirmMoveRemovesSucceededAndKeepsFailed() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let mover = StubMover(); mover.failIDs = [RawFileIdentity.fileID(for: a)]
        let s = makeState(mover: mover)
        s.importFiles(urls: [a,b]); await waitForScrubbing(s)
        s.handle(.toggleFlag(.red)); s.handle(.next); s.handle(.toggleFlag(.red))
        let dest = URL(fileURLWithPath: "/tmp/dest2")
        s.requestMove(to: dest)
        await s.confirmMove()
        XCTAssertEqual(s.session?.count, 1)
        XCTAssertEqual(s.session?.flaggedCount, 1)
        XCTAssertEqual(s.moveFailures.count, 1)
        XCTAssertEqual(s.pendingMoveCount, 0)
        XCTAssertNil(s.pendingMoveDestination)
        XCTAssertFalse(s.isMoving)
    }

    func testConfirmMoveEmptiesSessionResetsPhase() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let s = makeState()
        s.importFiles(urls: [a]); await waitForScrubbing(s)
        s.handle(.toggleFlag(.red))
        s.requestMove(to: URL(fileURLWithPath: "/tmp/dest3"))
        await s.confirmMove()
        XCTAssertNil(s.session)
        XCTAssertEqual(s.phase, .empty)
        XCTAssertEqual(s.viewMode, .scrub)
    }

    func testIsMovingTrueDuringMove() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let mover = StubMover()
        let gate = DispatchSemaphore(value: 0)
        mover.gate = gate
        let s = makeState(mover: mover)
        s.importFiles(urls: [a]); await waitForScrubbing(s)
        s.handle(.toggleFlag(.red))
        s.requestMove(to: URL(fileURLWithPath: "/tmp/dest4"))
        let task = Task { await s.confirmMove() }
        var observed = false
        for _ in 0..<100 {
            if s.isMoving { observed = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(observed)
        gate.signal()
        await task.value
        XCTAssertFalse(s.isMoving)
    }

    func testStartNewSessionClearsMoveState() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let s = makeState()
        s.importFiles(urls: [a]); await waitForScrubbing(s)
        s.handle(.toggleFlag(.red))
        s.requestMove(to: URL(fileURLWithPath: "/tmp/d"))
        s.moveFailures = [MoveOutcome(file: SessionFile(url: a), error: NSError(domain: "t", code: 1))]
        s.startNewSession()
        XCTAssertTrue(s.moveFailures.isEmpty)
        XCTAssertEqual(s.pendingMoveCount, 0)
        XCTAssertNil(s.pendingMoveDestination)
        XCTAssertFalse(s.isMoving)
    }

    func testImportClearsMoveState() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let s = makeState()
        s.importFiles(urls: [a]); await waitForScrubbing(s)
        s.requestMove(to: URL(fileURLWithPath: "/tmp/d2"))
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        s.importFiles(urls: [b]); await waitForScrubbing(s)
        XCTAssertEqual(s.pendingMoveCount, 0)
        XCTAssertNil(s.pendingMoveDestination)
        XCTAssertTrue(s.moveFailures.isEmpty)
    }

    func testMoveBlocksViewModeAndHandleWhileMoving() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let mover = StubMover()
        let gate = DispatchSemaphore(value: 0)
        mover.gate = gate
        let s = makeState(mover: mover)
        s.importFiles(urls: [a,b]); await waitForScrubbing(s)
        s.handle(.toggleFlag(.red))
        s.requestMove(to: URL(fileURLWithPath: "/tmp/d5"))
        let task = Task { await s.confirmMove() }
        // wait until isMoving
        for _ in 0..<100 { if s.isMoving { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        s.setViewMode(.grid)
        XCTAssertEqual(s.viewMode, .scrub) // blocked
        let indexBefore = s.session?.currentIndex
        s.handle(.next)
        XCTAssertEqual(s.session?.currentIndex, indexBefore, "scrub keys are blocked while moving")
        gate.signal()
        await task.value
    }

    func testUnsupportedImportClearsMoveState() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let s = makeState()
        s.importFiles(urls: [a]); await waitForScrubbing(s)
        s.handle(.toggleFlag(.red))
        s.requestMove(to: URL(fileURLWithPath: "/tmp/d"))
        XCTAssertNotNil(s.pendingMoveDestination)
        s.importFiles(urls: [URL(fileURLWithPath: "/tmp/x.txt")]) // unsupported
        XCTAssertNil(s.pendingMoveDestination)
        XCTAssertEqual(s.pendingMoveCount, 0)
    }
}
