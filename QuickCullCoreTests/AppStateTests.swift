import CoreGraphics
import XCTest
@testable import QuickCullCore

@MainActor
final class AppStateTests: XCTestCase {
    private var tempDir: URL!
    private var cache: ImageCacheStore!

    override func setUp() async throws {
        tempDir = try TestFixtures.makeTempDir(name: "state")
        cache = ImageCacheStore(baseURL: tempDir.appendingPathComponent("cache", isDirectory: true))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
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
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.txt", in: tempDir)
        let state = makeState()
        state.importFiles(urls: [a, b, a])
        await waitForScrubbing(state)
        XCTAssertEqual(state.session?.count, 1)
    }

    func testFlagsClearOnNewImport() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
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
        let files = try (0..<3).map { try TestFixtures.makeRawFile(named: "f\($0).cr2", in: tempDir) }
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
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let c = try TestFixtures.makeRawFile(named: "c.cr2", in: tempDir)
        let trasher = StubTrasher()
        let state = makeState(trasher: trasher)
        state.importFiles(urls: [a, b, c])
        await waitForScrubbing(state)

        state.handle(.toggleFlag)   // flag a
        state.handle(.next)
        state.handle(.toggleFlag)   // flag b
        state.requestCommit()
        XCTAssertEqual(state.pendingCommitCount, 2)
        await state.confirmCommit()

