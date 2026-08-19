import Foundation

/// Which photos the scrub sequence shows.
public enum CullFilter: CaseIterable, Hashable, Sendable {
    case all
    case red
    case yellow
    case green
    case keepers // unflagged
}
