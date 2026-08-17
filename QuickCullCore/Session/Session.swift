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
        guard !files.isEmpty else { return }
        let newFiles = projection(for: filter)
        guard !newFiles.isEmpty else {
            let currentID = currentFile.id
            self.filter = .all
            files = allFiles
            if let idx = allFiles.firstIndex(where: { $0.id == currentID }) {
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

    /// Toggles the current photo's reject flag. Under a non-All filter the
    /// flip always drops the photo out of the visible sequence, so the next
    /// match takes its place (index clamped at the end); if the sequence
    /// empties entirely the filter falls back to All, keeping the photo.
    /// Returns whether the visible sequence changed (always false in All
    /// mode).
    @discardableResult
    public func toggleFlag() -> Bool {
        guard !files.isEmpty else { return false }
        let id = currentFile.id
        if flagged.contains(id) { flagged.remove(id) } else { flagged.insert(id) }
        guard filter != .all else { return false }
        let newFiles = projection(for: filter)
        if newFiles.isEmpty {
            filter = .all
            files = allFiles
            if let idx = allFiles.firstIndex(where: { $0.id == id }) { currentIndex = idx }
        } else {
            files = newFiles
            currentIndex = min(currentIndex, newFiles.count - 1)
        }
        return true
    }

    public func isFlagged(_ file: SessionFile) -> Bool {
        flagged.contains(file.id)
    }

    public var flaggedCount: Int { flagged.count }

    /// Flagged files from the FULL session list: under the Keepers filter
    /// the flagged files are not visible, and commit must still find them.
    public var flaggedFiles: [SessionFile] {
        allFiles.filter { flagged.contains($0.id) }
    }

    /// Remove trashed files after a successful commit. All flags are cleared
    /// (flagged files are exactly the ones being removed). The current photo
    /// is preserved: after removal the first survivor at or after its old
    /// position becomes current, or the last survivor when none follows —
    /// exactly the pre-filter index-shift behavior in All mode, generalized
    /// to the projection. A commit that empties the visible sequence while
    /// files remain (e.g. every flagged photo committed in Flagged mode)
    /// falls back to All, landing on the first file.
    public func remove(_ filesToRemove: [SessionFile]) {
        guard !files.isEmpty else { return }
        let ids = Set(filesToRemove.map(\.id))
        let original = allFiles
        let currentPos = original.firstIndex(where: { $0.id == currentFile.id }) ?? 0
        flagged.subtract(ids)
        allFiles.removeAll { ids.contains($0.id) }
        files = projection(for: filter)
        guard !files.isEmpty else {
            currentIndex = 0
            if !allFiles.isEmpty {
                filter = .all
                files = allFiles
            }
            return
        }
        // First survivor at or after the old current position (today's
        // index-shift semantics, generalized to the projection); else the
        // last survivor. Positions are the ORIGINAL full-list ones: the
        // projection preserves full-list order, and `files` is a
        // subsequence of `allFiles` at every point.
        let originalPositions = Dictionary(uniqueKeysWithValues: original.enumerated().map { ($0.element.id, $0.offset) })
        if let survivor = files.first(where: { (originalPositions[$0.id] ?? 0) >= currentPos }),
           let idx = files.firstIndex(where: { $0.id == survivor.id }) {
            currentIndex = idx
        } else {
            currentIndex = files.count - 1
        }
    }
}
