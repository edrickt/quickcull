import Foundation
import XCTest
@testable import QuickCullCore

/// Culling opens as soon as `earlyViewThreshold` full-size previews are
/// cached, instead of waiting for the whole shoot to decode. These pin the
/// handoff: the viewer opens mid-import, the background decode stays visible,
/// previews fill in as they land, and a failure or commit that happens while
/// the decode is still running leaves the session consistent.
@MainActor
final class AppStateEarlyViewTests: XCTestCase {
    private var tempDir: URL!
    private var cache: ImageCacheStore!

    override func setUp() async throws {
        tempDir = try TestFixtures.makeTempDir(name: "early-view")
        cache = ImageCacheStore(baseURL: tempDir.appendingPathComponent("cache", isDirectory: true))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private func makeState(decoder: RawDecoding,
                           threshold: Int,
                           trasher: Trashing = StubTrasher()) -> AppState {
        AppState(decoder: decoder, cache: cache, trasher: trasher,
                 earlyViewThreshold: threshold)
    }

    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func makeFiles(count: Int) throws -> [URL] {
        // Zero-padded so the decode order (sorted by path) matches this order:
        // the tests rely on a file's position to control when it decodes.
        try (0..<count).map {
            try TestFixtures.makeRawFile(named: String(format: "e%03d.cr2", $0), in: tempDir)
        }
    }

    /// The requested behavior, pinned: production opens after 50 full-size
    /// previews, not after some other count.
    func testDefaultThresholdIsFiftyFullSizePreviews() {
        let state = AppState(cache: cache)
        XCTAssertEqual(state.earlyViewThreshold, 50)
    }

    /// The viewer opens while the shoot is still decoding: scrubbing is
    /// reachable before the import's completed event.
    func testScrubbingOpensBeforeTheShootHasFinishedDecoding() async throws {
        let files = try makeFiles(count: 60)
        let state = makeState(decoder: SlowStubDecoder(delay: 20_000_000), threshold: 5)

        state.importFiles(urls: files)
        let opened = await waitUntil { state.phase == .scrubbing }
        XCTAssertTrue(opened, "culling must open once the threshold is cached")
        XCTAssertEqual(state.session?.count, 60)
        XCTAssertNotNil(state.thumbWindow)
        XCTAssertNotNil(state.displayImages)
        XCTAssertNotNil(state.backgroundDecodeProgress,
                        "the rest of the shoot must still be decoding behind the viewer")

        let finished = await waitUntil(timeout: 10) { state.backgroundDecodeProgress == nil }
        XCTAssertTrue(finished, "background decode must finish and clear its progress")
        XCTAssertEqual(state.phase, .scrubbing)
        XCTAssertEqual(state.session?.count, 60)
        XCTAssertTrue(state.importFailures.isEmpty)
        XCTAssertEqual(state.displayImages?.count, 60)
    }

    /// A shoot no larger than the threshold cannot open early: every file must
    /// be cached before the scrub view (the old behavior).
    func testAShootAtOrBelowTheThresholdWaitsForEveryFile() async throws {
        let files = try makeFiles(count: 3)
        let state = makeState(decoder: SlowStubDecoder(delay: 30_000_000), threshold: 50)

        state.importFiles(urls: files)
        let opened = await waitUntil { state.phase == .scrubbing }
        XCTAssertTrue(opened)
        XCTAssertNil(state.backgroundDecodeProgress)
        XCTAssertEqual(state.session?.count, 3)
        for file in files {
            let cached = try cache.cacheURL(for: SessionFile(url: file))
            XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path),
                          "\(file.lastPathComponent) must be cached before viewing opens")
        }
    }

    /// Navigating ahead of the decode front must not strand a slot on its
    /// spinner: the fill-in must come from the decode-completion refresh, not
    /// from the import's final window re-install. Enough files stay queued
    /// after the target that the assertion runs while decoding is ongoing.
    func testAPhotoNavigatedToBeforeItsDecodeLandsFillsIn() async throws {
        let files = try makeFiles(count: 100)
        let state = makeState(decoder: SlowStubDecoder(delay: 20_000_000), threshold: 2)

        state.importFiles(urls: files)
        let opened = await waitUntil { state.phase == .scrubbing }
        XCTAssertTrue(opened)
        XCTAssertEqual(state.session?.count, 100)

        state.setCurrentIndex(39)
        XCTAssertNil(state.displayImages?.image(at: 39),
                     "precondition: the target photo's decode is still queued")

        let filled = await waitUntil(timeout: 10) {
            state.backgroundDecodeProgress != nil && state.displayImages?.image(at: 39) != nil
        }
        XCTAssertTrue(filled,
                      "the slot must fill from the decode-completion refresh, before the import ends")
    }

    /// A decode failure that lands before the handoff cannot be viewed, so it
    /// is pruned from the session and reported when culling opens.
    func testFailuresLandedBeforeViewingOpensArePrunedAtTheHandoff() async throws {
        let files = try makeFiles(count: 8)
        let bad = [files[0], files[1]]
        let decoder = SlowStubDecoder(failIDs: Set(bad.map { RawFileIdentity.fileID(for: $0) }),
                                      delay: 20_000_000)
        let state = makeState(decoder: decoder, threshold: 4)

        state.importFiles(urls: files)
        let opened = await waitUntil { state.phase == .scrubbing }
        XCTAssertTrue(opened)
        XCTAssertEqual(state.session?.count, 6, "failed previews cannot be viewed")
        XCTAssertEqual(state.importFailures.count, 2)
        XCTAssertNotNil(state.backgroundDecodeProgress)

        let finished = await waitUntil(timeout: 10) { state.backgroundDecodeProgress == nil }
        XCTAssertTrue(finished)
        XCTAssertEqual(state.session?.count, 6)
        XCTAssertEqual(state.importFailures.count, 2)
        XCTAssertEqual(state.phase, .scrubbing)
    }

    /// A failure landing after viewing opened is dropped from the session
    /// right away and surfaced, not left behind a spinner until the import
    /// finishes. The windows are position-addressed, so they must be re-mapped
    /// in the same turn: otherwise every later photo shows its neighbour.
    func testAFailureLandedAfterViewingOpensDropsTheFile() async throws {
        // Place the failure past the first worker batch, so the two successes
        // the handoff needs provably land first (the failure's decode is only
        // dequeued after enough completions). Many files stay queued after it,
        // keeping "still decoding" observable for a wide window rather than
        // racing the last few decodes.
        let batch = DecodeEngine.workerCount(
            activeProcessors: ProcessInfo.processInfo.activeProcessorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, limit: nil)
        let count = batch + 30
        let files = try makeFiles(count: count)
        let bad = files[batch + 5]
        let decoder = SlowStubDecoder(failIDs: [RawFileIdentity.fileID(for: bad)],
                                      delay: 20_000_000)
        let state = makeState(decoder: decoder, threshold: 2)

        state.importFiles(urls: files)
        let opened = await waitUntil { state.phase == .scrubbing }
        XCTAssertTrue(opened)

        let dropped = await waitUntil {
            state.session?.count == count - 1 && state.backgroundDecodeProgress != nil
        }
        XCTAssertTrue(dropped, "the failed file must leave the session while decoding continues")
        XCTAssertEqual(state.thumbWindow?.count, count - 1,
                       "the strip must be re-mapped onto the post-removal list now")
        XCTAssertEqual(state.displayImages?.count, count - 1)
        XCTAssertEqual(state.importFailures.count, 1)

        let finished = await waitUntil(timeout: 10) { state.backgroundDecodeProgress == nil }
        XCTAssertTrue(finished)
        XCTAssertEqual(state.session?.count, count - 1)
        XCTAssertEqual(state.importFailures.count, 1)
        XCTAssertEqual(state.importFailures.first?.file.url, bad)
        XCTAssertEqual(state.phase, .scrubbing)
    }

    /// A failure can surface while the user's commit is still in flight (the
    /// file is still in the session then). Once the commit removes that file,
    /// the banner entry must go too: the photo is gone by the user's action,
    /// not broken.
    func testAFailureDuringACommitIsDroppedWhenTheCommitRemovesTheFile() async throws {
        let files = try makeFiles(count: 25)
        let doomed = files[24]   // last in decode order: fails while the commit waits
        let trasher = StubTrasher()
        let decoder = SlowStubDecoder(failIDs: [RawFileIdentity.fileID(for: doomed)],
                                      delay: 20_000_000)
        let state = makeState(decoder: decoder, threshold: 2, trasher: trasher)

        state.importFiles(urls: files)
        let opened = await waitUntil { state.phase == .scrubbing }
        XCTAssertTrue(opened)
        state.setCurrentIndex(24)
        state.handle(.toggleFlag(.red))

        let gate = DispatchSemaphore(value: 0)
        trasher.gate = gate
        XCTAssertTrue(state.requestCommit(color: .red))
        let commit = Task { await state.confirmCommit() }
        let surfaced = await waitUntil(timeout: 10) {
            state.importFailures.contains { $0.file.url == doomed }
        }
        XCTAssertTrue(surfaced, "the decode failure surfaces while the commit is in flight")
        gate.signal()
        await commit.value

        XCTAssertTrue(state.importFailures.isEmpty,
                      "the file left the session by the user's action, so it is not a failure")
        XCTAssertEqual(state.session?.count, 24)

        let finished = await waitUntil(timeout: 10) { state.backgroundDecodeProgress == nil }
        XCTAssertTrue(finished)
        XCTAssertTrue(state.importFailures.isEmpty)
        XCTAssertEqual(state.session?.count, 24)
    }

    /// Dismissing the banner during the background decode must stick: a later
    /// failure re-surfaces only itself, and the completed event must not put
    /// the acknowledged failure back on screen.
    ///
    /// The late failure is gated rather than merely slow. The test cannot
    /// assume it observes the exact handoff turn: the decode event stream is
    /// buffered and the import loop can drain many events in one main-actor
    /// turn, so by the time the poll sees `.scrubbing` the "late" failure may
    /// already have landed (and the import may even have completed). That made
    /// the test flaky — it passed on the baseline run and failed in this
    /// audit's first full-suite run. The gate makes the ordering the test
    /// names true by construction instead.
    func testDismissedFailuresAreNotResurrectedByLaterFailures() async throws {
        let files = try makeFiles(count: 20)
        let earlyBad = files[0]
        let lateBad = files[8]
        let decoder = GatedMidDecodeDecoder(
            gatedID: RawFileIdentity.fileID(for: lateBad),
            failIDs: [RawFileIdentity.fileID(for: earlyBad)],
            gatedError: .cannotUnpack("stub failure"))
        let state = makeState(decoder: decoder, threshold: 2)

        state.importFiles(urls: files)
        let opened = await waitUntil { state.phase == .scrubbing }
        XCTAssertTrue(opened)
        // The early failure can land just before or just after the handoff
        // (both paths report it); wait for it instead of assuming either.
        let earlyReported = await waitUntil { state.importFailures.map(\.file.url) == [earlyBad] }
        XCTAssertTrue(earlyReported, "the failure that landed before the handoff is reported")

        state.dismissImportFailures()
        XCTAssertTrue(state.importFailures.isEmpty)

        decoder.open()
        let resurfaced = await waitUntil {
            state.importFailures.map(\.file.url) == [lateBad]
        }
        XCTAssertTrue(resurfaced,
                      "a later failure must re-surface the banner without the dismissed one")

        let finished = await waitUntil(timeout: 10) { state.backgroundDecodeProgress == nil }
        XCTAssertTrue(finished)
        XCTAssertEqual(state.importFailures.map(\.file.url), [lateBad],
                       "the completed event must not resurrect a dismissed failure")
        XCTAssertEqual(state.session?.count, 18)
    }

    /// Trashing a photo before its decode finishes must not report the
    /// inevitable decode attempt as a failure: the file is gone because the
    /// user said so, not because it was broken.
    func testTrashingAPhotoMidDecodeDoesNotReportADecodeFailure() async throws {
        let files = try makeFiles(count: 25)
        let doomed = files[24]   // last in decode order: still queued at the handoff
        let decoder = SlowStubDecoder(failIDs: [RawFileIdentity.fileID(for: doomed)],
                                      delay: 20_000_000)
        let state = makeState(decoder: decoder, threshold: 2)

        state.importFiles(urls: files)
        let opened = await waitUntil { state.phase == .scrubbing }
        XCTAssertTrue(opened)
        state.setCurrentIndex(24)
        state.handle(.toggleFlag(.red))
        XCTAssertTrue(state.requestCommit(color: .red))
        await state.confirmCommit()
        XCTAssertEqual(state.session?.count, 24)

        let finished = await waitUntil(timeout: 10) { state.backgroundDecodeProgress == nil }
        XCTAssertTrue(finished)
        XCTAssertTrue(state.importFailures.isEmpty,
                      "a file the user trashed is not a decode failure")
        XCTAssertEqual(state.session?.count, 24)
        XCTAssertEqual(state.phase, .scrubbing)
    }

    /// A decode that read its source before the user trashed it can still
    /// finish and write a preview *after* the commit's own discard ran. The
    /// write recomputed the cache key after the deletion, so that discard
    /// cannot have named it; the preview must not outlive the file.
    func testAPreviewWrittenAfterItsFileWasTrashedIsDeleted() async throws {
        let files = try makeFiles(count: 3)
        let doomed = files[2]
        let decoder = GatedMidDecodeDecoder(gatedID: RawFileIdentity.fileID(for: doomed))
        let state = makeState(decoder: decoder, threshold: 1, trasher: DeletingTrasher())

        state.importFiles(urls: files)
        let opened = await waitUntil { state.phase == .scrubbing }
        XCTAssertTrue(opened)
        let inFlight = await waitUntil { decoder.hasStarted }
        XCTAssertTrue(inFlight, "precondition: the doomed file's decode is in flight")

        state.setCurrentIndex(2)
        state.handle(.toggleFlag(.red))
        XCTAssertTrue(state.requestCommit(color: .red))
        await state.confirmCommit()
        XCTAssertEqual(state.session?.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: doomed.path),
                       "precondition: the file is trashed")

        decoder.open()
        let finished = await waitUntil(timeout: 10) { state.backgroundDecodeProgress == nil }
        XCTAssertTrue(finished)
        XCTAssertTrue(state.importFailures.isEmpty)

        // With the source gone, the late write's key is the path-only key these
        // callers compute, so this is exactly where the orphan would live.
        let orphan = try cache.cacheURL(for: SessionFile(url: doomed))
        let gone = await waitUntil {
            !FileManager.default.fileExists(atPath: orphan.path)
        }
        XCTAssertTrue(gone, "a preview written after its file was trashed must be deleted")
    }
}

