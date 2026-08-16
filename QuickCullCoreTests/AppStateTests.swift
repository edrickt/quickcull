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

    private func waitForEmpty(_ state: AppState) async {
        for _ in 0..<200 {   // bounded wait; stub decode is instant
            if state.session == nil && state.phase == .empty { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("never reached empty state")
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

    func testFailedFilesAreRemovedFromSession() async throws {
        let ok = try makeRaw("ok.cr2")
        let bad = try makeRaw("bad.cr2")
        let state = makeState(decoder: StubDecoder(failIDs: [bad.path]))
        state.importFiles(urls: [ok, bad])
        await waitForScrubbing(state)

        // Spec: the session proceeds WITHOUT the failed file.
        XCTAssertEqual(state.session?.count, 1)
        XCTAssertEqual(state.importFailures.count, 1)
    }

    func testAllFailedReturnsToEmptyState() async throws {
        let bad1 = try makeRaw("bad1.cr2")
        let bad2 = try makeRaw("bad2.cr2")
        let state = makeState(decoder: StubDecoder(failIDs: [bad1.path, bad2.path]))
        state.importFiles(urls: [bad1, bad2])
        await waitForEmpty(state)

        XCTAssertEqual(state.importFailures.count, 2)
        XCTAssertEqual(state.phase, .empty)
        XCTAssertNil(state.session)
    }

    func testRealImportFlowPopulatesDisplayImage() async throws {
        let bundle = Bundle(for: Self.self)
        let urls = try FileManager.default.contentsOfDirectory(
            at: bundle.resourceURL!.appendingPathComponent("Fixtures/raws", isDirectory: true),
            includingPropertiesForKeys: nil)
            .filter { RawFileIdentity.isSupported($0) && !$0.lastPathComponent.hasPrefix("bad_") }
        XCTAssertEqual(urls.count, 8)

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = ImageCacheStore(baseURL: base.appendingPathComponent("cache", isDirectory: true))

        let state = AppState(decoder: LibRawDecoder(), cache: cache, trasher: StubTrasher())
        state.importFiles(urls: urls)

        for _ in 0..<600 {   // real decode of 8 raws takes seconds
            if state.phase == .scrubbing { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(state.phase, .scrubbing)
        XCTAssertEqual(state.session?.count, 8)
        XCTAssertTrue(state.importFailures.isEmpty)

        await state.displayImages?.waitUntilSettled()
        XCTAssertNotNil(state.displayImages?.image(at: 0),
                        "display image must materialize from the real decode → cache → load chain")
        await state.thumbWindow?.waitUntilSettled()
        XCTAssertNotNil(state.thumbWindow?.image(at: 0))
    }

    func testPartialUnsupportedRecordsFailures() async throws {
        let a = try makeRaw("a.cr2")
        let b = try makeRaw("b.cr2")
        let jpg = try makeRaw("c.jpg")
        let state = makeState()
        state.importFiles(urls: [a, b, jpg])
        await waitForScrubbing(state)
        XCTAssertEqual(state.session?.count, 2)
        XCTAssertEqual(state.importFailures.count, 1)
        XCTAssertEqual(state.importFailures.first?.error, .cannotOpen("Unsupported format"))
    }

}
