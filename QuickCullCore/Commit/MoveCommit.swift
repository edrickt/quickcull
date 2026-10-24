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
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            candidate = folder.appendingPathComponent(name)
            suffix += 1
        }
        return candidate
    }

    public func commit(files: [SessionFile], to folder: URL) -> [MoveOutcome] {
        let destination = folder.standardizedFileURL
        return files.map { file in
            // A move into the folder the file already lives in is a no-op.
            // Without this the collision suffix below finds the file itself at
            // the destination and renames every original to "name 1.ext" in
            // place — a mass rename the user never asked for.
            if file.url.deletingLastPathComponent().standardizedFileURL.path == destination.path {
                return MoveOutcome(file: file, error: nil)
            }
            let base = file.url.deletingPathExtension().lastPathComponent
            let ext = file.url.pathExtension
            var dest = autoRenamedDestination(for: file, in: folder)
            // Derive next suffix for TOCTOU retry: dest is .../base.ext or .../base N.ext
            var nextSuffix: Int = 1
            let baseName = ext.isEmpty ? base : "\(base).\(ext)"
            if dest.lastPathComponent != baseName {
                let nameNoExt = dest.deletingPathExtension().lastPathComponent
                if nameNoExt.hasPrefix(base + " ") {
                    let suffixStr = String(nameNoExt.dropFirst(base.count + 1))
                    if let parsed = Int(suffixStr) { nextSuffix = parsed + 1 }
                }
            }
            var attempts = 0
            while attempts < 100 {
                do {
                    try mover.move(from: file.url, to: dest)
                    return MoveOutcome(file: file, error: nil)
                } catch let cocoaError as NSError
                            where cocoaError.domain == NSCocoaErrorDomain
                            && cocoaError.code == NSFileWriteFileExistsError {
                    // TOCTOU: destination was created between check and move — retry with next suffix.
                    let name = ext.isEmpty ? "\(base) \(nextSuffix)" : "\(base) \(nextSuffix).\(ext)"
                    dest = folder.appendingPathComponent(name)
                    nextSuffix += 1
                    attempts += 1
                    continue
                } catch {
                    return MoveOutcome(file: file, error: error)
                }
            }
            return MoveOutcome(
                file: file,
                error: NSError(
                    domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                    userInfo: [NSLocalizedDescriptionKey: "Move failed after retries: destination exists"]))
        }
    }
}
