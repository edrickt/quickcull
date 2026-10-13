import Foundation

/// Which photos the scrub sequence shows. An option set: any combination of
/// `red`, `yellow`, `green`, and `keepers` can be active at once. The empty
/// set (`.all`) means no restriction — every file matches — so membership
/// tests should use `isEmpty` (`contains(.all)` is always false).
public struct CullFilter: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    /// No restriction: every file matches.
    public static let all: CullFilter = []
    public static let red = CullFilter(rawValue: 1 << 0)
    public static let yellow = CullFilter(rawValue: 1 << 1)
    public static let green = CullFilter(rawValue: 1 << 2)
    public static let keepers = CullFilter(rawValue: 1 << 3) // unflagged

    /// The single filter component matching a flag state (`nil` = unflagged).
    public init(matching flag: FlagColor?) {
        switch flag {
        case .red: self = .red
        case .yellow: self = .yellow
        case .green: self = .green
        case nil: self = .keepers
        }
    }
}
