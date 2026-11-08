import XCTest
@testable import QuickCullCore

/// The app-wide Space monitor consumes every bare Space while the loupe can
/// start, and must leave the key alone everywhere else. The one predicate is
/// `AppState.canActivateLoupe` (scrubbing, non-grid, rendered image, no
/// commit/move in flight); consuming Space anywhere else stole it from the
/// focused control (Space activates the default button in the importer) and
/// from the grid's scroll view, while producing no loupe.
final class LoupeSpaceRoutingTests: XCTestCase {
    private func consumes(canActivateLoupe: Bool,
                          command: Bool = false,
                          control: Bool = false,
                          option: Bool = false,
                          systemOwnsKeys: Bool = false) -> Bool {
        KeyRouter.consumesLoupeSpace(hasCommand: command,
                                     hasControl: control,
                                     hasOption: option,
                                     systemOwnsKeys: systemOwnsKeys,
                                     canActivateLoupe: canActivateLoupe)
    }

    func testBareSpaceBelongsToTheLoupeWhenItCanActivate() {
        XCTAssertTrue(consumes(canActivateLoupe: true))
    }

    func testSpacePassesThroughWhereTheLoupeCannotStart() {
        XCTAssertFalse(consumes(canActivateLoupe: false),
                       "importer, decoding, grid, filtered-empty, commit and move: "
                           + "no loupe can start, so Space must reach the focused control")
    }

    func testChordedSpaceReachesTheSystem() {
        XCTAssertFalse(consumes(canActivateLoupe: true, command: true),
                       "Cmd+Space is Spotlight")
        XCTAssertFalse(consumes(canActivateLoupe: true, control: true),
                       "Ctrl+Space is the input-source switch")
        XCTAssertFalse(consumes(canActivateLoupe: true, option: true))
    }

    func testSpacePassesThroughWhenAModalOrTextEditingOwnsKeys() {
        XCTAssertFalse(consumes(canActivateLoupe: true, systemOwnsKeys: true),
                       "a modal, sheet, or text field owns every key, Space included")
    }
}
