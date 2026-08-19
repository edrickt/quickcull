import Foundation
import SwiftUI

public enum FlagColor: String, CaseIterable, Sendable, Codable, Hashable {
    case red, yellow, green
    public var displayName: String {
        switch self { case .red: "Red"; case .yellow: "Yellow"; case .green: "Green" }
    }
    public var keyCode: UInt16 {
        switch self { case .red: 6; case .yellow: 7; case .green: 8 }
    }
    public var uiColor: Color {
        switch self { case .red: .red; case .yellow: .yellow; case .green: .green }
    }
}
