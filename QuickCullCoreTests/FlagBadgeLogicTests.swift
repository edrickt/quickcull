import XCTest
@testable import QuickCullCore

final class FlagBadgeLogicTests: XCTestCase {
    func testShowsOnlyWhenFlaggedAndImageLoaded() {
        XCTAssertTrue(FlagBadgeLogic.shouldShow(isFlagged: true, hasImage: true))
        XCTAssertFalse(FlagBadgeLogic.shouldShow(isFlagged: true, hasImage: false), "badge must not show on placeholder container (cb13898, 9b9dc4a regression)")
        XCTAssertFalse(FlagBadgeLogic.shouldShow(isFlagged: false, hasImage: true))
        XCTAssertFalse(FlagBadgeLogic.shouldShow(isFlagged: false, hasImage: false))
    }

    // The three tests that used to live here restated `shouldShow(isFlagged:
    // true, hasImage: false)` with local constants and claimed to cover the
    // grid/filmstrip/viewer call sites; none of them called a view, and deleting
    // `FlagBadgeLogic` would have left them green. The rule is single: a badge
    // shows only on a loaded image, which `BadgedThumbnailView` enforces
    // structurally (`hasImage` is true inside `if let image`).
}
