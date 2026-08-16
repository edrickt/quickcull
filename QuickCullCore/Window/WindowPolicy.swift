import Foundation

/// Pure policy math for the sliding in-memory window (no I/O; fully testable).
public struct WindowPolicy {
    public let radius: Int

    public init(radius: Int = 30) {
        self.radius = radius
    }

    /// Clamped half-open range of indices that should be resident.
    public func window(around current: Int, count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let clamped = min(max(current, 0), count - 1)
        let lower = max(clamped - radius, 0)
        let upper = min(clamped + radius + 1, count)
        return lower..<upper
    }

    /// Load order: current index first, then outward by distance
    /// (after-neighbor before before-neighbor).
    public func loadOrder(current: Int, count: Int) -> [Int] {
        let range = window(around: current, count: count)
        guard !range.isEmpty else { return [] }
        var order: [Int] = []
        for distance in 0...radius {
            let after = current + distance
            let before = current - distance
            if range.contains(after) { order.append(after) }
            if distance > 0, range.contains(before) { order.append(before) }
        }
        return order
    }

    /// Resident indices that fall outside the desired window.
    public func toEvict(resident: Set<Int>, current: Int, count: Int) -> Set<Int> {
        let desired = Set(window(around: current, count: count))
        return resident.subtracting(desired)
    }
}
