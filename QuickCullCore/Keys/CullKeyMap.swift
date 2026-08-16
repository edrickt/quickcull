import Foundation

/// Actions the scrub UI responds to.
public enum CullAction: Equatable {
    case next
    case previous
    case jumpForward
    case jumpBack
    case toggleFlag
}

/// Pure mapping from macOS virtual key codes to cull actions.
/// Using keyCode (not characters) makes Z work regardless of shift/caps.
public enum CullKeyMap {
    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124
    private static let downArrow: UInt16 = 125
    private static let upArrow: UInt16 = 126
    private static let zKey: UInt16 = 6

    public static func action(forKeyCode keyCode: UInt16) -> CullAction? {
        switch keyCode {
        case leftArrow: return .previous
        case rightArrow: return .next
        case downArrow: return .jumpForward
        case upArrow: return .jumpBack
        case zKey: return .toggleFlag
        default: return nil
        }
    }
}
