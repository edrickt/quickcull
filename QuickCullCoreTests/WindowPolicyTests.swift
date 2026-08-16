import XCTest
@testable import QuickCullCore

final class WindowPolicyTests: XCTestCase {
    func testWindowClampsAtEdges() {
        let policy = WindowPolicy(radius: 30)
        XCTAssertEqual(policy.window(around: 0, count: 100), 0..<31)
        XCTAssertEqual(policy.window(around: 99, count: 100), 69..<100)
    }

    func testWindowNeverExceedsRadius() {
        let policy = WindowPolicy(radius: 30)
        for current in [0, 1, 50, 98, 99] {
            let window = policy.window(around: current, count: 100)
            XCTAssertLessThanOrEqual(window.count, 61)
        }
    }

    func testWindowEmptyWhenNoFiles() {
        let policy = WindowPolicy(radius: 30)
        XCTAssertTrue(policy.window(around: 0, count: 0).isEmpty)
    }

    func testLoadOrderStartsWithCurrentThenOutward() {
        let policy = WindowPolicy(radius: 2)
        XCTAssertEqual(policy.loadOrder(current: 5, count: 100),
                       [5, 6, 4, 7, 3])
    }

    func testToEvictOutsideWindow() {
        let policy = WindowPolicy(radius: 1)
        let resident: Set<Int> = [0, 1, 2, 3, 99]
        XCTAssertEqual(policy.toEvict(resident: resident, current: 1, count: 100),
                       Set([3, 99]))
    }
}
