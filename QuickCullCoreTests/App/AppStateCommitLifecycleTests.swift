import Foundation
import XCTest
@testable import QuickCullCore

/// Lifecycle guarantees for commit/move completions that land after the
/// session they were started against has been torn down or replaced, plus the
/// failure-notification revision the UI observes.
@MainActor
final class AppStateCommitLifecycleTests: XCTestCase {
    private var tempDir: URL!
    private var cache: ImageCacheStore!

    override func setUp() async throws {
        tempDir = try TestFixtures.makeTempDir(name: "commit-lifecycle")
        cache = ImageCacheStore(baseURL: tempDir.appendingPathComponent("cache", isDirectory: true))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private func waitForScrubbing(_ state: AppState) async {
        let reached = await waitUntil { state.phase == .scrubbing }
        XCTAssertTrue(reached, "never reached scrubbing")
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func makeFlaggedState(trasher: Trashing) async throws -> (AppState, URL, URL, StubTrasher) {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let stub = trasher as! StubTrasher
        let state = AppState(decoder: StubDecoder(), cache: cache, trasher: trasher)
        state.importFiles(urls: [a, b])
        await waitForScrubbing(state)
        await state.thumbWindow?.waitUntilSettled()
        XCTAssertNotNil(state.thumbWindow, "precondition: windows installed")
        state.handle(.toggleFlag(.red))
        return (state, a, b, stub)
    }

    /// `File ▸ New Session` is disabled while a commit runs (the command reads
    /// a nil focused value), but the state machine must hold even if the
    /// teardown happens anyway: the in-flight completion owns no state.
    func testNewSessionDuringInFlightCommitKeepsStateClean() async throws {
        let trasher = StubTrasher()
        trasher.gate = DispatchSemaphore(value: 0)
        let (state, _, _, stub) = try await makeFlaggedState(trasher: trasher)

        state.requestCommit()
        let commit = Task { await state.confirmCommit() }
        let inFlight = await waitUntil { state.isCommitting }
        XCTAssertTrue(inFlight, "precondition: commit in flight")

        state.startNewSession()
        guard let gate = stub.gate else { return XCTFail("missing gate") }
        gate.signal()
        await commit.value

        XCTAssertEqual(state.phase, .empty)
        XCTAssertNil(state.session)
        XCTAssertNil(state.thumbWindow,
                     "a stale commit completion must not reinstall windows for the discarded session")
        XCTAssertNil(state.gridThumbs)
        XCTAssertNil(state.displayImages)
        XCTAssertFalse(state.isCommitting)
        XCTAssertTrue(state.commitFailures.isEmpty)
        XCTAssertEqual(stub.trashed.count, 1, "the commit itself still ran to completion")
    }

    private final class GatedMover: Moving, @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _moved: [String] = []
        var moved: [String] { lock.lock(); defer { lock.unlock() }; return _moved }
        func move(from: URL, to: URL) throws {
            gate.wait()
            lock.lock(); defer { lock.unlock() }
            _moved.append(from.path)
        }
    }

    func testNewSessionDuringInFlightMoveKeepsStateClean() async throws {
        let mover = GatedMover()
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let dest = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let state = AppState(decoder: StubDecoder(), cache: cache,
                             trasher: StubTrasher(), mover: mover)
        state.importFiles(urls: [a, b])
        await waitForScrubbing(state)
        await state.thumbWindow?.waitUntilSettled()
        state.handle(.toggleFlag(.red))

        state.requestMove(to: dest)
        let move = Task { await state.confirmMove() }
        let inFlight = await waitUntil { state.isMoving }
        XCTAssertTrue(inFlight, "precondition: move in flight")

        state.startNewSession()
        mover.gate.signal()
        await move.value

        XCTAssertEqual(state.phase, .empty)
        XCTAssertNil(state.session)
        XCTAssertNil(state.thumbWindow,
                     "a stale move completion must not reinstall windows for the discarded session")
        XCTAssertNil(state.displayImages)
        XCTAssertFalse(state.isMoving)
        XCTAssertTrue(state.moveFailures.isEmpty)
        XCTAssertEqual(mover.moved.count, 1, "the move itself still ran to completion")
    }

    /// Two commits that each fail on one file leave `commitFailures.count` at
    /// 1; the revision is what lets the UI announce the second failure.
    func testRepeatedEqualFailureCountsBumpCommitRevision() async throws {
        let trasher = StubTrasher()
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        trasher.failIDs = [a.path]
        let state = AppState(decoder: StubDecoder(), cache: cache, trasher: trasher)
        state.importFiles(urls: [a, b])
        await waitForScrubbing(state)
        state.handle(.toggleFlag(.red))   // flag a

        state.requestCommit()
        await state.confirmCommit()
        XCTAssertEqual(state.commitFailures.count, 1)
        XCTAssertEqual(state.commitFailureRevision, 1)
        XCTAssertEqual(state.session?.flaggedCount, 1, "a failed file keeps its flag")

        // Same single failure again: count unchanged, revision must advance.
        state.requestCommit()
        await state.confirmCommit()
        XCTAssertEqual(state.commitFailures.count, 1)
        XCTAssertEqual(state.commitFailureRevision, 2,
                       "count-based observation would miss this second failure")
        XCTAssertEqual(state.session?.flaggedCount, 1)
    }

    /// A successful commit also advances the revision (the UI only reacts when
    /// the failure list is non-empty), and a new session clears the list.
    func testCommitRevisionAdvancesOnSuccessAndFailuresClearOnNewSession() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let state = AppState(decoder: StubDecoder(), cache: cache, trasher: StubTrasher())
        state.importFiles(urls: [a, b])
        await waitForScrubbing(state)
        state.handle(.toggleFlag(.red))

        state.requestCommit()
        await state.confirmCommit()
        XCTAssertTrue(state.commitFailures.isEmpty)
        XCTAssertEqual(state.commitFailureRevision, 1)
        XCTAssertEqual(state.session?.count, 1)

        state.startNewSession()
        XCTAssertTrue(state.commitFailures.isEmpty)
        XCTAssertNil(state.session)
    }
}
