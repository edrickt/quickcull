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

    // MARK: Asymmetric window (behind / ahead)

    func testAsymmetricWindowClampsAtEdges() {
        let policy = WindowPolicy(behind: 10, ahead: 20)
        XCTAssertEqual(policy.window(around: 50, count: 100), 40..<71)
        XCTAssertEqual(policy.window(around: 0, count: 100), 0..<21)
        XCTAssertEqual(policy.window(around: 99, count: 100), 89..<100)
        XCTAssertEqual(policy.window(around: 50, count: 100).count, 31)
        XCTAssertLessThanOrEqual(policy.window(around: 0, count: 100).count, 31)
    }

    func testAsymmetricLoadOrderStartsWithCurrentThenOutwardPerSide() {
        let policy = WindowPolicy(behind: 10, ahead: 20)
        XCTAssertEqual(policy.loadOrder(current: 50, count: 100),
                       [50, 51, 49, 52, 48, 53, 47, 54, 46, 55, 45, 56, 44,
                        57, 43, 58, 42, 59, 41, 60, 40, 61, 62, 63, 64, 65,
                        66, 67, 68, 69, 70])
    }

    func testAsymmetricLoadOrderNeverCrossesItsSide() {
        let policy = WindowPolicy(behind: 1, ahead: 3)
        XCTAssertEqual(policy.loadOrder(current: 5, count: 100), [5, 6, 4, 7, 8])
    }
}
