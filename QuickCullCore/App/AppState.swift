import AppKit
import Foundation
import ImageIO
import Observation

public enum AppPhase: Equatable {
    case empty
    case decoding(completed: Int, total: Int)
    case scrubbing
}

/// Central app state: session phases, import pipeline, commit orchestration,
/// and the sliding windows. All UI observes this one object.
@MainActor
@Observable
public final class AppState {
    public private(set) var phase: AppPhase = .empty
    public enum ViewMode: Equatable, Sendable { case scrub, split, grid }
    public private(set) var viewMode: ViewMode = .scrub
    public private(set) var gridSelection: Set<String> = []
    private var gridAnchorID: String?
    public private(set) var session: Session?
    public private(set) var importFailures: [DecodeOutcome] = []
    public private(set) var commitFailures: [TrashOutcome] = []
    public private(set) var pendingCommitCount: Int = 0
    public private(set) var isCommitting: Bool = false

    public private(set) var thumbWindow: ImageWindow?
    public private(set) var gridThumbs: ImageWindow?
    public private(set) var displayImages: ImageWindow?

    public let cache: ImageCacheStore
    private let decoder: RawDecoding
    private let trasher: Trashing

    public init(decoder: RawDecoding = RoutingDecoder(librawDecoder: LibRawDecoder(),
                                                      imageIODecoder: ImageIODecoder()),
                cache: ImageCacheStore = ImageCacheStore(baseURL: ImageCacheStore.defaultBaseURL()),
                trasher: Trashing = FileManagerTrasher()) {
        self.decoder = decoder
        self.cache = cache
        self.trasher = trasher
    }

    /// Launch-time authoritative cache cleanup (leftovers from crashes
    /// included); runs detached so UI never waits on it.
    public func prepareForLaunch() {
        Task { try? await cache.wipe() }
    }

    /// Full reset equivalent to quit+relaunch. Single owner of the empty transition.
    /// Always confirmed by ScrubView, so no flag-count guard here.
    @MainActor
    public func startNewSession() {
        Task { try? await cache.wipe() }
        session = nil
        thumbWindow = nil
        gridThumbs = nil
        displayImages = nil
        importFailures = []
        commitFailures = []
        pendingCommitCount = 0
        isCommitting = false
        gridSelection = []
        gridAnchorID = nil
        viewMode = .scrub
        phase = .empty
    }

    /// Import: validate + dedupe, then Phase 1 (decode everything), then scrub.
    public func importFiles(urls: [URL]) {
        viewMode = .scrub
        gridSelection = []
        gridAnchorID = nil
        let unique = Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        let supported = unique.filter(RawFileIdentity.isSupported)
        guard !supported.isEmpty else {
            // Nothing importable: surface the unsupported selection in the
            // empty-state banner instead of silently ignoring it.
            importFailures = unique.map {
                DecodeOutcome(file: SessionFile(url: $0),
                              error: .cannotOpen("Unsupported format"))
            }
            phase = .empty
            return
        }

        let files = supported.map(SessionFile.init)
        // Files the user picked that we don't support: reported in the
        // failure banner instead of silently disappearing from the count.
        let unsupportedFailures = unique
            .filter { !RawFileIdentity.isSupported($0) }
            .map { DecodeOutcome(file: SessionFile(url: $0),
                                 error: .cannotOpen("Unsupported format")) }
        session = Session(files: files)
        importFailures = []
        commitFailures = []
        pendingCommitCount = 0
        phase = .decoding(completed: 0, total: files.count)

        let engine = DecodeEngine(decoder: decoder, cache: cache)
        Task {
            for await event in await engine.decodeAll(files: files) {
                switch event {
                case .progress(let completed, let total):
                    phase = .decoding(completed: completed, total: total)
                case .completed(let outcomes):
                    importFailures = unsupportedFailures + outcomes.filter { $0.error != nil }
                    let failed = outcomes.filter { $0.error != nil }.map(\.file)
                    if !failed.isEmpty {
                        // Spec: the session proceeds without the failed files.
                        // Flags are empty at this point, so remove() only
                        // drops the files (and shifts the index correctly).
                        session?.remove(failed)
                        if let s = session {
                            gridSelection = gridSelection.filter { s.contains(id: $0) }
                        }
                    }
                    if session?.isEmpty == true {
                        // All failed: back to the empty state; its banner
                        // surfaces the failures.
                        session = nil
                        thumbWindow = nil
                        gridThumbs = nil
                        displayImages = nil
                        phase = .empty
                        viewMode = .scrub
                    } else if let session {
                        // Loaders index into the files array, so it must be
                        // the post-removal list.
                        finishDecoding(files: session.files)
                    }
                }
            }
        }
    }

    private func finishDecoding(files: [SessionFile]) {
        installWindows(for: files)
        phase = .scrubbing
    }

    private func installWindows(for files: [SessionFile]) {
        // No sliding window for thumbnails: grid and strip share an all-thumbs window (radius = count).
        // All thumbnails stay loaded while scrolling, no eviction.
        let thumbs = ImageWindow.gridThumbnails(files: files, cache: cache)
        thumbWindow = thumbs
        gridThumbs = thumbs
        displayImages = ImageWindow.display(files: files, cache: cache)
        syncWindows()
        thumbs.setCurrent(0)
    }

    /// Dismisses the import-failure banner once the user has seen it.
    /// Failures persist past the decoding → scrubbing transition so the
    /// scrub phase can surface them.
    public func dismissImportFailures() {
        importFailures = []
    }

