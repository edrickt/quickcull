import XCTest
@testable import QuickCullCore

final class CullKeyMapTricolorTests: XCTestCase {
    func testZXYMapping() {
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 6), .toggleFlag(.red))
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 7), .toggleFlag(.yellow))
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 8), .toggleFlag(.green))
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 123), .previous)
        XCTAssertNil(CullKeyMap.action(forKeyCode: 99))
    }
}
