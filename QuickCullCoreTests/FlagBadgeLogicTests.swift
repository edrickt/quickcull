import XCTest
@testable import QuickCullCore

final class FlagBadgeLogicTests: XCTestCase {
    func testShowsOnlyWhenFlaggedAndImageLoaded() {
        XCTAssertTrue(FlagBadgeLogic.shouldShow(isFlagged: true, hasImage: true))
        XCTAssertFalse(FlagBadgeLogic.shouldShow(isFlagged: true, hasImage: false), "badge must not show on placeholder container (cb13898, 9b9dc4a regression)")
        XCTAssertFalse(FlagBadgeLogic.shouldShow(isFlagged: false, hasImage: true))
        XCTAssertFalse(FlagBadgeLogic.shouldShow(isFlagged: false, hasImage: false))
    }

    func testGridCellRequiresImage() {
        // GridCell uses BadgedThumbnailView which delegates to FlagBadgeLogic.
        // A flagged file without a loaded thumbnail must not badge.
        let isFlagged = true
        let hasImage = false
        XCTAssertFalse(FlagBadgeLogic.shouldShow(isFlagged: isFlagged, hasImage: hasImage),
                       "Grid badge belongs to image, not 160x108 placeholder (grid view regression)")
    }

    func testFilmstripCanvasRequiresImage() {
        // Filmstrip Canvas must skip flagged cells whose image hasn't loaded.
        let isFlagged = true
        let hasImage = false
        XCTAssertFalse(FlagBadgeLogic.shouldShow(isFlagged: isFlagged, hasImage: hasImage),
                       "Strip badge must wait for photo (9b9dc4a regression)")
    }

    func testViewerFallbackRequiresImage() {
        // Viewer flag overlay sits on Image branch only; ProgressView branch has no image.
        XCTAssertTrue(FlagBadgeLogic.shouldShow(isFlagged: true, hasImage: true))
        XCTAssertFalse(FlagBadgeLogic.shouldShow(isFlagged: true, hasImage: false))
    }
}
