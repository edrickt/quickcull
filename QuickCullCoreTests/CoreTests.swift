import XCTest
@testable import QuickCullCore

final class CoreTests: XCTestCase {
    func testAnswer() {
        XCTAssertEqual(Core.answer, 42)
    }
}
