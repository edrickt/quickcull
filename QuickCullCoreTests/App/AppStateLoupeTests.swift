import Foundation
import XCTest
@testable import QuickCullCore

/// `AppState.canActivateLoupe` is the single predicate behind both
/// `setLoupeActive` and the app-wide Space monitor. The residual bug the
/// round-3 fix left: the monitor ignored `isMoving`/`isCommitting` and a
/// filtered-empty projection, so Space was still swallowed when the loupe could
/// not start. These tests pin the predicate for every state the earlier fix
/// missed and keep the normal scrub path consumed.
@MainActor
final class AppStateLoupeTests: XCTestCase {
    private var tempDir: URL!
    private var cache: ImageCacheStore!

    override func setUp() async throws {
        tempDir = try TestFixtures.makeTempDir(name: "loupe")
        cache = ImageCacheStore(baseURL: tempDir.appendingPathComponent("cache", isDirectory: true))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private final class GatedMover: Moving, @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        func move(from: URL, to: URL) throws { gate.wait() }
    }

    private func makeState(trasher: Trashing = StubTrasher(),
                           mover: Moving = FileManagerMover()) -> AppState {
        AppState(decoder: StubDecoder(), cache: cache, trasher: trasher, mover: mover)
    }

    private func waitForScrubbing(_ state: AppState) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, state.phase != .scrubbing {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(state.phase, .scrubbing, "never reached scrubbing")
    }

    private func importTwo(_ state: AppState) async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        state.importFiles(urls: [a, b])
        await waitForScrubbing(state)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    func testCanActivateLoupeWhileScrubbing() async throws {
        let state = makeState()
        try await importTwo(state)

        XCTAssertTrue(state.canActivateLoupe)
        state.setLoupeActive(true)
        XCTAssertTrue(state.isLoupeActive, "normal scrub keeps Space consumed")
        state.setLoupeActive(false)
        XCTAssertFalse(state.isLoupeActive)
    }

    func testCanActivateLoupeIsFalseInGrid() async throws {
        let state = makeState()
        try await importTwo(state)
        state.setViewMode(.grid)

        XCTAssertFalse(state.canActivateLoupe)
        state.setLoupeActive(true)
        XCTAssertFalse(state.isLoupeActive, "the predicate and setLoupeActive agree in grid")
    }

    func testCanActivateLoupeIsFalseForAFilteredEmptyProjection() async throws {
        let state = makeState()
        try await importTwo(state)
        state.setFilter(.red)               // nothing flagged: placeholder, no image

        XCTAssertEqual(state.session?.files.isEmpty, true, "precondition: filtered-empty")
        XCTAssertFalse(state.canActivateLoupe)
        state.setLoupeActive(true)
        XCTAssertFalse(state.isLoupeActive, "there is no image to magnify, so no loupe may activate")
    }

    func testCanActivateLoupeIsFalseDuringCommit() async throws {
        let trasher = StubTrasher()
        let gate = DispatchSemaphore(value: 0)
        trasher.gate = gate
        let state = makeState(trasher: trasher)
        try await importTwo(state)
        state.handle(.toggleFlag(.red))
        XCTAssertTrue(state.requestCommit())
        let commit = Task { await state.confirmCommit() }
        let committing = await waitUntil { state.isCommitting }
        XCTAssertTrue(committing, "precondition: commit in flight")

        XCTAssertFalse(state.canActivateLoupe)
        state.setLoupeActive(true)
        XCTAssertFalse(state.isLoupeActive, "the predicate and setLoupeActive agree while committing")

        gate.signal()
        await commit.value
        XCTAssertTrue(state.canActivateLoupe, "the loupe is possible again once the commit settles")
    }

    func testCanActivateLoupeIsFalseDuringMove() async throws {
        let mover = GatedMover()
        let dest = try TestFixtures.makeTempDir(name: "loupe-move-dest")
        defer { try? FileManager.default.removeItem(at: dest) }
        let state = makeState(mover: mover)
        try await importTwo(state)
        state.handle(.toggleFlag(.red))
        XCTAssertTrue(state.requestMove(to: dest))
        let move = Task { await state.confirmMove() }
        let moving = await waitUntil { state.isMoving }
        XCTAssertTrue(moving, "precondition: move in flight")

        XCTAssertFalse(state.canActivateLoupe)
        state.setLoupeActive(true)
        XCTAssertFalse(state.isLoupeActive, "the predicate and setLoupeActive agree while moving")

        mover.gate.signal()
        await move.value
        XCTAssertTrue(state.canActivateLoupe, "the loupe is possible again once the move settles")
    }
}
