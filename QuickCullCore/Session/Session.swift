import Foundation
import Observation

/// Per-session culling state. Flags live only in memory and are discarded
/// when a new session starts. Commit removes trashed files; scrubbing
/// continues on the remainder. @Observable so the UI re-renders on index
/// and flag changes (filmstrip highlight, auto-scroll, badges).
@MainActor
@Observable
public final class Session {
    public private(set) var files: [SessionFile]
    public private(set) var currentIndex: Int = 0
    public private(set) var flagged: Set<String> = []
    public private(set) var filter: CullFilter = .all

    /// The full post-commit file list; `files` is its projection under
    /// `filter`. Nothing outside Session touches this.
    private var allFiles: [SessionFile]

    public init(files: [SessionFile]) {
        precondition(!files.isEmpty, "Session requires at least one file")
        self.files = files
        self.allFiles = files
    }

    public var count: Int { files.count }
    public var isEmpty: Bool { files.isEmpty }
    /// Every photo in the session, filtered or not (for keeper counts).
    public var totalCount: Int { allFiles.count }
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

    // MARK: Filtering

    private func matches(_ file: SessionFile, _ filter: CullFilter) -> Bool {
        switch filter {
        case .all: return true
        case .flagged: return flagged.contains(file.id)
        case .keepers: return !flagged.contains(file.id)
        }
    }

    private func projection(for filter: CullFilter) -> [SessionFile] {
        allFiles.filter { matches($0, filter) }
    }

    /// Position of `file` in the full list (order-preserving projection
    /// invariant: `files` is always a subsequence of `allFiles`).
    private func position(of file: SessionFile) -> Int {
        allFiles.firstIndex(where: { $0.id == file.id }) ?? 0
    }

    /// Switches the visible sequence to `filter`. The current photo stays
    /// current when it still matches; otherwise the nearest match in full
    /// list order takes over, ties resolving forward. A filter matching
    /// nothing (e.g. Flagged while nothing is flagged) falls back to All.
    public func setFilter(_ filter: CullFilter) {
        let newFiles = projection(for: filter)
        guard !newFiles.isEmpty else {
            self.filter = .all
            files = allFiles
            if let idx = allFiles.firstIndex(where: { $0.id == currentFile.id }) {
                currentIndex = idx
            }
            return
        }
        let currentID = currentFile.id
        self.filter = filter
        files = newFiles
        if let idx = newFiles.firstIndex(where: { $0.id == currentID }) {
            currentIndex = idx
        } else {
            currentIndex = nearestMatchIndex(to: currentID, in: newFiles)
        }
    }

    /// Index in `newFiles` of the file closest to `currentID`'s position in
    /// the full list; a tie resolves to the later (forward) file. Only
    /// called when `currentID` is NOT in `newFiles`, so the anchor is the
    /// current photo's position in `allFiles` (it always exists there).
    private func nearestMatchIndex(to currentID: String, in newFiles: [SessionFile]) -> Int {
        let currentPos = allFiles.firstIndex(where: { $0.id == currentID }) ?? 0
        var best = 0
        var bestDistance = Int.max
        for (i, file) in newFiles.enumerated() {
            let pos = position(of: file)
            let distance = abs(pos - currentPos)
            if distance < bestDistance
                || (distance == bestDistance && pos > position(of: newFiles[best])) {
                best = i
                bestDistance = distance
            }
        }
        return best
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
