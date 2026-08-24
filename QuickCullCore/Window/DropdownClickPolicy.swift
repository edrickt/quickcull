import Foundation
import CoreGraphics

/// What to do with a mouse-down that arrives while a custom dropdown panel
/// is open.
///
/// Native NSMenu tracking consumes the first click outside an open menu:
/// the menu closes but the click never reaches the control underneath,
/// so the user has to press a second time. QuickCull's dropdowns are
/// custom panels (see DropdownMenu) precisely to avoid that; this policy
/// classifies each outside click so the panel can close and, where
/// appropriate, let the same click land.
public enum DropdownClickPolicy: Equatable {
    /// The click is inside the open panel — let the panel's items handle it.
    case ignore
    /// The click is on the dropdown's own toggle button — close without
    /// re-toggling (the same press must not immediately reopen the panel).
    case consume
    /// The click is anywhere else — close the panel and pass the click
    /// through so the first press activates the control underneath.
    case passThrough

    /// - Parameters:
    ///   - click: the mouse-down location in screen coordinates.
    ///   - panel: the open panel's frame in screen coordinates.
    ///   - toggle: the dropdown button's frame in screen coordinates.
    public static func classify(click: CGPoint, panel: CGRect, toggle: CGRect) -> DropdownClickPolicy {
        if panel.contains(click) { return .ignore }
        if toggle.contains(click) { return .consume }
        return .passThrough
    }
}
