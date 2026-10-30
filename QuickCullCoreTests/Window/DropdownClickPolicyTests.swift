import XCTest
import CoreGraphics
@testable import QuickCullCore

/// Decides what to do with a mouse-down while a custom dropdown panel is
/// open. Native NSMenu tracking consumes the first click outside the menu
/// (closing it but swallowing the click, forcing a second press); the
/// custom dropdown in ScrubView uses this policy to close the panel AND
/// pass the click through so the first press lands.
final class DropdownClickPolicyTests: XCTestCase {
    private let panel = CGRect(x: 100, y: 100, width: 240, height: 160)
    private let toggle = CGRect(x: 50, y: 50, width: 120, height: 28)

    func testClickInsidePanelIsIgnoredSoPanelControlsHandleIt() {
        let policy = DropdownClickPolicy.classify(
            click: CGPoint(x: 200, y: 150), panel: panel, toggle: toggle)
        XCTAssertEqual(policy, .ignore)
    }

    func testClickOnToggleIsConsumedSoItClosesWithoutReopening() {
        let policy = DropdownClickPolicy.classify(
            click: CGPoint(x: 80, y: 64), panel: panel, toggle: toggle)
        XCTAssertEqual(policy, .consume)
    }

    func testClickElsewherePassesThroughSoTheFirstPressLands() {
        let policy = DropdownClickPolicy.classify(
            click: CGPoint(x: 400, y: 300), panel: panel, toggle: toggle)
        XCTAssertEqual(policy, .passThrough)
    }

    func testOverlappingPanelAndTogglePanelWins() {
        let overlappingToggle = CGRect(x: 150, y: 150, width: 200, height: 200)
        let policy = DropdownClickPolicy.classify(
            click: CGPoint(x: 250, y: 250), panel: panel, toggle: overlappingToggle)
        XCTAssertEqual(policy, .ignore)
    }

    func testClickInGapBetweenPanelAndTogglePassesThrough() {
        // The strip between the toggle and the panel is empty space, not
        // part of the dropdown: the click must land where it points.
        let policy = DropdownClickPolicy.classify(
            click: CGPoint(x: 60, y: 95), panel: panel, toggle: toggle)
        XCTAssertEqual(policy, .passThrough)
    }

    func testClickOnPanelTrailingEdgeIsOutsidePanel() {
        // CGRect.contains excludes the trailing edges; the click must not
        // be treated as inside the panel.
        let policy = DropdownClickPolicy.classify(
            click: CGPoint(x: panel.maxX, y: 150), panel: panel, toggle: toggle)
        XCTAssertNotEqual(policy, .ignore)
    }

    /// `FrameAnchor` reports the panel frame from the AppKit layout pass, so a
    /// click that arrives before it does gives an empty panel rect. Nothing may be
    /// classified as "inside the panel" then, or the click would be swallowed
    /// and the panel would stay open.
    func testZeroSizePanelClassifiesNothingAsInside() {
        let policy = DropdownClickPolicy.classify(
            click: CGPoint(x: 200, y: 150), panel: .zero, toggle: toggle)
        XCTAssertEqual(policy, .passThrough)
    }
}
