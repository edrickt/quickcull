import SwiftUI
import QuickCullCore

extension FlagColor {
    var uiColor: Color {
        switch self {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        }
    }
}
