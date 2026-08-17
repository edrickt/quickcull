import Foundation

/// Single source of truth for badge visibility.
/// A badge belongs to the photo, never to the placeholder container.
/// Every view (strip Canvas, grid, viewer) must use this.
public enum FlagBadgeLogic {
    /// Badge shows only when flagged AND the photo image has loaded.
    public static func shouldShow(isFlagged: Bool, hasImage: Bool) -> Bool {
        isFlagged && hasImage
    }
}