    public func handle(_ action: CullAction) {
        guard let session, phase == .scrubbing else { return }
        switch action {
        case .next: session.move(by: 1)
        case .previous: session.move(by: -1)
        case .jumpForward: session.move(by: 10)
        case .jumpBack: session.move(by: -10)
        case .toggleFlag:
            if viewMode == .grid && !gridSelection.isEmpty {
                let changed = session.toggleFlags(ids: gridSelection)
                if changed { installWindows(for: session.files) } else { syncWindows() }
                // Deselect after any flag action: Ctrl+A + Z should not stay highlighted
                gridSelection = []
                gridAnchorID = nil
            } else {
                // A flag flip under a non-All filter changes the visible
                // sequence (the photo drops out / the filter falls back to
                // All), so the windows must be rebuilt over the new
                // projection. In All mode the sequence is unchanged and the
                // windows stay put.
                if session.toggleFlag() {
                    installWindows(for: session.files)
                } else {
                    syncWindows()
                }
            }
        }
        syncWindows()
    }

    public func setCurrentIndex(_ index: Int) {
        guard let session, phase == .scrubbing else { return }
        session.setIndex(index)
        syncWindows()
    }

    /// Switches the visible sequence to `filter` and rebuilds both image
    /// windows over the new projection (same path commit uses). No-op
    /// outside the scrubbing phase, and when `filter` is already active
    /// (the windows already cover that projection).
    public func setFilter(_ filter: CullFilter) {
        guard let session, phase == .scrubbing else { return }
        guard session.filter != filter else { return }
        session.setFilter(filter)
        installWindows(for: session.files)
    }

    public func setViewMode(_ mode: ViewMode) {
        guard !isCommitting else { return }
        guard phase == .scrubbing else { return }
        guard viewMode != mode else { return }
        viewMode = mode
    }

    public func selectSingle(id: String) {
        gridSelection = [id]
        gridAnchorID = id
    }

    public func toggleSelection(id: String) {
        if gridSelection.contains(id) { gridSelection.remove(id) }
        else { gridSelection.insert(id) }
        // Intentionally does not update gridAnchorID: Finder-like semantics where
        // Cmd-click toggles selection without moving the Shift-range anchor.
        // Plan says gridAnchorID = id but test expects no anchor move; keep as is.
    }

    public func selectRange(to targetID: String) {
        guard let anchor = gridAnchorID,
              let session,
              let anchorIdx = session.files.firstIndex(where: { $0.id == anchor }),
              let targetIdx = session.files.firstIndex(where: { $0.id == targetID }) else {
            selectSingle(id: targetID); return
        }
        let lo = min(anchorIdx, targetIdx), hi = max(anchorIdx, targetIdx)
        let rangeIDs = session.files[lo...hi].map(\.id)
        gridSelection.formUnion(rangeIDs)
    }

    public func handleGridTap(id: String, isCmd: Bool, isShift: Bool) {
        if isShift { selectRange(to: id) }
        else if isCmd { toggleSelection(id: id) }
        else { selectSingle(id: id) }
        // Do NOT move currentIndex or sync windows here: selection is
        // highlight-only. Current photo stays where scrub left it; double-click
        // is the explicit jump to scrub at that photo (setIndex+syncWindows).
        // Removing setIndex/syncWindows here avoids ImageWindow window
        // recompute (evict + 61 loader Tasks) on every Cmd/Shift click,
        // which made grid selection extremely slow for 100+ photos.
    }

    public func handleGridDoubleClick(id: String) {
        guard !isCommitting, let idx = session?.files.firstIndex(where: { $0.id == id }) else { return }
        session?.setIndex(idx)
        syncWindows()
        viewMode = .scrub
    }

    public func selectAllInGrid() {
        guard phase == .scrubbing, viewMode == .grid, let session else { return }
        guard !session.files.isEmpty else { return }
        gridSelection = Set(session.files.map(\.id))
        gridAnchorID = session.files.first?.id
    }

    private func syncWindows() {
        guard let session else { return }
        thumbWindow?.setCurrent(session.currentIndex)
        displayImages?.setCurrent(session.currentIndex)
        // Ensure right pane (current+1) is also in-flight when in Split and at edge
        // (radius 1 already covers current±1, but at last index right is nil; no extra work needed)
        // Optional: if radius were tight, ensureLoaded would be called, but radius 1 suffices.
    }

    public func requestCommit() {
        pendingCommitCount = session?.flaggedCount ?? 0
    }

    public func confirmCommit() async {
        guard let session, !isCommitting else { return }
        let flagged = session.flaggedFiles
        isCommitting = true
        let outcomes = await Task.detached(priority: .userInitiated) {
            TrashCommit(trasher: self.trasher).commit(files: flagged)
        }.value
        let succeeded = outcomes.filter(\.succeeded).map(\.file)
        session.remove(succeeded)
        gridSelection = gridSelection.filter { session.contains(id: $0) }
        commitFailures = outcomes.filter { !$0.succeeded }
        pendingCommitCount = 0
        isCommitting = false
        if session.isEmpty {
            self.session = nil
            thumbWindow = nil
            gridThumbs = nil
            displayImages = nil
            phase = .empty
            viewMode = .scrub
        } else {
            installWindows(for: session.files)
        }
    }

    public func cancelCommit() {
        pendingCommitCount = 0
    }
}
