import CoreGraphics
import Foundation
import XCTest
@testable import QuickCullCore

/// Window ownership across projection changes: decoded images must survive a
/// filter switch / flag drop-out, the strip must stay bounded, and the grid
/// must not decode the whole shoot at import time.
@MainActor
final class AppStateWindowRetargetTests: XCTestCase {
    private var tempDir: URL!
    private var cache: ImageCacheStore!

    override func setUp() async throws {
        tempDir = try TestFixtures.makeTempDir(name: "window-retarget")
        cache = ImageCacheStore(baseURL: tempDir.appendingPathComponent("cache", isDirectory: true))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private func waitForScrubbing(_ state: AppState) async {
        for _ in 0..<300 {
            if state.phase == .scrubbing { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("never reached scrubbing")
    }

    /// Real JPEGs, so the thumbnail path really decodes (the stub decoder
    /// produces 8×4 images and would hide the window behaviour).
    private func makeJPEGFiles(_ count: Int) throws -> [URL] {
        try (0..<count).map { index in
            let url = tempDir.appendingPathComponent(String(format: "img_%02d.jpg", index))
            try TestFixtures.writeJPEG(color: UInt8(index * 5 % 256), width: 1200, height: 800, to: url)
            return url
        }
    }

    /// Regression for the O(shoot) re-decode: flagging under a colour filter
    /// used to rebuild both windows from scratch, dropping every decoded
    /// thumbnail (30 → 0). A retarget keeps all survivors.
    func testFlagToggleUnderFilterKeepsDecodedThumbnails() async throws {
        let urls = try makeJPEGFiles(30)
        let state = AppState(decoder: ImageIODecoder(), cache: cache, trasher: StubTrasher())
        state.importFiles(urls: urls)
        await waitForScrubbing(state)
        await state.thumbWindow?.waitUntilSettled()

        // Flag all 30 red while the sequence is unchanged (All mode).
        state.setViewMode(.grid)
        state.selectAllInGrid()
        state.handle(.toggleFlag(.red))
        await state.thumbWindow?.waitUntilSettled()
        state.setViewMode(.scrub)

        state.setFilter(.red)
        await state.thumbWindow?.waitUntilSettled()
        XCTAssertEqual(state.thumbWindow?.images.count, 30, "all 30 thumbs are resident under the filter")

        // Un-flag the current photo: the projection shrinks by exactly one, so
        // only that identity's image may be dropped.
        state.handle(.toggleFlag(.red))
        XCTAssertEqual(state.session?.count, 29)
        XCTAssertEqual(state.thumbWindow?.images.count, 29,
                       "retarget must keep every surviving thumbnail decoded")
    }

    func testStripWindowStaysBoundedAndGridLoadsLazily() async throws {
        let urls = try makeJPEGFiles(90)
        let state = AppState(decoder: ImageIODecoder(), cache: cache, trasher: StubTrasher())
        state.importFiles(urls: urls)
        await waitForScrubbing(state)
        await state.thumbWindow?.waitUntilSettled()

        XCTAssertFalse(state.thumbWindow === state.gridThumbs,
                       "strip and grid are separate windows with different extents")
        XCTAssertEqual(state.gridThumbs?.images.count, 0,
                       "the grid must not decode the shoot at import time")

        // Strip window: radius 30, so at most 61 resident thumbs anywhere.
        state.setCurrentIndex(45)
        await state.thumbWindow?.waitUntilSettled()
        let resident = state.thumbWindow?.images.count ?? -1
        XCTAssertLessThanOrEqual(resident, 61, "strip memory is bounded by the window, not the shoot")
        XCTAssertGreaterThan(resident, 0)

        // Grid: a cell that appears ensures its own thumbnail.
        state.gridThumbs?.ensureLoaded(indices: [80])
        await state.gridThumbs?.waitUntilSettled()
        XCTAssertNotNil(state.gridThumbs?.image(at: 80))
    }

    /// A re-import builds fresh windows (the loaders capture that session's
    /// files); a projection change within a session retargets them.
    func testReimportBuildsFreshWindows() async throws {
        let first = try makeJPEGFiles(3)
        let state = AppState(decoder: ImageIODecoder(), cache: cache, trasher: StubTrasher())
        state.importFiles(urls: first)
        await waitForScrubbing(state)
        let windows = state.thumbWindow

        let second = try (0..<3).map { index -> URL in
            let url = tempDir.appendingPathComponent("second_\(index).jpg")
            try TestFixtures.writeJPEG(color: UInt8(index * 40 + 7), width: 1200, height: 800, to: url)
            return url
        }
        state.importFiles(urls: second)
        await waitForScrubbing(state)
        XCTAssertFalse(state.thumbWindow === windows,
                       "a re-import must rebuild windows for the new session's files")
        await state.thumbWindow?.waitUntilSettled()
        XCTAssertNotNil(state.thumbWindow?.image(at: 0), "the new session's thumbs load")
    }
}
