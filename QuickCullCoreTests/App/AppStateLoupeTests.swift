import Foundation
import XCTest
@testable import QuickCullCore

/// `AppState.canActivateLoupe` is the single predicate behind both
/// `setLoupeActive` and the app-wide Space monitor. Round 3 pinned where Space
/// must pass through (grid, filtered-empty projection, commit/move in flight);
/// the residual bugs those tests left are the loupe hold outliving the context
/// it started in, and the predicate claiming a "rendered image" while only
/// checking the projection. These tests pin both, plus the normal scrub path.
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
                           mover: Moving = FileManagerMover(),
                           earlyViewThreshold: Int = 50) -> AppState {
        AppState(decoder: StubDecoder(), cache: cache, trasher: trasher, mover: mover,
                 earlyViewThreshold: earlyViewThreshold)
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
        // The predicate now needs the rendered image, and the stub decoder's
        // tiny previews load asynchronously: settle both windows before any
        // activation assertion.
        await state.displayImages?.waitUntilSettled()
        await state.thumbWindow?.waitUntilSettled()
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
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

    // MARK: A hold must not outlive the context it started in

    /// The Space monitor only re-evaluates the hold on the next Space event, so
    /// a hold that started before the Trash dialog opened stayed set while the
    /// sheet swallowed the release. Cancelling the dialog then left the loupe
    /// showing with no key held.
    func testAPendingTrashDialogReleasesAHeldLoupe() async throws {
        let state = makeState()
        try await importTwo(state)
        state.handle(.toggleFlag(.red))
        state.setLoupeActive(true)
        XCTAssertTrue(state.isLoupeActive, "precondition: Space is held over a rendered image")

        XCTAssertTrue(state.requestCommit(color: .red))
        XCTAssertEqual(state.pendingCommitCount, 1)
        XCTAssertFalse(state.canActivateLoupe, "the dialog owns the destructive flow")
        XCTAssertFalse(state.isLoupeActive, "the hold must end when the dialog opens")

        state.cancelCommit()
        XCTAssertTrue(state.canActivateLoupe)
        XCTAssertFalse(state.isLoupeActive, "the loupe must not reappear without Space held")
    }

    /// Same for the Move dialog: its pending request ends the hold too.
    func testAPendingMoveDialogReleasesAHeldLoupe() async throws {
        let dest = try TestFixtures.makeTempDir(name: "loupe-hold-move-dest")
        defer { try? FileManager.default.removeItem(at: dest) }
        let state = makeState()
        try await importTwo(state)
        state.handle(.toggleFlag(.red))
        state.setLoupeActive(true)
        XCTAssertTrue(state.isLoupeActive, "precondition: Space is held over a rendered image")

        XCTAssertTrue(state.requestMove(to: dest, color: .red))
        XCTAssertEqual(state.pendingMoveCount, 1)
        XCTAssertFalse(state.isLoupeActive, "the hold must end when the dialog opens")

        state.cancelMove()
        XCTAssertTrue(state.canActivateLoupe)
        XCTAssertFalse(state.isLoupeActive, "the loupe must not reappear without Space held")
    }

    /// A filter that matches nothing takes the image away; releasing Space
    /// cannot be seen by the monitor there (no loupe can start), so the hold
    /// must be cleared at the transition or it comes back with the next filter.
    func testAnEmptyFilterProjectionReleasesAHeldLoupe() async throws {
        let state = makeState()
        try await importTwo(state)
        state.setLoupeActive(true)
        XCTAssertTrue(state.isLoupeActive, "precondition: Space is held over a rendered image")

        state.setFilter(.red)   // nothing flagged: the placeholder, no image
        XCTAssertEqual(state.session?.files.isEmpty, true, "precondition: filtered-empty")
        XCTAssertFalse(state.isLoupeActive, "no image, so no hold")

        state.setFilter(.all)
        await state.displayImages?.waitUntilSettled()
        await state.thumbWindow?.waitUntilSettled()
        XCTAssertTrue(state.canActivateLoupe)
        XCTAssertFalse(state.isLoupeActive,
                       "returning to All must not restore a loupe whose Space was released")
    }

    /// The predicate's documented "rendered image" is the viewer's own
    /// fallback chain. During the early-view background decode a photo
    /// navigated to before its preview lands shows the loading state: Space
    /// must pass through there instead of being swallowed for no loupe.
    func testCanActivateLoupeRequiresARenderedImage() async throws {
        let files = try (0..<40).map {
            try TestFixtures.makeRawFile(named: String(format: "l%03d.cr2", $0), in: tempDir)
        }
        let state = AppState(decoder: SlowStubDecoder(delay: 20_000_000), cache: cache,
                             trasher: StubTrasher(), earlyViewThreshold: 2)
        state.importFiles(urls: files)
        await waitForScrubbing(state)

        state.setCurrentIndex(39)   // queued behind the handoff: no preview yet
        XCTAssertNil(state.displayImages?.image(at: 39), "precondition: preview has not landed")
        XCTAssertNil(state.thumbWindow?.image(at: 39))
        XCTAssertFalse(state.canActivateLoupe,
                       "a loading placeholder has no pixels to magnify, so Space is not ours")
        state.setLoupeActive(true)
        XCTAssertFalse(state.isLoupeActive)

        let filled = await waitUntil { state.displayImages?.image(at: 39) != nil }
        XCTAssertTrue(filled, "the background decode must fill the slot")
        XCTAssertTrue(state.canActivateLoupe, "the loupe is possible once the image renders")
    }
}
