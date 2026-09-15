import CoreGraphics
import Foundation

/// Maps between AppKit screen coordinates and SwiftUI's `.global` coordinate
/// space so a pane's `frame(in: .global)` can be hit-tested against the mouse.
///
/// The two spaces disagree on both origin and direction:
/// - `NSEvent.mouseLocation` is **screen** coordinates: origin at the
///   bottom-left of the screen, y growing upward.
/// - `GeometryProxy.frame(in: .global)` on macOS is **window** coordinates:
///   origin at the top-left of the window's frame (title bar included), y
///   growing downward.
///
/// Comparing the two directly makes the hit-test depend on where the window
/// happens to sit on screen, so the caller must convert first.
public enum WindowHitTest {
    /// Converts a screen-space point into the window-relative, top-left
    /// origin, y-down space that `frame(in: .global)` reports.
    ///
    /// - Parameters:
    ///   - screenPoint: point in screen coordinates (e.g. `NSEvent.mouseLocation`).
    ///   - windowFrame: the window's frame in screen coordinates, title bar
    ///     included (e.g. `NSWindow.frame`). Its height and origin define the
    ///     `.global` origin: a point on the window frame's top edge maps to `y == 0`.
    public static func globalPoint(fromScreen screenPoint: CGPoint, windowFrame: CGRect) -> CGPoint {
        CGPoint(x: screenPoint.x - windowFrame.minX,
                y: windowFrame.maxY - screenPoint.y)
    }

    /// True when the screen-space point falls inside `paneGlobalFrame`.
    public static func contains(screenPoint: CGPoint,
                               windowFrame: CGRect,
                               paneGlobalFrame: CGRect) -> Bool {
        paneGlobalFrame.contains(globalPoint(fromScreen: screenPoint, windowFrame: windowFrame))
    }
}
