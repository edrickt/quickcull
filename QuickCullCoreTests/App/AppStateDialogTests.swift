import Foundation
import XCTest
@testable import QuickCullCore

/// Regressions from the 2026-10-28 code-quality audit: the pending-dialog slot,
/// committing from an empty-filter placeholder, grid flag keys with no
/// selection, shift-range shrinking, and cancelling a running import.
@MainActor
final class AppStateDialogTests: XCTestCase {
    private var tempDir: URL!
    private var cache: ImageCacheStore!

    override func setUp() async throws {
        tempDir = try TestFixtures.makeTempDir(name: "dialogs")
        cache = ImageCacheStore(baseURL: tempDir.appendingPathComponent("cache", isDirectory: true))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private func waitForScrubbing(_ state: AppState) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, state.phase != .scrubbing {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(state.phase, .scrubbing, "never reached scrubbing")
    }

    private func makeState(decoder: RawDecoding = StubDecoder(),
                           trasher: Trashing = StubTrasher()) -> AppState {
        AppState(decoder: decoder, cache: cache, trasher: trasher)
    }

    private func makeFlaggedState(count: Int = 2) async throws -> AppState {
        let urls = try (0..<count).map {
            try TestFixtures.makeRawFile(named: "d\($0).cr2", in: tempDir)
        }
        let state = makeState()
        state.importFiles(urls: urls)
        await waitForScrubbing(state)
        return state
    }

    // MARK: One pending request per app

    /// `AppState` is shared by every window. A second window's request used to
    /// overwrite the set the first window's dialog already named, so confirming
    /// the first dialog committed the second window's choice.
    func testASecondRequestCannotReplaceThePendingSet() async throws {
        let state = try await makeFlaggedState()
        state.handle(.toggleFlag(.red))
        state.handle(.next)
        state.handle(.toggleFlag(.green))

        XCTAssertTrue(state.requestCommit(color: .red))
        XCTAssertEqual(state.pendingCommitColor, .red)
        XCTAssertEqual(state.pendingCommitCount, 1)

        // Window B picks Trash G while window A's dialog is up.
        XCTAssertFalse(state.requestCommit(color: .green), "a pending dialog owns the slot")
        XCTAssertEqual(state.pendingCommitColor, .red, "the dialog's target is unchanged")
        XCTAssertEqual(state.pendingCommitCount, 1)

        XCTAssertFalse(state.requestMove(to: tempDir, color: .green),
                       "trash and move share the one pending slot")
        XCTAssertNil(state.pendingMoveDestination)
    }

    // MARK: Committing from an empty-filter placeholder

    /// A commit made while the filter matches nothing leaves the projection
    /// empty but the session full. Reading the projection as "the session is
    /// gone" dropped every surviving photo and its flags.
    func testCommittingFromAnEmptyPlaceholderKeepsTheSession() async throws {
        let state = try await makeFlaggedState(count: 3)
        state.handle(.toggleFlag(.yellow))
        state.setFilter(.red)
        XCTAssertTrue(state.session?.files.isEmpty ?? false, "precondition: placeholder")

        XCTAssertTrue(state.requestCommit(color: .yellow), "the menu is enabled by the flag count")
        await state.confirmCommit()

        XCTAssertNotNil(state.session, "the session survives a commit it did not empty")
        XCTAssertEqual(state.session?.totalCount, 2, "only the committed file left")
        XCTAssertEqual(state.phase, .scrubbing)
        XCTAssertEqual(state.session?.flaggedCount, 0, "the committed flag is gone, the rest were never set")
    }

    /// A move from the placeholder keeps the session for the same reason.
    func testMovingFromAnEmptyPlaceholderKeepsTheSession() async throws {
        let dir = try TestFixtures.makeTempDir(name: "dialogs-move-dst")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = try await makeFlaggedState(count: 2)
        state.handle(.toggleFlag(.green))
        state.setFilter(.red)
        XCTAssertTrue(state.session?.files.isEmpty ?? false, "precondition: placeholder")

        XCTAssertTrue(state.requestMove(to: dir, color: .green))
        await state.confirmMove()

        XCTAssertNotNil(state.session)
        XCTAssertEqual(state.session?.totalCount, 1)
        XCTAssertEqual(state.phase, .scrubbing)
    }

    // MARK: Grid has no current photo to flag

    /// The batch path still works, and still reaches only selected photos.
    func testGridFlagKeyWithASelectionFlagsTheSelection() async throws {
        let state = try await makeFlaggedState(count: 3)
        state.setViewMode(.grid)
        state.handleGridTap(id: state.session!.files[2].id, isCmd: false, isShift: false)
        state.handle(.toggleFlag(.green))
        XCTAssertEqual(state.session?.flaggedCount(.green), 1)
        XCTAssertEqual(state.session?.flagColor(for: state.session!.files[2]), .green)
    }

    // MARK: Shift-click ranges shrink like Finder's

    func testShiftRangeShrinksWhenTheTargetMovesBack() async throws {
        let state = try await makeFlaggedState(count: 5)
        state.setViewMode(.grid)
        let ids = state.session!.files.map(\.id)
        state.selectSingle(id: ids[0])
        state.selectRange(to: ids[3])
        XCTAssertEqual(state.gridSelection, Set(ids[0...3]))
        // Same anchor, nearer target: the range replaces, it does not union.
        state.selectRange(to: ids[1])
        XCTAssertEqual(state.gridSelection, Set(ids[0...1]))
    }

    // MARK: Cancelling a running import

    func testCancelImportReturnsToTheImporterAndStaysThere() async throws {
        let urls = try (0..<3).map {
            try TestFixtures.makeRawFile(named: "c\($0).cr2", in: tempDir)
        }
        let state = makeState(decoder: SlowStubDecoder(delay: 300_000_000))
        state.importFiles(urls: urls)
        XCTAssertEqual(state.phase, .decoding(completed: 0, total: 3), "precondition: decoding")

        state.cancelImport()

        XCTAssertEqual(state.phase, .empty)
        XCTAssertNil(state.session)
        XCTAssertNil(state.thumbWindow)
        // A decode already in flight must not resurrect the cancelled session.
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(state.phase, .empty)
        XCTAssertNil(state.session)
    }
}
