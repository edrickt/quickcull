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

public enum MoveError: Error, Equatable {
    /// The file already lives in the destination folder. Nothing was moved, so
    /// reporting success would let the session discard a photo that is still
    /// on disk (QS-03).
    case sameDirectory
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
        let base = file.resolvedURL.deletingPathExtension().lastPathComponent
        let ext = file.resolvedURL.pathExtension
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
            // A move into the folder the file already lives in moves nothing.
            // Without this check the collision suffix below finds the file
            // itself at the destination and renames every original to
            // "name 1.ext" in place — a mass rename the user never asked for.
            // It is still not a success: the session removes every successful
            // outcome, which silently dropped photos that never moved (QS-03).
            let source = file.resolvedURL
            if Self.isSameDirectory(source.deletingLastPathComponent(), destination) {
                return MoveOutcome(file: file, error: MoveError.sameDirectory)
            }
            let base = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            var dest = autoRenamedDestination(for: file, in: destination)
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
                    try mover.move(from: source, to: dest)
                    return MoveOutcome(file: file, error: nil)
                } catch let cocoaError as NSError
                            where cocoaError.domain == NSCocoaErrorDomain
                            && cocoaError.code == NSFileWriteFileExistsError {
                    // TOCTOU: destination was created between check and move — retry with next suffix.
                    let name = ext.isEmpty ? "\(base) \(nextSuffix)" : "\(base) \(nextSuffix).\(ext)"
                    dest = destination.appendingPathComponent(name)
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

    /// True when both URLs name the same directory on disk.
    ///
    /// Spelling is not identity: `standardizedFileURL` removes `..` and
    /// trailing slashes but resolves neither symlinks nor case, so a source
    /// imported through an alias and a destination picked in its target folder
    /// compared unequal and fell into the collision path — renaming every
    /// original in place, the AUD-01 failure. Exact spelling is the cheap
    /// answer; otherwise compare device + inode, which is the filesystem's own
    /// identity for the directory whatever path led to it.
    static func isSameDirectory(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.path == b.standardizedFileURL.path { return true }
        guard let ia = directoryIdentity(a), let ib = directoryIdentity(b) else { return false }
        return ia == ib
    }

    private static func directoryIdentity(_ url: URL) -> String? {
        let resolved = url.resolvingSymlinksInPath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              let inode = attrs[.systemFileNumber] as? NSNumber,
              let device = attrs[.systemNumber] as? NSNumber else { return nil }
        return "\(device):\(inode)"
    }
}
