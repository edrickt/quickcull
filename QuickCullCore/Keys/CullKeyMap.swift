import Foundation

/// Actions the scrub UI responds to.
public enum CullAction: Equatable {
    case next
    case previous
    case jumpForward
    case jumpBack
    case toggleFlag(FlagColor)
}

/// Pure mapping from macOS virtual key codes to cull actions.
/// Using keyCode (not characters) makes Z work regardless of shift/caps.
public enum CullKeyMap {
    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124
    private static let downArrow: UInt16 = 125
    private static let upArrow: UInt16 = 126

    public static func action(forKeyCode keyCode: UInt16) -> CullAction? {
        switch keyCode {
        case leftArrow: return .previous
        case rightArrow: return .next
        case downArrow: return .jumpForward
        case upArrow: return .jumpBack
        default:
            // Flag keys live on `FlagColor` so the key map and the colour
            // legends can never drift apart.
            return FlagColor.allCases
                .first { $0.keyCode == keyCode }
                .map { .toggleFlag($0) }
        }
    }

    /// The letter a key prints, case-insensitively (`Z`, `z`, and Caps Lock all
    /// match). This outranks `forKeyCode` on non-QWERTY layouts, where the key
    /// labelled `Z` is not on the ANSI Z position: README tells the user to
    /// press Z, so the key that says Z is the key that must flag red.
    public static func action(forCharacter character: String) -> CullAction? {
        guard character.count == 1 else { return nil }
        let letter = character.lowercased()
        return FlagColor.allCases
            .first { $0.character == letter }
            .map { .toggleFlag($0) }
    }
}