        XCTAssertEqual(state.session?.count, 1)
        XCTAssertEqual(state.session?.flaggedCount, 0)
        XCTAssertEqual(trasher.trashed.count, 2)
        XCTAssertEqual(state.pendingCommitCount, 0)
    }

    func testCommitFailureKeepsFlag() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let trasher = StubTrasher()
        trasher.failIDs = [a.path]
        let state = makeState(trasher: trasher)
        state.importFiles(urls: [a, b])
        await waitForScrubbing(state)

        state.handle(.toggleFlag)   // flag a
        state.handle(.next)
        state.handle(.toggleFlag)   // flag b
        state.requestCommit()
        await state.confirmCommit()
        XCTAssertEqual(state.session?.count, 1)        // a stays
        XCTAssertEqual(state.session?.flaggedCount, 1) // a stays flagged
        XCTAssertEqual(state.commitFailures.count, 1)
    }

    func testCommitOfEverythingReturnsToEmptyState() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let state = makeState()
        state.importFiles(urls: [a])
        await waitForScrubbing(state)

        state.handle(.toggleFlag)
        state.requestCommit()
        await state.confirmCommit()
        XCTAssertNil(state.session)
        XCTAssertEqual(state.phase, .empty)
    }

    func testCommitSetsCommittingState() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let gate = DispatchSemaphore(value: 0)
        let trasher = StubTrasher()
        trasher.gate = gate
        let state = makeState(trasher: trasher)
        state.importFiles(urls: [a, b])
        await waitForScrubbing(state)

        state.handle(.toggleFlag)
        state.requestCommit()
        XCTAssertFalse(state.isCommitting)

        let commit = Task { await state.confirmCommit() }
        // The trasher is gated: the commit must be stuck in flight now.
        var observedInFlight = false
        for _ in 0..<100 {
            if state.isCommitting { observedInFlight = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(observedInFlight,
                      "isCommitting must be true while the trash move is in flight")
        gate.signal()
        await commit.value
        XCTAssertFalse(state.isCommitting)
        XCTAssertEqual(state.session?.count, 1)
        XCTAssertEqual(trasher.trashed.count, 1)
    }

    func testImportFailuresSurviveIntoScrubbing() async throws {
        let ok = try TestFixtures.makeRawFile(named: "ok.cr2", in: tempDir)
        let bad = try TestFixtures.makeRawFile(named: "bad.cr2", in: tempDir)
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
        let ok = try TestFixtures.makeRawFile(named: "ok.cr2", in: tempDir)
        let bad = try TestFixtures.makeRawFile(named: "bad.cr2", in: tempDir)
        let state = makeState(decoder: StubDecoder(failIDs: [bad.path]))
        state.importFiles(urls: [ok, bad])
        await waitForScrubbing(state)

        // Spec: the session proceeds WITHOUT the failed file.
        XCTAssertEqual(state.session?.count, 1)
        XCTAssertEqual(state.importFailures.count, 1)
    }

    func testAllFailedReturnsToEmptyState() async throws {
        let bad1 = try TestFixtures.makeRawFile(named: "bad1.cr2", in: tempDir)
        let bad2 = try TestFixtures.makeRawFile(named: "bad2.cr2", in: tempDir)
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

        let base = try TestFixtures.makeTempDir(name: "flow")
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
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let txt = try TestFixtures.makeRawFile(named: "c.txt", in: tempDir)
        let state = makeState()
        state.importFiles(urls: [a, b, txt])
        await waitForScrubbing(state)
        XCTAssertEqual(state.session?.count, 2)
        XCTAssertEqual(state.importFailures.count, 1)
        XCTAssertEqual(state.importFailures.first?.error, .cannotOpen("Unsupported format"))
    }


    func testMixedRawAndImageImportThroughDefaultDecoder() async throws {
        let bundle = Bundle(for: Self.self)
        let rawURLs = try FileManager.default.contentsOfDirectory(
            at: bundle.resourceURL!.appendingPathComponent("Fixtures/raws", isDirectory: true),
            includingPropertiesForKeys: nil)
            .filter { RawFileIdentity.isSupported($0) && !$0.lastPathComponent.hasPrefix("bad_") }
        XCTAssertEqual(rawURLs.count, 8)

        // One real JPEG side by side with the raws.
        let jpgURL = try TestFixtures.makeTempDir(name: "mixed")
        defer { try? FileManager.default.removeItem(at: jpgURL) }
        let jpgFile = jpgURL.appendingPathComponent("sidecar.jpg")
        var bytes = [UInt8](repeating: 120, count: 32 * 32 * 3)
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 24,
                            bytesPerRow: 32 * 3, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        let sink = CGImageDestinationCreateWithURL(jpgFile as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(sink, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(sink))

        let cacheBase = try TestFixtures.makeTempDir(name: "mixed-cache")
        defer { try? FileManager.default.removeItem(at: cacheBase) }

        // Default decoder (RoutingDecoder) with a real cache.
        let state = AppState(cache: ImageCacheStore(baseURL: cacheBase), trasher: StubTrasher())
        state.importFiles(urls: rawURLs + [jpgFile])

        for _ in 0..<600 {
            if state.phase == .scrubbing { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(state.phase, .scrubbing)
        XCTAssertEqual(state.session?.count, 9)
        XCTAssertTrue(state.importFailures.isEmpty)

        await state.displayImages?.waitUntilSettled()
        XCTAssertNotNil(state.displayImages?.image(at: 0))
    }

    func testSetFilterRebuildsWindowsOverProjection() async throws {
        let files = try (0..<3).map { try TestFixtures.makeRawFile(named: "f\($0).cr2", in: tempDir) }
        let state = makeState()
        state.importFiles(urls: files)
        await waitForScrubbing(state)

        state.handle(.toggleFlag)          // flag f0
        state.setFilter(.flagged)
        XCTAssertEqual(state.session?.count, 1)
        XCTAssertEqual(state.thumbWindow?.count, 1)
        XCTAssertEqual(state.displayImages?.count, 1)

        state.setFilter(.all)
        XCTAssertEqual(state.session?.count, 3)
        XCTAssertEqual(state.thumbWindow?.count, 3)
    }

    func testToggleFlagRebuildsWindowsOnlyWhenProjectionChanges() async throws {
        let files = try (0..<3).map { try TestFixtures.makeRawFile(named: "f\($0).cr2", in: tempDir) }
        let state = makeState()
        state.importFiles(urls: files)
        await waitForScrubbing(state)

        let window = state.thumbWindow
        state.handle(.toggleFlag)          // All mode: sequence unchanged
        XCTAssertTrue(state.thumbWindow === window,
                      "flag toggle in All mode must not rebuild windows")

        state.setFilter(.flagged)          // [f0]
        state.handle(.toggleFlag)          // unflag f0: projection empties -> reset to All
        XCTAssertEqual(state.session?.filter, .all)
        XCTAssertEqual(state.session?.count, 3)
        XCTAssertNotNil(state.thumbWindow)
    }

    func testCommitUnderKeepersFilterTrashesFlagged() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let trasher = StubTrasher()
        let state = makeState(trasher: trasher)
        state.importFiles(urls: [a, b])
        await waitForScrubbing(state)

        state.handle(.toggleFlag)          // flag a
        state.setFilter(.keepers)          // [b], current = b
        state.requestCommit()
        XCTAssertEqual(state.pendingCommitCount, 1)
        await state.confirmCommit()

        XCTAssertEqual(trasher.trashed.count, 1)
        XCTAssertEqual(state.session?.count, 1)
        XCTAssertEqual(state.session?.filter, .keepers)
        XCTAssertEqual(state.session?.currentFile.url.lastPathComponent, "b.cr2")
        XCTAssertEqual(state.thumbWindow?.count, 1)
    }

}
