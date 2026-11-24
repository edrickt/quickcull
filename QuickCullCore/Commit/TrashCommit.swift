import Foundation

public protocol Trashing: Sendable {
    func trash(url: URL) throws
}

public struct FileManagerTrasher: Trashing {
    public init() {}

    public func trash(url: URL) throws {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }
}

public struct TrashOutcome {
    public let file: SessionFile
    public let error: Error?

    public var succeeded: Bool { error == nil }

    public init(file: SessionFile, error: Error?) {
        self.file = file
        self.error = error
    }
}

/// Moves flagged files to the macOS Trash. Never throws; every file gets an
/// individual outcome so one bad volume can't abort the commit.
public struct TrashCommit {
    private let trasher: Trashing

    public init(trasher: Trashing) {
        self.trasher = trasher
    }

    public func commit(files: [SessionFile]) -> [TrashOutcome] {
        files.map { file in
            do {
                // The identity and the cache key already name the resolved
                // target; trashing the imported path would throw away a symlink
                // and leave the photo on the card (QS-04).
                try trasher.trash(url: file.resolvedURL)
                return TrashOutcome(file: file, error: nil)
            } catch {
                return TrashOutcome(file: file, error: error)
            }
        }
    }
}
