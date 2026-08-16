import CoreGraphics
import XCTest
@testable import QuickCullCore

@MainActor
final class AppStateTests: XCTestCase {
    private var tempDir: URL!
    private var cache: ImageCacheStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        cache = ImageCacheStore(baseURL: tempDir.appendingPathComponent("cache", isDirectory: true))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeRaw(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(repeating: 7, count: 16).write(to: url)
        return url
    }

    private func makeState(decoder: RawDecoding = StubDecoder(),
                           trasher: Trashing = StubTrasher()) -> AppState {
        AppState(decoder: decoder, cache: cache, trasher: trasher)
    }

    private func waitForScrubbing(_ state: AppState) async {
        for _ in 0..<200 {   // bounded wait; stub decode is instant
            if state.phase == .scrubbing { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("never reached scrubbing")
    }

    func testImportFiltersUnsupportedAndDedupes() async throws {
        let a = try makeRaw("a.cr2")
        let b = try makeRaw("b.jpg")
        let state = makeState()
        state.importFiles(urls: [a, b, a])
        await waitForScrubbing(state)
        XCTAssertEqual(state.session?.count, 1)
    }

    func testFlagsClearOnNewImport() async throws {
        let a = try makeRaw("a.cr2")
        let b = try makeRaw("b.cr2")
        let state = makeState()
        state.importFiles(urls: [a])
        await waitForScrubbing(state)
        state.handle(.toggleFlag)
        XCTAssertEqual(state.session?.flaggedCount, 1)
        state.importFiles(urls: [b])
        await waitForScrubbing(state)
        XCTAssertEqual(state.session?.flaggedCount, 0)
    }

    func testHandleMovesAndFlags() async throws {
        let files = try (0..<3).map { try makeRaw("f\($0).cr2") }
        let state = makeState()
        state.importFiles(urls: files)
        await waitForScrubbing(state)

        state.handle(.next)
        XCTAssertEqual(state.session?.currentIndex, 1)
        state.handle(.jumpForward)
        XCTAssertEqual(state.session?.currentIndex, 2)
        state.handle(.jumpBack)
        XCTAssertEqual(state.session?.currentIndex, 0)
        state.handle(.toggleFlag)
        XCTAssertEqual(state.session?.flaggedCount, 1)
    }

    func testCommitRemovesFlaggedAndContinues() async throws {
        let a = try makeRaw("a.cr2")
        let b = try makeRaw("b.cr2")
        let c = try makeRaw("c.cr2")
        let trasher = StubTrasher()
        let state = makeState(trasher: trasher)
        state.importFiles(urls: [a, b, c])
        await waitForScrubbing(state)

        state.handle(.toggleFlag)   // flag a
        state.handle(.next)
        state.handle(.toggleFlag)   // flag b
        state.requestCommit()
        XCTAssertEqual(state.pendingCommitCount, 2)
        state.confirmCommit()

        XCTAssertEqual(state.session?.count, 1)
        XCTAssertEqual(state.session?.flaggedCount, 0)
        XCTAssertEqual(trasher.trashed.count, 2)
        XCTAssertEqual(state.pendingCommitCount, 0)
    }

    func testCommitFailureKeepsFlag() async throws {
        let a = try makeRaw("a.cr2")
        let b = try makeRaw("b.cr2")
        let trasher = StubTrasher()
        trasher.failIDs = [a.path]
        let state = makeState(trasher: trasher)
        state.importFiles(urls: [a, b])
        await waitForScrubbing(state)

        state.handle(.toggleFlag)   // flag a
        state.handle(.next)
        state.handle(.toggleFlag)   // flag b
        state.requestCommit()
        state.confirmCommit()
        XCTAssertEqual(state.session?.count, 1)        // a stays
        XCTAssertEqual(state.session?.flaggedCount, 1) // a stays flagged
        XCTAssertEqual(state.commitFailures.count, 1)
    }

    func testCommitOfEverythingReturnsToEmptyState() async throws {
        let a = try makeRaw("a.cr2")
        let state = makeState()
        state.importFiles(urls: [a])
        await waitForScrubbing(state)

        state.handle(.toggleFlag)
        state.requestCommit()
        state.confirmCommit()
        XCTAssertNil(state.session)
        XCTAssertEqual(state.phase, .empty)
    }

    func testImportFailuresSurviveIntoScrubbing() async throws {
        let ok = try makeRaw("ok.cr2")
        let bad = try makeRaw("bad.cr2")
        let state = makeState(decoder: StubDecoder(failIDs: [bad.path]))
        state.importFiles(urls: [ok, bad])
        await waitForScrubbing(state)

        // Phase flips to scrubbing in the same turn that records failures;
        // the scrub phase must still see them (DecodingView never renders).
        XCTAssertEqual(state.phase, .scrubbing)
        XCTAssertEqual(state.importFailures.count, 1)

        state.dismissImportFailures()
        XCTAssertTrue(state.importFailures.isEmpty)
    }
}
