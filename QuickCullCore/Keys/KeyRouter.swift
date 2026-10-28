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
///
/// `hasSheet` covers SwiftUI's `.fileImporter`, which AppKit presents as a
/// sheet: it does not set `NSApp.modalWindow`, so without this the import
/// panel's arrow keys and Space (Quick Look) were consumed as cull keys.
public enum KeyRouter {
    public static func outcome(keyCode: UInt16,
                               characters: String? = nil,
                               hasCommand: Bool,
                               hasControl: Bool,
                               hasOption: Bool,
                               hasModalWindow: Bool,
                               hasSheet: Bool = false,
                               isEditingText: Bool) -> KeyEventOutcome {
        guard !hasModalWindow, !hasSheet, !isEditingText else { return .passthrough }
        // Select-all in grid: Cmd+A or Ctrl+A, accepted either way for muscle
        // memory. Key code 0 is the physical A key on QWERTY; the printed letter
        // covers layouts (AZERTY, Dvorak) where A is somewhere else.
        let isSelectAllChord = keyCode == 0 || characters?.lowercased() == "a"
        if isSelectAllChord, (hasCommand || hasControl), !hasOption { return .selectAll }
        guard !hasCommand, !hasControl, !hasOption else { return .passthrough }
        // The printed letter outranks the ANSI position for flag keys: on AZERTY
        // the key labelled Z is keyCode 13 and keyCode 6 is labelled W, so
        // position matching flagged on the wrong key while the advertised one
        // did nothing. Arrows have no letter and fall through to the key code.
        if let characters, let action = CullKeyMap.action(forCharacter: characters) {
            return .handle(action)
        }
        // A Latin character that is not a flag letter must not fall back to the
        // ANSI position either: pressing the key labelled W on AZERTY sends
        // keyCode 6, and flagging red from that would be the same bug inverted.
        // Restricted to ASCII on purpose: on a Cyrillic or Greek input source
        // keyCode 6 prints a local letter, and there the ANSI position is the
        // only mapping the user's keyboard legend can agree with.
        if let characters, characters.count == 1,
           let scalar = characters.unicodeScalars.first,
           scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
            return .passthrough
        }
        guard let action = CullKeyMap.action(forKeyCode: keyCode) else { return .passthrough }
        return .handle(action)
    }
}
