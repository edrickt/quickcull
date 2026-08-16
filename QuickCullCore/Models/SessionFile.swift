import Foundation

/// One raw file in a culling session.
public struct SessionFile: Identifiable, Hashable, Sendable {
    public let url: URL
    public let id: String

    public init(url: URL) {
        self.url = url
        self.id = RawFileIdentity.fileID(for: url)
    }
}
