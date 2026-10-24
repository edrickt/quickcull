import Foundation

/// What the app does with a keyDown it observes.
public enum KeyEventOutcome: Equatable {
    case handle(CullAction)
    case selectAll
    case passthrough
}

/// Routing decision for the app-wide key monitor, as a pure function so the
/// rules are testable without AppKit.
///
/// Two classes of key must reach the system instead of the cull UI:
/// command/control/option chords (Cmd+Z undo, Cmd+X cut, Ctrl+arrow spaces)
/// and every key typed into a modal or a text field. Flag keys are matched by
/// key code, so without this Cmd+Z would flag red, and the folder picker would
/// never receive the letters of a new folder name.
public enum KeyRouter {
    public static func outcome(keyCode: UInt16,
                               hasCommand: Bool,
                               hasControl: Bool,
                               hasOption: Bool,
                               hasModalWindow: Bool,
                               isEditingText: Bool) -> KeyEventOutcome {
        guard !hasModalWindow, !isEditingText else { return .passthrough }
        // Select-all in grid: Cmd+A or Ctrl+A, accepted either way for muscle
        // memory. Key code 0 is the physical A key, which is also how the flag
        // keys are matched.
        if keyCode == 0, (hasCommand || hasControl), !hasOption { return .selectAll }
        guard !hasCommand, !hasControl, !hasOption else { return .passthrough }
        guard let action = CullKeyMap.action(forKeyCode: keyCode) else { return .passthrough }
        return .handle(action)
    }
}
