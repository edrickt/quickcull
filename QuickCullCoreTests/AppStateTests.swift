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
        state.handle(.toggleFlag(.red))
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
        state.handle(.toggleFlag(.red))
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

        state.handle(.toggleFlag(.red))   // flag a
        state.handle(.next)
        state.handle(.toggleFlag(.red))   // flag b
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

        state.handle(.toggleFlag(.red))   // flag a
        state.handle(.next)
        state.handle(.toggleFlag(.red))   // flag b
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

        state.handle(.toggleFlag(.red))
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

        state.handle(.toggleFlag(.red))
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

        state.handle(.toggleFlag(.red))          // flag f0
        state.setFilter(.red)
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
        state.handle(.toggleFlag(.red))          // All mode: sequence unchanged
        XCTAssertTrue(state.thumbWindow === window,
                      "flag toggle in All mode must not rebuild windows")

        state.setFilter(.red)          // [f0]
        state.handle(.toggleFlag(.red))          // unflag f0: projection empties -> reset to All
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
        state.handle(.toggleFlag(.red))          // flag a
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

    /// The rapid "next, Z, repeat" burst must leave the model in a fully
    /// consistent state: every view derives badges from the same
    /// `flagged` set, whether it looks up by index (`files[index]`) or by
    /// the id-keyed cell's file. The strip-badge bug was reported under
    /// exactly this input pattern; this pins the model invariants the
    /// views rely on.
    func testRapidNextToggleBurstLeavesConsistentState() async throws {
        let files = try (0..<8).map { try TestFixtures.makeRawFile(named: "f\($0).cr2", in: tempDir) }
        let state = makeState()
        state.importFiles(urls: files)
        await waitForScrubbing(state)

        for _ in 0..<8 {
            state.handle(.next)
            state.handle(.toggleFlag(.red))
        }
        // Pair i flags the photo current after pair i's next. The last next
        // clamps at the end, so pair 8's toggle lands on f7 again and flips
        // it back OFF: f1...f6 are flagged, f7 is current and unflagged.
        XCTAssertEqual(state.session?.currentIndex, 7)
        XCTAssertEqual(state.session?.flaggedCount, 6)
        XCTAssertFalse(state.session?.isFlagged(state.session!.files[0]) ?? true)
        XCTAssertFalse(state.session?.isFlagged(state.session!.files[7]) ?? true,
                       "the clamped pair-8 toggle must flip f7 back off")
        for i in 1..<7 {
            XCTAssertTrue(state.session?.isFlagged(state.session!.files[i]) ?? false,
                          "file \(i) must be flagged after the burst")
        }
        // Index-based lookup (main viewer) and id-keyed cell lookup
        // (filmstrip) must always agree for every displayed file.
        for (i, file) in (state.session?.files ?? []).enumerated() {
            XCTAssertEqual(state.session?.isFlagged(file),
                           state.session?.flagged.contains(file.id),
                           "lookups disagree at index \(i)")
        }
        // The current photo's badge state is the same whichever view reads it.
        let current = state.session!.currentFile
        XCTAssertFalse(state.session?.isFlagged(current) ?? true,
                       "f7 is current and unflagged after the burst")
        XCTAssertEqual(state.thumbWindow?.count, 8)
    }

    func testViewModeDefaultsScrubAndResetsOnImport() async throws {
        let files = try (0..<2).map { try TestFixtures.makeRawFile(named: "v\($0).cr2", in: tempDir) }
        let state = makeState()
        state.importFiles(urls: files)
        await waitForScrubbing(state)
        XCTAssertEqual(state.viewMode, .scrub)
        state.setViewMode(.grid)
        XCTAssertEqual(state.viewMode, .grid)
        // new import resets
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        state.importFiles(urls: [b])
        await waitForScrubbing(state)
        XCTAssertEqual(state.viewMode, .scrub)
        XCTAssertTrue(state.gridSelection.isEmpty)
    }

    func testGridSelectionSingleCmdShiftRange() async throws {
        let files = try (0..<5).map { try TestFixtures.makeRawFile(named: "g\($0).cr2", in: tempDir) }
        let state = makeState()
        state.importFiles(urls: files)
        await waitForScrubbing(state)
        let ids = state.session!.files.map(\.id)
        state.selectSingle(id: ids[1])
        XCTAssertEqual(state.gridSelection, [ids[1]])
        state.toggleSelection(id: ids[3])
        XCTAssertEqual(state.gridSelection, [ids[1], ids[3]])
        state.selectRange(to: ids[4]) // anchor was ids[1], range 1...4
        XCTAssertEqual(state.gridSelection, Set([ids[1], ids[2], ids[3], ids[4]]))
        state.selectSingle(id: ids[0])
        XCTAssertEqual(state.gridSelection, [ids[0]])
    }

    func testHandleToggleFlagInGridBatchesSelection() async throws {
        let files = try (0..<3).map { try TestFixtures.makeRawFile(named: "h\($0).cr2", in: tempDir) }
        let state = makeState()
        state.importFiles(urls: files)
        await waitForScrubbing(state)
        state.setViewMode(.grid)
        let ids = state.session!.files.map(\.id)
        state.selectSingle(id: ids[0])
        state.toggleSelection(id: ids[2])
        state.handle(.toggleFlag(.red)) // should batch-flag 0 and 2
        XCTAssertEqual(state.session?.flaggedCount, 2)
        XCTAssertTrue(state.session!.isFlagged(state.session!.files[0]))
        XCTAssertTrue(state.gridSelection.isEmpty, "grid should deselect after any flag action (Ctrl+A + Z should not stay highlighted)")
    }

    func testHandleToggleFlagInGridEmptyFallsBackToSingle() async throws {
        let files = try (0..<2).map { try TestFixtures.makeRawFile(named: "e\($0).cr2", in: tempDir) }
        let state = makeState()
        state.importFiles(urls: files)
        await waitForScrubbing(state)
        state.setViewMode(.grid)
        XCTAssertTrue(state.gridSelection.isEmpty)
        state.handle(.toggleFlag(.red)) // no selection → flags current (index 0)
        XCTAssertEqual(state.session?.flaggedCount, 1)
    }

    func testGridSelectionPrunedAfterCommitAndFilter() async throws {
        let files = try (0..<3).map { try TestFixtures.makeRawFile(named: "p\($0).cr2", in: tempDir) }
        let state = makeState()
        state.importFiles(urls: files)
        await waitForScrubbing(state)
        let ids = state.session!.files.map(\.id)
        state.setViewMode(.grid)
        state.selectSingle(id: ids[0])
        state.toggleSelection(id: ids[1])
        state.handle(.toggleFlag(.red)) // flag 0,1 -> deselects after flag
        XCTAssertTrue(state.gridSelection.isEmpty, "deselect after flag")
        state.setFilter(.keepers) // grid now shows only [2]
        XCTAssertTrue(state.gridSelection.isEmpty)
        // commit removes flagged 0,1 → still empty
        state.requestCommit()
        await state.confirmCommit()
        XCTAssertTrue(state.gridSelection.isEmpty)
        XCTAssertEqual(state.session?.count, 1)
    }

    func testSetFilterEmptyPlaceholderKeepsGhosts() async throws {
        let files = try (0..<2).map { try TestFixtures.makeRawFile(named: "k\($0).cr2", in: tempDir) }
        let state = makeState()
        state.importFiles(urls: files)
        await waitForScrubbing(state)
        let ids = state.session!.files.map(\.id)
        state.setViewMode(.grid)
        state.selectSingle(id: ids[0])
        // No flags yet: Flagged filter yields empty placeholder, not fallback
        state.setFilter(.red)
        XCTAssertEqual(state.session?.filter, .red)
        XCTAssertEqual(state.session?.count, 0)
        XCTAssertTrue(state.session?.isEmpty == true)
        XCTAssertEqual(state.thumbWindow?.count, 0)
        XCTAssertEqual(state.displayImages?.count, 0)
        // Ghost selection stays (not pruned on filter)
        XCTAssertEqual(state.gridSelection, [ids[0]])
        // Back to All restores
        state.setFilter(.all)
        XCTAssertEqual(state.session?.count, 2)
        XCTAssertEqual(state.thumbWindow?.count, 2)
    }

    func testCommitEmptiesSessionResetsViewMode() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let state = makeState()
        state.importFiles(urls: [a])
        await waitForScrubbing(state)
        state.setViewMode(.grid)
        XCTAssertEqual(state.viewMode, .grid)
        // Empty selection in grid falls back to single-flag current
        state.handle(.toggleFlag(.red))
        XCTAssertEqual(state.session?.flaggedCount, 1)
        state.requestCommit()
        await state.confirmCommit()
        XCTAssertEqual(state.phase, .empty)
        XCTAssertEqual(state.viewMode, .scrub)
        XCTAssertTrue(state.gridSelection.isEmpty)
    }

    func testStartNewSessionResetsToEmpty() async throws {
        // Setup: import 2 files, flag one, select in grid, create failures
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let state = makeState() // helper that injects temp ImageCacheStore, same as existing tests
        state.importFiles(urls: [a, b])
        await waitForScrubbing(state)
        // make non-empty state: flag, filter, grid selection, failures
        state.session?.toggleFlag() // flag current
        state.setFilter(.red)
        state.setViewMode(.grid)
        state.selectSingle(id: state.session!.files[0].id)
        state.requestCommit() // pendingCommitCount >0 but not committing
        // Create a marker file in cache to verify wipe is attempted (best-effort)
        let baseURL = await state.cache.baseURL
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let marker = baseURL.appendingPathComponent("marker.tmp")
        try Data("x".utf8).write(to: marker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        // Act
        state.startNewSession()
        // Allow detached Task { try? await cache.wipe() } to run
        try await Task.sleep(nanoseconds: 300_000_000) // 0.3s

        // Assert full reset like quit/relaunch
        XCTAssertEqual(state.phase, .empty)
        XCTAssertNil(state.session)
        XCTAssertNil(state.thumbWindow)
        XCTAssertNil(state.gridThumbs)
        XCTAssertNil(state.displayImages)
        XCTAssertTrue(state.importFailures.isEmpty)
        XCTAssertTrue(state.commitFailures.isEmpty)
        XCTAssertEqual(state.pendingCommitCount, 0)
        XCTAssertFalse(state.isCommitting)
        XCTAssertTrue(state.gridSelection.isEmpty)
        XCTAssertEqual(state.viewMode, .scrub)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "cache should be wiped")
    }

    func testStartNewSessionIsIdempotentWhenAlreadyEmpty() {
        let state = makeState()
        XCTAssertEqual(state.phase, .empty)
        state.startNewSession()
        XCTAssertEqual(state.phase, .empty)
        XCTAssertNil(state.session)
    }

    func testSplitViewModeToggleAndShift() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let c = try TestFixtures.makeRawFile(named: "c.cr2", in: tempDir)
        let state = makeState()
        state.importFiles(urls: [a, b, c])
        await waitForScrubbing(state)
        XCTAssertEqual(state.viewMode, .scrub)
        state.setViewMode(.split)
        XCTAssertEqual(state.viewMode, .split)
        // Split second index is current+1 when exists
        XCTAssertEqual(state.session?.currentIndex, 0)
        let second = state.session!.files.indices.contains(1) ? state.session!.files[1].id : nil
        XCTAssertNotNil(second)
        // Both shift by 1 overlapping
        state.handle(.next) // current 0→1
        XCTAssertEqual(state.session?.currentIndex, 1)
        // Right preview now c (index 2)
        XCTAssertEqual(state.session?.files[state.session!.currentIndex + 1].url.lastPathComponent, "c.cr2")
        // At last, right should be nil placeholder (view computes)
        state.handle(.next) // 1→2 last
        XCTAssertEqual(state.session?.currentIndex, 2)
        // Next beyond last clamps (move does not exceed)
        state.handle(.next)
        XCTAssertEqual(state.session?.currentIndex, 2)
        // Toggle Split disabled while committing
        state.requestCommit()
        // Simulate isCommitting true via flagged commit path? Just test setViewMode guard:
        // isCommitting is false initially; after requestCommit without confirm, still false so not testable here.
    }

    func testSplitViewModeResetOnNewSession() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let state = makeState()
        state.importFiles(urls: [a])
        await waitForScrubbing(state)
        state.setViewMode(.split)
        XCTAssertEqual(state.viewMode, .split)
        state.startNewSession()
        XCTAssertEqual(state.viewMode, .scrub) // AppState.startNewSession resets to scrub
        XCTAssertEqual(state.phase, .empty)
    }

    func testFlagKeysAreIgnoredWhileTheTrashDialogIsUp() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let state = makeState()
        state.importFiles(urls: [a, b])
        await waitForScrubbing(state)
        state.handle(.toggleFlag(.red))
        state.requestCommit(color: .red)
        XCTAssertEqual(state.pendingCommitCount, 1)
        // The alert is up: scrub and flag keys must not change the session the
        // dialog is describing.
        state.handle(.next)
        state.handle(.toggleFlag(.red))
        XCTAssertEqual(state.session?.currentIndex, 0)
        XCTAssertEqual(state.session?.flaggedCount, 1)
    }

    func testConfirmCommitsTheFilesTheDialogNamedEvenIfFlagsChange() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let trasher = StubTrasher()
        let state = makeState(trasher: trasher)
        state.importFiles(urls: [a, b])
        await waitForScrubbing(state)
        state.handle(.toggleFlag(.red))            // a is red
        state.requestCommit(color: .red)
        // Any mutation that bypasses the input gate must still not change the
        // set the user approved.
        state.session?.toggleFlag(color: .red)      // clears a's red flag
        XCTAssertEqual(state.session?.flaggedCount, 0)
        await state.confirmCommit()
        XCTAssertEqual(trasher.trashed, [RawFileIdentity.fileID(for: a)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func testGridFlagActionSkipsPhotosHiddenByTheFilter() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
        let state = makeState()
        state.importFiles(urls: [a, b])
        await waitForScrubbing(state)
        let session = state.session!
        let bFile = session.allFiles.first { $0.url.lastPathComponent == "b.cr2" }!
        state.handle(.toggleFlag(.red))             // a red, current stays a
        state.setViewMode(.grid)
        state.selectAllInGrid()                     // both ids selected
        state.setFilter(.red)                       // only a is visible now
        XCTAssertEqual(state.session?.count, 1)
        XCTAssertEqual(state.gridSelection.count, 2)
        state.handle(.toggleFlag(.red))             // Z: unflag the visible one
        XCTAssertNil(state.session?.flagColor(for: bFile))
        XCTAssertEqual(state.session?.flaggedCount, 0)
    }

    func testUnsupportedOnlyImportClearsThePreviousSession() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let txt = try TestFixtures.makeRawFile(named: "n.txt", in: tempDir)
        let state = makeState()
        state.importFiles(urls: [a])
        await waitForScrubbing(state)
        XCTAssertNotNil(state.session)
        state.importFiles(urls: [txt])
        XCTAssertNil(state.session)
        XCTAssertNil(state.thumbWindow)
        XCTAssertNil(state.displayImages)
        XCTAssertEqual(state.phase, .empty)
        XCTAssertEqual(state.importFailures.count, 1)
    }

    func testSuccessfulCommitDeletesTheCachedPreview() async throws {
        let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
        let state = makeState()
        state.importFiles(urls: [a])
        await waitForScrubbing(state)
        let file = state.session!.allFiles[0]
        let preview = try cache.cacheURL(for: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))
        state.handle(.toggleFlag(.red))
        state.requestCommit(color: .red)
        await state.confirmCommit()
        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: preview.path), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path))
    }
}
