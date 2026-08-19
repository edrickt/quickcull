import Foundation

public protocol Moving: Sendable {
    func move(from: URL, to: URL) throws
}

public struct FileManagerMover: Moving {
    public init() {}
    public func move(from: URL, to: URL) throws {
        try FileManager.default.moveItem(at: from, to: to)
    }
}

public struct MoveOutcome {
    public let file: SessionFile
    public let error: Error?
    public var succeeded: Bool { error == nil }
    public init(file: SessionFile, error: Error?) {
        self.file = file
        self.error = error
    }
}

public struct MoveCommit {
    private let mover: Moving
    public init(mover: Moving) { self.mover = mover }

    public func autoRenamedDestination(for file: SessionFile, in folder: URL) -> URL {
        let base = file.url.deletingPathExtension().lastPathComponent
        let ext = file.url.pathExtension
        var candidate = folder.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }

    public func commit(files: [SessionFile], to folder: URL) -> [MoveOutcome] {
        files.map { file in
            let dest = autoRenamedDestination(for: file, in: folder)
            do {
                try mover.move(from: file.url, to: dest)
                return MoveOutcome(file: file, error: nil)
            } catch {
                return MoveOutcome(file: file, error: error)
            }
        }
    }
}
