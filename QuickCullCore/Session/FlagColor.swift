import Foundation

public enum FlagColor: String, CaseIterable, Sendable, Codable, Hashable {
    case red, yellow, green
    public var displayName: String {
        switch self { case .red: "R"; case .yellow: "Y"; case .green: "G" }
    }
    public var keyCode: UInt16 {
        switch self { case .red: 6; case .yellow: 7; case .green: 8 }
    }
}
