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
    public private(set) var flags: [String: FlagColor] = [:]
    /// Monotonic revision bumped on every flag mutation. The filmstrip keys
    /// its cells by id + revision, so a flag change re-keys the strip from
    /// the final state (a preempted render pass can't leave stale badges)
    /// at O(1) cost — previously the strip sorted and joined every flagged
    /// id on each render.
    public private(set) var flagRevision: Int = 0
    public var flagged: Set<String> { Set(flags.keys) }
    public func flagColor(for file: SessionFile) -> FlagColor? { flags[file.id] }
    public func flagColor(for id: String) -> FlagColor? { flags[id] }
    public func flaggedCount(_ color: FlagColor? = nil) -> Int {
        if let c = color { return flags.values.filter { $0 == c }.count }
        else { return flags.count }
    }
    public var flaggedCount: Int { flags.count }
    public func flaggedFiles(_ color: FlagColor? = nil) -> [SessionFile] {
        if let c = color { return allFiles.filter { flags[$0.id] == c } }
        else { return allFiles.filter { flags[$0.id] != nil } }
    }
    public var flaggedFiles: [SessionFile] { flaggedFiles(nil) }
    public func isFlagged(_ file: SessionFile) -> Bool { flags[file.id] != nil }
    public func isFlagged(_ file: SessionFile, color: FlagColor) -> Bool { flags[file.id] == color }
    /// The active filter combination (empty = `.all`). The `files` visible
    /// sequence is `allFiles` projected under it.
    public private(set) var filter: CullFilter = .all

    /// The full post-commit file list; `files` is its projection under
    /// `filter`. Nothing outside Session touches this.
    public private(set) var allFiles: [SessionFile]
    /// id → position in `allFiles`. Rebuilt whenever `allFiles` changes
    /// (init/remove); `position`, `nearestMatchIndex`, `remove` and
    /// `toggleFlags` read it for O(1) lookups instead of linear scans.
    private var idPositions: [String: Int] = [:]

    public init(files: [SessionFile]) {
        precondition(!files.isEmpty, "Session requires at least one file")
        self.files = files
        self.allFiles = files
        rebuildIDPositions()
    }

    private func rebuildIDPositions() {
        idPositions = Dictionary(uniqueKeysWithValues: allFiles.enumerated().map { ($0.element.id, $0.offset) })
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
        filter.isEmpty || filter.contains(CullFilter(matching: flags[file.id]))
    }

    private func projection(for filter: CullFilter) -> [SessionFile] {
        allFiles.filter { matches($0, filter) }
    }

    /// Position of `file` in the full list (order-preserving projection
    /// invariant: `files` is always a subsequence of `allFiles`).
    private func position(of file: SessionFile) -> Int {
        idPositions[file.id] ?? 0
    }

    /// Switches the visible sequence to `filter` (a combination; empty =
    /// All). The current photo stays current when it still matches; otherwise the nearest match in full
    /// list order takes over, ties resolving forward. A filter matching
    /// nothing yields an empty projection (placeholder) with `files==[]`,
    /// not a fallback to All — the grid shows "No photos in this filter".
    /// `toggleFlag`/`toggleFlags` empty projections still fall back to All
    /// (batch distinction).
    public func setFilter(_ filter: CullFilter) {
        let newFiles = projection(for: filter)
        if newFiles.isEmpty {
            self.filter = filter
            files = []
            currentIndex = 0
            return
        }
        let currentID: String? = files.isEmpty ? nil : currentFile.id
        self.filter = filter
        files = newFiles
        if let cid = currentID, let idx = newFiles.firstIndex(where: { $0.id == cid }) {
            currentIndex = idx
        } else if let cid = currentID {
            currentIndex = nearestMatchIndex(to: cid, in: newFiles)
        } else {
            currentIndex = 0
        }
    }

    /// Index in `newFiles` of the file closest to `currentID`'s position in
    /// the full list; a tie resolves to the later (forward) file. Only
    /// called when `currentID` is NOT in `newFiles`, so the anchor is the
    /// current photo's position in `allFiles` (it always exists there).
    private func nearestMatchIndex(to currentID: String, in newFiles: [SessionFile]) -> Int {
        let currentPos = idPositions[currentID] ?? 0
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
    public func toggleFlag(color: FlagColor) -> Bool {
        guard !files.isEmpty else { return false }
        let id = currentFile.id
        if flags[id] == color { flags.removeValue(forKey: id) } else { flags[id] = color }
        flagRevision += 1
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

    @discardableResult
    public func toggleFlag() -> Bool { toggleFlag(color: .red) }

    /// Batch-toggles flags for the given ids (intersection with `allFiles`).
    /// Recomputes the projection once. If the current photo is still visible
    /// it stays current; otherwise the nearest match in full-list order takes
    /// over (ties forward). An empty projection falls back to `.all` keeping
    /// the previous current photo by id. Returns whether the projection
    /// size changed or the filter fell back.
    @discardableResult
    public func toggleFlags(ids: Set<String>, color: FlagColor) -> Bool {
        guard !allFiles.isEmpty, !ids.isEmpty else { return false }
        let validIDs = Set(ids.filter { idPositions[$0] != nil })
        guard !validIDs.isEmpty else { return false }
        let beforeCount = files.count
        let beforeFilter = filter
        let currentIDBefore = files.isEmpty ? nil : currentFile.id
        for id in validIDs {
            if flags[id] == color { flags.removeValue(forKey: id) } else { flags[id] = color }
        }
        flagRevision += 1
        let newFiles = projection(for: filter)
        if newFiles.isEmpty {
            filter = .all
            files = allFiles
            if let cid = currentIDBefore, let idx = allFiles.firstIndex(where: { $0.id == cid }) {
                currentIndex = idx
            } else {
                currentIndex = 0
            }
            return true
        }
        files = newFiles
        if let cid = currentIDBefore, let idx = newFiles.firstIndex(where: { $0.id == cid }) {
            currentIndex = idx
        } else if let cid = currentIDBefore {
            currentIndex = nearestMatchIndex(to: cid, in: newFiles)
        } else {
            currentIndex = 0
        }
        return files.count != beforeCount || filter != beforeFilter
    }

    @discardableResult
    public func toggleFlags(ids: Set<String>) -> Bool { toggleFlags(ids: ids, color: .red) }

    public func contains(id: String) -> Bool {
        allFiles.contains { $0.id == id }
    }

    /// Remove trashed files after a successful commit. All flags are cleared
    /// (flagged files are exactly the ones being removed). The current photo
    /// is preserved: after removal the first survivor at or after its old
    /// position becomes current, or the last survivor when none follows —
    /// exactly the pre-filter index-shift behavior in All mode, generalized
    /// to the projection. A commit that empties the visible sequence while
    /// files remain (e.g. every flagged photo committed in Flagged mode)
    /// falls back to All, landing on the first file.
    /// When `files` is an empty placeholder (filter yields empty), removal
    /// still operates on `allFiles` so commits from placeholder-state work.
    public func remove(_ filesToRemove: [SessionFile]) {
        guard !allFiles.isEmpty else { return }
        let ids = Set(filesToRemove.map(\.id))
        let currentPos: Int
        if !files.isEmpty {
            currentPos = idPositions[currentFile.id] ?? 0
        } else {
            currentPos = 0
        }
        for id in ids { flags.removeValue(forKey: id) }
        flagRevision += 1
        // Positions in the ORIGINAL full list: `idPositions` is still the
        // pre-removal id → position map here. The projection preserves
        // full-list order, and `files` is a subsequence of `allFiles` at
        // every point.
        let originalPositions = idPositions
        allFiles.removeAll { ids.contains($0.id) }
        rebuildIDPositions()
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
        // last survivor.
        if let survivor = files.first(where: { (originalPositions[$0.id] ?? 0) >= currentPos }),
           let idx = files.firstIndex(where: { $0.id == survivor.id }) {
            currentIndex = idx
        } else {
            currentIndex = files.count - 1
        }
    }
}
