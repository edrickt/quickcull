import Foundation

/// Per-session culling state. Flags live only in memory and are discarded
/// when a new session starts. Commit removes trashed files; scrubbing
/// continues on the remainder.
@MainActor
public final class Session {
    public private(set) var files: [SessionFile]
    public private(set) var currentIndex: Int = 0
    public private(set) var flagged: Set<String> = []

    public init(files: [SessionFile]) {
        precondition(!files.isEmpty, "Session requires at least one file")
        self.files = files
    }

    public var count: Int { files.count }
    public var isEmpty: Bool { files.isEmpty }
    /// The file at the current index.
    ///
    /// Precondition: `files` is not empty (the scrubbing phase guarantees
    /// this; commit transitions away from an empty session).
    public var currentFile: SessionFile {
        assert(!files.isEmpty, "currentFile requires a non-empty session")
        return files[currentIndex]
    }

    public func move(by delta: Int) {
        guard !files.isEmpty else { return }
        currentIndex = min(max(currentIndex + delta, 0), files.count - 1)
    }

    public func setIndex(_ index: Int) {
        guard !files.isEmpty else { return }
        currentIndex = min(max(index, 0), files.count - 1)
    }

    public func toggleFlag() {
        guard !files.isEmpty else { return }
        let id = currentFile.id
        if flagged.contains(id) { flagged.remove(id) } else { flagged.insert(id) }
    }

    public func isFlagged(_ file: SessionFile) -> Bool {
        flagged.contains(file.id)
    }

    public var flaggedCount: Int { flagged.count }

    public var flaggedFiles: [SessionFile] {
        files.filter { flagged.contains($0.id) }
    }

    /// Remove trashed files after a successful commit. All flags are cleared
    /// (flagged files are exactly the ones being removed). The current photo
    /// is preserved: if files before it were removed, the index shifts back
    /// by that count so `currentFile` does not silently change.
    public func remove(_ filesToRemove: [SessionFile]) {
        let ids = Set(filesToRemove.map(\.id))
        let removedBeforeCurrent = files.enumerated()
            .filter { $0.offset < currentIndex && ids.contains($0.element.id) }
            .count
        flagged.subtract(ids)
        files.removeAll { ids.contains($0.id) }
        currentIndex = min(max(currentIndex - removedBeforeCurrent, 0), max(files.count - 1, 0))
    }
}
