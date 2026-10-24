import XCTest
@testable import QuickCullCore

final class KeyRouterTests: XCTestCase {
    private func route(_ keyCode: UInt16,
                       command: Bool = false, control: Bool = false, option: Bool = false,
                       modal: Bool = false, editingText: Bool = false) -> KeyEventOutcome {
        KeyRouter.outcome(keyCode: keyCode, hasCommand: command, hasControl: control,
                          hasOption: option, hasModalWindow: modal, isEditingText: editingText)
    }

    func testPlainCullKeysAreHandled() {
        XCTAssertEqual(route(123), .handle(.previous))
        XCTAssertEqual(route(124), .handle(.next))
        XCTAssertEqual(route(125), .handle(.jumpForward))
        XCTAssertEqual(route(126), .handle(.jumpBack))
        XCTAssertEqual(route(6), .handle(.toggleFlag(.red)))
        XCTAssertEqual(route(7), .handle(.toggleFlag(.yellow)))
        XCTAssertEqual(route(8), .handle(.toggleFlag(.green)))
    }

    func testCommandChordsReachTheSystem() {
        // Cmd+Z must undo, not flag red; Cmd+C/X must copy/cut.
        XCTAssertEqual(route(6, command: true), .passthrough)
        XCTAssertEqual(route(8, command: true), .passthrough)
        XCTAssertEqual(route(123, command: true), .passthrough)
    }

    func testControlAndOptionChordsReachTheSystem() {
        XCTAssertEqual(route(6, control: true), .passthrough)
        XCTAssertEqual(route(6, option: true), .passthrough)
        XCTAssertEqual(route(123, control: true), .passthrough)
    }

    func testSelectAllAcceptsCommandOrControl() {
        XCTAssertEqual(route(0, command: true), .selectAll)
        XCTAssertEqual(route(0, control: true), .selectAll)
    }

    func testModalAndTextEditingGetEveryKeyUntouched() {
        // The folder picker runs a modal: its letters and arrows must not scrub
        // or flag the session behind it.
        XCTAssertEqual(route(6, modal: true), .passthrough)
        XCTAssertEqual(route(124, modal: true), .passthrough)
        XCTAssertEqual(route(0, command: true, modal: true), .passthrough)
        XCTAssertEqual(route(6, editingText: true), .passthrough)
        XCTAssertEqual(route(124, editingText: true), .passthrough)
    }

    func testUnmappedKeysPassThrough() {
        XCTAssertEqual(route(36), .passthrough)   // Return
        XCTAssertEqual(route(53), .passthrough)   // Escape
    }
}
