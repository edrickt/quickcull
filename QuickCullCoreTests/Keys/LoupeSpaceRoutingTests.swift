import XCTest
@testable import QuickCullCore

/// The app-wide Space monitor consumes every bare Space while the loupe can
/// start (including the release of a hold), and must leave the key alone
/// everywhere else. The one predicate is `AppState.canActivateLoupe`
/// (scrubbing, non-grid, rendered image, no commit/move flow in flight);
/// consuming Space anywhere else stole it from the focused control (Space
/// activates the default button in the importer) and from the grid's scroll
/// view, while producing no loupe.
final class LoupeSpaceRoutingTests: XCTestCase {
    private func consumes(canActivateLoupe: Bool,
                          command: Bool = false,
                          control: Bool = false,
                          option: Bool = false,
                          systemOwnsKeys: Bool = false,
                          isKeyUp: Bool = false,
                          isLoupeActive: Bool = false) -> Bool {
        KeyRouter.consumesLoupeSpace(hasCommand: command,
                                     hasControl: control,
                                     hasOption: option,
                                     systemOwnsKeys: systemOwnsKeys,
                                     canActivateLoupe: canActivateLoupe,
                                     isKeyUp: isKeyUp,
                                     isLoupeActive: isLoupeActive)
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

    /// A release must always end a hold that is still set. The activation
    /// context can disappear between the key-down and the key-up (the photo's
    /// preview leaves the preload window, a commit starts, the filter empties,
    /// a sheet appears), and the monitor only sees Space events: if the release
    /// passes through unconsumed the hold survives and the loupe reappears later
    /// with no key held.
    func testASpaceReleaseEndsALiveHoldWhereANewHoldCouldNotStart() {
        XCTAssertTrue(consumes(canActivateLoupe: false, isKeyUp: true, isLoupeActive: true),
                      "the release is the only chance to clear a hold whose context vanished")
        XCTAssertTrue(consumes(canActivateLoupe: false, systemOwnsKeys: true,
                               isKeyUp: true, isLoupeActive: true),
                      "a sheet that swallowed the key-down must not also strand the held state")
        XCTAssertFalse(consumes(canActivateLoupe: false, isKeyUp: true, isLoupeActive: false),
                       "no hold and no activatable loupe: the key-up belongs to the system")
    }
}
