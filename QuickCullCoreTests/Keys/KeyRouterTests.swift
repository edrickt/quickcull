import XCTest
@testable import QuickCullCore

final class KeyRouterTests: XCTestCase {
    private func route(_ keyCode: UInt16, characters: String? = nil,
                       command: Bool = false, control: Bool = false, option: Bool = false,
                       modal: Bool = false, sheet: Bool = false, editingText: Bool = false) -> KeyEventOutcome {
        KeyRouter.outcome(keyCode: keyCode, characters: characters,
                          hasCommand: command, hasControl: control,
                          hasOption: option, hasModalWindow: modal, hasSheet: sheet,
                          isEditingText: editingText)
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

    /// README tells the user to press Z/X/C. On a non-QWERTY layout those letters
    /// are not on the ANSI positions the key codes name, so the printed letter
    /// must win for flag keys (and a non-flag letter must not fall back to the
    /// position, or AZERTY's W would flag red).
    func testFlagKeysFollowThePrintedLetterNotTheKeyPosition() {
        XCTAssertEqual(route(13, characters: "z"), .handle(.toggleFlag(.red)))
        XCTAssertEqual(route(13, characters: "Z"), .handle(.toggleFlag(.red)))
        XCTAssertEqual(route(6, characters: "w"), .passthrough, "AZERTY W sits on ANSI Z")
        XCTAssertEqual(route(7, characters: "x"), .handle(.toggleFlag(.yellow)))
        XCTAssertEqual(route(8, characters: "c"), .handle(.toggleFlag(.green)))
    }

    /// A non-Latin input source (Cyrillic, Greek, Hebrew…) prints a local letter
    /// on the ANSI positions: the printed character cannot match a flag, so the
    /// position must still work rather than disabling Z/X/C entirely.
    func testNonLatinInputSourceStillFlagsByPosition() {
        XCTAssertEqual(route(6, characters: "я"), .handle(.toggleFlag(.red)))
        XCTAssertEqual(route(7, characters: "ч"), .handle(.toggleFlag(.yellow)))
        XCTAssertEqual(route(8, characters: "с"), .handle(.toggleFlag(.green)))
    }

    /// Cmd+A is select-all on any layout, not only where A is keyCode 0.
    func testSelectAllFollowsTheLetterOnOtherLayouts() {
        XCTAssertEqual(route(0, characters: "q", command: true), .selectAll, "AZERTY: A is on Q")
        XCTAssertEqual(route(0, characters: "a", command: true), .selectAll)
        XCTAssertEqual(route(0, characters: "q", command: true, modal: true), .passthrough)
    }

    /// Arrows carry a private-use character, not a letter: they still route by
    /// key code, which is layout-independent for them.
    func testArrowKeysStillRouteByKeyCode() {
        XCTAssertEqual(route(123, characters: "\u{F702}"), .handle(.previous))
        XCTAssertEqual(route(124, characters: "\u{F703}"), .handle(.next))
    }

    /// The import panel is a sheet, which does not set `NSApp.modalWindow`:
    /// without the sheet flag its arrow keys scrubbed and Space was swallowed
    /// instead of opening Quick Look.
    func testSheetKeysReachThePanel() {
        XCTAssertEqual(route(124, characters: "\u{F703}", sheet: true), .passthrough)
        XCTAssertEqual(route(6, characters: "z", sheet: true), .passthrough)
        XCTAssertEqual(route(0, characters: "a", command: true, sheet: true), .passthrough)
    }
}
