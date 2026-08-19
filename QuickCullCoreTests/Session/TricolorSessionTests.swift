import XCTest
@testable import QuickCullCore

@MainActor
final class TricolorSessionTests: XCTestCase {
    func testExclusiveToggle() {
        let files = TestFixtures.makeFiles(["a.jpg","b.jpg"])
        let s = Session(files: files)
        _ = s.toggleFlag(color: .red) // a red
        XCTAssertEqual(s.flagColor(for: files[0]), .red)
        XCTAssertEqual(s.flaggedCount(.red), 1)
        _ = s.toggleFlag(color: .red) // same key toggles off
        XCTAssertNil(s.flagColor(for: files[0]))
        XCTAssertEqual(s.flaggedCount(), 0)
        _ = s.toggleFlag(color: .red)
        _ = s.toggleFlag(color: .yellow) // X on red → yellow replaces
        XCTAssertEqual(s.flagColor(for: files[0]), .yellow)
        XCTAssertEqual(s.flaggedCount(.red), 0)
        XCTAssertEqual(s.flaggedCount(.yellow), 1)
    }
    func testFilterProjections() {
        var files = TestFixtures.makeFiles(["a.jpg","b.jpg","c.jpg","d.jpg"])
        let s = Session(files: files)
        _ = s.toggleFlag(color: .red) // a red
        s.move(by: 1); _ = s.toggleFlag(color: .yellow) // b yellow
        s.move(by: 1); _ = s.toggleFlag(color: .green) // c green
        // d unflagged
        s.setFilter(.red); XCTAssertEqual(s.files.count, 1); XCTAssertEqual(s.files[0].id, files[0].id)
        s.setFilter(.yellow); XCTAssertEqual(s.files.count, 1)
        s.setFilter(.green); XCTAssertEqual(s.files.count, 1)
        s.setFilter(.keepers); XCTAssertEqual(s.files.count, 1) // d
        s.setFilter(.all); XCTAssertEqual(s.files.count, 4)
        XCTAssertEqual(s.flaggedCount(.red), 1); XCTAssertEqual(s.flaggedCount(.yellow), 1); XCTAssertEqual(s.flaggedCount(.green), 1)
        XCTAssertEqual(s.flaggedCount(), 3)
        XCTAssertEqual(s.flaggedFiles(.red).count, 1)
        XCTAssertEqual(s.flaggedFiles().count, 3)
    }
    func testRemovePerColorLeavesOthers() {
        let files = TestFixtures.makeFiles(["a.jpg","b.jpg","c.jpg"])
        let s = Session(files: files)
        _ = s.toggleFlag(color: .red) // a
        s.move(by:1); _ = s.toggleFlag(color: .yellow) // b
        s.move(by:1); _ = s.toggleFlag(color: .green) // c
        s.remove(s.flaggedFiles(.red))
        XCTAssertEqual(s.flaggedCount(.red), 0)
        XCTAssertEqual(s.flaggedCount(.yellow), 1)
        XCTAssertEqual(s.flaggedCount(), 2)
        XCTAssertEqual(s.allFiles.count, 2)
    }
}
