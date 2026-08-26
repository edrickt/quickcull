import Foundation

/// Pure policy math for the sliding in-memory window (no I/O; fully testable).
/// The window is asymmetric: `behind` indices before the current image,
/// `ahead` indices after it. Culling moves forward, so the default display
/// window loads more ahead (+20) than behind (−10), center included — 31
/// images either way.
public struct WindowPolicy {
    public let behind: Int
    public let ahead: Int

    public init(behind: Int, ahead: Int) {
        self.behind = max(0, behind)
        self.ahead = max(0, ahead)
    }

    /// Symmetric window (same distance both directions).
    public init(radius: Int = 30) {
        self.init(behind: radius, ahead: radius)
    }

    /// Largest distance from current in either direction.
    public var radius: Int { max(behind, ahead) }

    /// Clamped half-open range of indices that should be resident.
    public func window(around current: Int, count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let clamped = min(max(current, 0), count - 1)
        let lower = max(clamped - behind, 0)
        let upper = min(clamped + ahead + 1, count)
        return lower..<upper
    }

    /// Load order: current index first, then outward by distance
    /// (after-neighbor before before-neighbor, each direction capped by its
    /// own side of the window).
    public func loadOrder(current: Int, count: Int) -> [Int] {
        let range = window(around: current, count: count)
        guard !range.isEmpty else { return [] }
        var order: [Int] = []
        for distance in 0...radius {
            let after = current + distance
            let before = current - distance
            if distance <= ahead, range.contains(after) { order.append(after) }
            if distance > 0, distance <= behind, range.contains(before) { order.append(before) }
        }
        return order
    }

    /// Resident indices that fall outside the desired window.
    public func toEvict(resident: Set<Int>, current: Int, count: Int) -> Set<Int> {
        let desired = Set(window(around: current, count: count))
        return resident.subtracting(desired)
    }
}
