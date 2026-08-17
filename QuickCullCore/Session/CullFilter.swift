import Foundation

/// Which photos the scrub sequence shows.
public enum CullFilter: CaseIterable, Hashable, Sendable {
    /// Every photo in the session.
    case all
    /// Only photos flagged for deletion.
    case flagged
    /// Only photos not flagged for deletion.
    case keepers
}
