import CoreGraphics
import XCTest
@testable import QuickCullCore

/// Regression coverage for the two-finger-pan hit-test. The bug these tests
/// pin: `NSEvent.mouseLocation` (screen coordinates, y up) was compared
/// directly against `frame(in: .global)` (window coordinates, y down), so
/// pan only worked when the window happened to sit near the screen origin.
final class WindowHitTestTests: XCTestCase {
    /// Values measured on a real 1920×1080 screen with the window at (400,200),
    /// content 600×400 and a 32pt title bar: the SwiftUI `.global` frame reports
    /// (0,32,600,400) for that content, and the window frame is (400,200,600,432).
    private let windowFrame = CGRect(x: 400, y: 200, width: 600, height: 432)
    /// A pane smaller than the content area (50,60)-(450,360) in `.global`
    /// coordinates, so the letterbox bands around it can be tested.
    private let paneGlobalFrame = CGRect(x: 50, y: 60, width: 400, height: 300)

    func testTopLeftOfContentMapsToGlobalOriginOffsetByTitleBar() {
        // Screen point at the content view's top-left corner, in screen
        // coordinates with a bottom-left origin: y = 200 + 400 = 600.
        let screenPoint = CGPoint(x: 400, y: 600)
        XCTAssertEqual(WindowHitTest.globalPoint(fromScreen: screenPoint, windowFrame: windowFrame),
                       CGPoint(x: 0, y: 32))
    }

    func testHoverInsidePaneIsAHitWhenWindowIsOffsetFromScreenOrigin() {
        // Middle of the pane in window coordinates (300, 232) → screen (700, 400).
        let screenPoint = CGPoint(x: 700, y: 400)
        XCTAssertTrue(WindowHitTest.contains(screenPoint: screenPoint,
                                             windowFrame: windowFrame,
                                             paneGlobalFrame: paneGlobalFrame))
    }

    func testHoverOutsidePaneHorizontallyIsNotAHit() {
        // 700pt right of the pane, same vertical band.
        let screenPoint = CGPoint(x: 1300, y: 400)
        XCTAssertFalse(WindowHitTest.contains(screenPoint: screenPoint,
                                              windowFrame: windowFrame,
                                              paneGlobalFrame: paneGlobalFrame))
    }

    func testHoverOverLetterboxedAreaIsNotAHit() {
        // Inside the window and inside the content, but below the pane's
        // bottom edge (pane ends at global y 360): screen y = 632 - 400 = 232.
        let screenPoint = CGPoint(x: 600, y: 232)
        XCTAssertFalse(WindowHitTest.contains(screenPoint: screenPoint,
                                              windowFrame: windowFrame,
                                              paneGlobalFrame: paneGlobalFrame))
    }

    func testHitTestIsIndependentOfWindowPositionOnScreen() {
        let pane = CGRect(x: 0, y: 0, width: 500, height: 300)
        let panesOriginOnScreen = CGPoint(x: 900, y: 800)   // arbitrary placement
        let window = CGRect(x: panesOriginOnScreen.x, y: panesOriginOnScreen.y,
                            width: 500, height: 300)
        // Center of the pane: window coords (250, 150) → screen coords
        // (900 + 250, 800 + (300 - 150)).
        let screenPoint = CGPoint(x: panesOriginOnScreen.x + 250,
                                  y: panesOriginOnScreen.y + 150)
        XCTAssertTrue(WindowHitTest.contains(screenPoint: screenPoint,
                                             windowFrame: window,
                                             paneGlobalFrame: pane))
        // 10pt above the pane's top edge must not hit.
        let justOutside = CGPoint(x: screenPoint.x, y: panesOriginOnScreen.y + 300 + 10)
        XCTAssertFalse(WindowHitTest.contains(screenPoint: justOutside,
                                              windowFrame: window,
                                              paneGlobalFrame: pane))
    }

    /// A point already expressed in window coordinates must not be converted
    /// twice: `globalPoint` mirrors y through the window frame, so feeding it
    /// a screen point outside the window yields a point outside the pane.
    func testScreenPointOutsideWindowFrameIsNotAHit() {
        let aboveWindow = CGPoint(x: 700, y: 1000)   // above the window's top edge
        XCTAssertFalse(WindowHitTest.contains(screenPoint: aboveWindow,
                                              windowFrame: windowFrame,
                                              paneGlobalFrame: paneGlobalFrame))
    }

    /// A display arranged left of or below the main one has a negative-origin
    /// window frame; the y flip must still be measured from its own top edge.
    func testNegativeOriginWindowFrameMapsFromItsOwnTopEdge() {
        let frame = CGRect(x: -800, y: -600, width: 600, height: 432)
        let point = WindowHitTest.globalPoint(fromScreen: CGPoint(x: -800, y: -600),
                                             windowFrame: frame)
        XCTAssertEqual(point, CGPoint(x: 0, y: 432))
    }

    /// Before the first layout pass the pane reports a zero frame; no screen
    /// point may be treated as inside it.
    func testZeroSizePaneIsNeverAHit() {
        XCTAssertFalse(WindowHitTest.contains(screenPoint: CGPoint(x: 700, y: 400),
                                              windowFrame: windowFrame,
                                              paneGlobalFrame: .zero))
    }

    /// Split mode puts an 8pt gap between the panes; a point in it belongs to
    /// neither, so neither pane's scroll monitor may claim the event.
    func testSplitPaneGapBelongsToNeitherPane() {
        let left = CGRect(x: 50, y: 60, width: 400, height: 300)
        let right = CGRect(x: 458, y: 60, width: 400, height: 300)
        let gapX = left.maxX + 4
        // Screen y for window y = 210: 200 + 432 - 210 = 422.
        let screenPoint = CGPoint(x: 400 + gapX, y: 422)
        XCTAssertFalse(WindowHitTest.contains(screenPoint: screenPoint,
                                              windowFrame: windowFrame, paneGlobalFrame: left))
        XCTAssertFalse(WindowHitTest.contains(screenPoint: screenPoint,
                                              windowFrame: windowFrame, paneGlobalFrame: right))
    }
}
