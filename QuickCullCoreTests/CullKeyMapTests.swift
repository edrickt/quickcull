import XCTest
@testable import QuickCullCore

final class CullKeyMapTests: XCTestCase {
    func testArrowKeys() {
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 123), .previous)  // left
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 124), .next)      // right
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 125), .jumpForward)  // down
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 126), .jumpBack)     // up
    }

    func testZKey() {
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 6), .toggleFlag(.red))  // 'z' physical key
    }

    func testUnknownKeysAreIgnored() {
        for code: UInt16 in [0, 1, 3, 36, 49, 122] {
            XCTAssertNil(CullKeyMap.action(forKeyCode: code))
        }
    }
}