/// Removes the source file like the real Trashing implementation does; the
/// stock stub only records, which cannot exercise the mid-decode delete paths.
private struct DeletingTrasher: Trashing {
    func trash(url: URL) throws { try FileManager.default.removeItem(at: url) }
}

/// Decodes instantly except for one gated file: `hasStarted` flips (polled by
/// the test) and the decode blocks on `open()` until the commit has landed.
/// `failIDs` fail immediately; the gated file fails after `open()` when
/// `gatedError` is set, so a test can order a failure after the handoff.
private final class GatedMidDecodeDecoder: RawDecoding, @unchecked Sendable {
    let gatedID: String
    let failIDs: Set<String>
    let gatedError: DecodeError?
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var started = false

    init(gatedID: String, failIDs: Set<String> = [], gatedError: DecodeError? = nil) {
        self.gatedID = gatedID
        self.failIDs = failIDs
        self.gatedError = gatedError
    }

    var hasStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    func open() { release.signal() }

    func decodeRaw(at url: URL, options: DecodeOptions) throws -> RawBitmap {
        let id = RawFileIdentity.fileID(for: url)
        if id == gatedID {
            lock.lock(); started = true; lock.unlock()
            release.wait()
            if let gatedError { throw gatedError }
        }
        if failIDs.contains(id) {
            throw DecodeError.cannotUnpack("stub failure")
        }
        return RawBitmap(image: TestFixtures.makeCGImage(width: 4, height: 4, color: 9),
                         width: 4, height: 4, flip: 0)
    }
}
