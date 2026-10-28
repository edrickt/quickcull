import Foundation

public enum FlagColor: String, CaseIterable, Sendable, Codable, Hashable {
    case red, yellow, green
    public var displayName: String {
        switch self { case .red: "R"; case .yellow: "Y"; case .green: "G" }
    }
    /// The letter the key prints. Matched before `keyCode`, which only names the
    /// ANSI position: on AZERTY the key labelled Z is not keyCode 6.
    public var character: String {
        switch self { case .red: "z"; case .yellow: "x"; case .green: "c" }
    }
    public var keyCode: UInt16 {
        switch self { case .red: 6; case .yellow: 7; case .green: 8 }
    }
}
