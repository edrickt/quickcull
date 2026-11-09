import AppKit
import Foundation
import ImageIO
import Observation

public enum AppPhase: Equatable {
    case empty
    case decoding(completed: Int, total: Int)
    case scrubbing
}

/// Progress of an import that is still decoding after culling opened (see
/// `AppState.backgroundDecodeProgress`).
public struct ImportProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }
}

/// Central app state: session phases, import pipeline, commit orchestration,
/// and the sliding windows. All UI observes this one object.
@MainActor
@Observable
public final class AppState {
    public private(set) var phase: AppPhase = .empty {
        didSet { if phase != .scrubbing { isLoupeActive = false } }
    }
    public enum ViewMode: Equatable, Sendable { case scrub, split, grid }
    public private(set) var viewMode: ViewMode = .scrub {
        didSet { if viewMode == .grid { isLoupeActive = false } }
    }
    public private(set) var gridSelection: Set<String> = []
    private var gridAnchorID: String?
    public private(set) var session: Session?
    public private(set) var importFailures: [DecodeOutcome] = []
    /// Failure ids the user already dismissed from the banner. The import can
    /// surface failures again while it keeps decoding, and at its completed
    /// event; a later failure must not resurrect ones already acknowledged.
    private var dismissedImportFailureIDs: Set<String> = []
    /// Non-nil while the import is still decoding files after the scrub view
    /// already opened: `earlyViewThreshold` full-size previews are cached and
    /// the rest are still landing. Photos whose preview has not landed show
    /// the viewer's loading state, and each landed decode refreshes its slots.
    public private(set) var backgroundDecodeProgress: ImportProgress?
    /// How many full-size previews must be cached before culling opens. The
    /// rest of the shoot keeps decoding behind the scrub view, so a long
    /// import no longer blocks the first photo behind every other file. A
    /// shoot at or below this size waits for every file (the previous
    /// behavior).
    public let earlyViewThreshold: Int
    public private(set) var commitFailures: [TrashOutcome] = []
    /// Bumped once per completed commit, so the UI can announce a failure even
    /// when the count is unchanged (two commits failing on one file each).
    /// Observing `commitFailures.count` misses that second notification.
    public private(set) var commitFailureRevision: Int = 0
    public private(set) var pendingCommitCount: Int = 0
    public private(set) var pendingCommitColor: FlagColor?
    /// The exact files the pending dialog names. Snapshotted at request time so
    /// a flag key that lands while the alert is up cannot change what gets
    /// trashed, and so the count the user approved is the count that commits.
    private var pendingCommitFiles: [SessionFile] = []
    public private(set) var lastCommitColor: FlagColor?
    public private(set) var isCommitting: Bool = false
    public private(set) var pendingMoveCount: Int = 0
    public private(set) var pendingMoveDestination: URL?
    public private(set) var pendingMoveColor: FlagColor?
    /// See `pendingCommitFiles`.
    private var pendingMoveFiles: [SessionFile] = []
    public private(set) var lastMoveColor: FlagColor?
    /// `internal(set)` so tests can inject failures; app code treats as read-only.
    public internal(set) var moveFailures: [MoveOutcome] = []
    /// See `commitFailureRevision`.
    public private(set) var moveFailureRevision: Int = 0
    public private(set) var isMoving: Bool = false
    public private(set) var isLoupeActive: Bool = false
    private let mover: Moving

    public private(set) var thumbWindow: ImageWindow?
    public private(set) var gridThumbs: ImageWindow?
    public private(set) var displayImages: ImageWindow?

    public let cache: ImageCacheStore
    private let decoder: RawDecoding
    private let trasher: Trashing
    private let decodeOptions: DecodeOptions = .v1
    /// The in-flight import decode stream. Cancelled before a new import or
    /// new session starts so a stale stream can never write phase/windows
    /// over newer state. A finished task left here is harmless (cancelling
    /// it is a no-op); no UI path re-imports while one runs today, but the
    /// guard keeps that invariant local instead of incidental.
    private var importTask: Task<Void, Never>?
    /// One-shot guard for `prepareForLaunch` (see there).
    private var hasPreparedForLaunch = false

    /// Monotonic session identity, bumped by every path that installs or
    /// discards a session. A commit/move started against the previous session
    /// runs off the main actor; it captures this value and re-checks it before
    /// writing any state, so a completion that lands after `New Session` (or a
    /// re-import) can never install windows or flags for a session that no
    /// longer exists.
    private var sessionGeneration = 0
    /// `sessionGeneration` the windows were built for. A projection change
    /// within one session retargets the existing windows; a new session (or a
    /// re-import) rebuilds them, because the loaders capture that session's
    /// files.
    private var windowsGeneration = -1

    public init(decoder: RawDecoding = RoutingDecoder(librawDecoder: LibRawDecoder(),
                                                      imageIODecoder: ImageIODecoder()),
                cache: ImageCacheStore = ImageCacheStore(baseURL: ImageCacheStore.defaultBaseURL()),
                trasher: Trashing = FileManagerTrasher(),
                mover: Moving = FileManagerMover(),
                earlyViewThreshold: Int = 50) {
        self.decoder = decoder
        self.cache = cache
        self.trasher = trasher
        self.mover = mover
        self.earlyViewThreshold = max(1, earlyViewThreshold)
    }

    /// Launch-time authoritative cache cleanup (leftovers from crashes
    /// included); runs detached so UI never waits on it. Idempotent: a second
    /// window or a restored scene must not wipe the cache a running session is
    /// reading from.
    public func prepareForLaunch() {
        guard !hasPreparedForLaunch else { return }
        hasPreparedForLaunch = true
        Task { try? await cache.wipe() }
    }

    /// Clears pending/failure state for both commit flows. Used at session
    /// start, on import, and after a confirmed commit finishes.
    private func resetTransientState() {
        pendingCommitCount = 0
        pendingCommitColor = nil
        pendingCommitFiles = []
        lastCommitColor = nil
        isCommitting = false
        commitFailures = []
        // The revisions are the failure channel; clearing the arrays is a
        // notification too, so an observer keyed on the revision must see it.
        commitFailureRevision += 1
        pendingMoveCount = 0
        pendingMoveDestination = nil
        pendingMoveColor = nil
        pendingMoveFiles = []
        lastMoveColor = nil
        moveFailures = []
        moveFailureRevision += 1
        isMoving = false
    }

    /// Single owner of the empty transition: drop the session and windows,
    /// return to the importer in scrub mode.
    private func transitionToEmptySession() {
        sessionGeneration += 1
        session = nil
        thumbWindow = nil
        gridThumbs = nil
        displayImages = nil
        backgroundDecodeProgress = nil
        viewMode = .scrub
        phase = .empty
    }

    /// Full reset equivalent to quit+relaunch. Single owner of the empty transition.
    /// Always confirmed by ScrubView, so no flag-count guard here.
    @MainActor
    public func startNewSession() {
        importTask?.cancel()
        Task { try? await cache.wipe() }
        transitionToEmptySession()
        resetTransientState()
        importFailures = []
        commitFailures = []
        isLoupeActive = false
        gridSelection = []
        gridAnchorID = nil
    }

    /// Aborts a running import and returns to the importer. The decode workers
    /// stop at their next queue pop; previews already written stay until the
    /// launch wipe (they are keyed by the originals, so they are never stale).
    public func cancelImport() {
        importTask?.cancel()
        importTask = nil
        importFailures = []
        gridSelection = []
        gridAnchorID = nil
        resetTransientState()
        transitionToEmptySession()
    }

    /// True when the Space loupe can start right now.
    ///
    /// Single source of truth for `setLoupeActive` and the app-wide key
    /// monitor: the session must be on screen with a rendered image (not the
    /// grid, not a filtered-empty placeholder) and no commit or move may be in
    /// flight. Space is only consumed where this is true; everywhere else it
    /// belongs to the focused control or scroll view.
    public var canActivateLoupe: Bool {
        phase == .scrubbing
            && !isMoving
            && !isCommitting
            && viewMode != .grid
            && !(session?.files.isEmpty ?? true)
    }

    public func setLoupeActive(_ active: Bool) {
        guard canActivateLoupe else {
            if isLoupeActive { isLoupeActive = false }
            return
        }
        isLoupeActive = active
    }

    /// Import: validate + dedupe, then decode. Culling opens as soon as
    /// `earlyViewThreshold` full-size previews are cached; the rest of the
    /// shoot keeps decoding behind the scrub view (`backgroundDecodeProgress`)
    /// and fills in as it lands.
    public func importFiles(urls: [URL]) {
        dismissedImportFailureIDs = []
        viewMode = .scrub
        gridSelection = []
        gridAnchorID = nil
        // Dedupe by file identity (symlinks resolved): the same photo picked
        // through an alias and via its target is one file, not two.
        var seenIDs = Set<String>()
        var deduped: [URL] = []
        deduped.reserveCapacity(urls.count)
        for url in urls {
            let id = RawFileIdentity.fileID(for: url)
            if seenIDs.insert(id).inserted { deduped.append(url) }
        }
        let unique = deduped.sorted { $0.path < $1.path }
        let supported = unique.filter(RawFileIdentity.isSupported)
        guard !supported.isEmpty else {
            // Nothing importable: surface the unsupported selection in the
            // empty-state banner instead of silently ignoring it. A previous
            // session must not survive behind the importer, so this goes
            // through the same empty transition every other path uses.
            importFailures = unique.map {
                DecodeOutcome(file: SessionFile(url: $0),
                              error: .cannotOpen(ImportFailureSummary.unsupportedMessage))
            }
            resetTransientState()
            gridSelection = []
            gridAnchorID = nil
            transitionToEmptySession()
            return
        }

        let files = supported.map(SessionFile.init)
        // Files the user picked that we don't support: reported in the
        // failure banner instead of silently disappearing from the count.
        let unsupportedFailures = unique
            .filter { !RawFileIdentity.isSupported($0) }
            .map { DecodeOutcome(file: SessionFile(url: $0),
                                 error: .cannotOpen(ImportFailureSummary.unsupportedMessage)) }
        session = Session(files: files)
        sessionGeneration += 1
        let generation = sessionGeneration
        importFailures = []
        commitFailures = []
        resetTransientState()
        phase = .decoding(completed: 0, total: files.count)
        backgroundDecodeProgress = nil

        let engine = DecodeEngine(decoder: decoder, cache: cache, options: decodeOptions)
        importTask?.cancel()
        // A shoot at or below the threshold has nothing to gain from opening
        // early: "threshold reached" would already be "all decoded".
        let earlyViewAt = earlyViewThreshold < files.count ? earlyViewThreshold : nil
        // Failure banner order: decode completion order is nondeterministic,
        // but the same import must name its failures in the same order.
        var inputOrder: [String: Int] = [:]
        inputOrder.reserveCapacity(files.count)
        for (index, file) in files.enumerated() { inputOrder[file.id] = index }

        importTask = Task {
            var succeeded = 0
            var processed = 0
            var failures: [DecodeOutcome] = []
            var failedIDs: Set<String> = []
            var isViewing = false

            for await event in await engine.decodeAll(files: files) {
                if Task.isCancelled || generation != sessionGeneration { break }
                switch event {
                case .fileCompleted(let outcome):
                    if outcome.error != nil {
                        // A file the user already trashed or moved while the
                        // import was still running is not a decode failure to
                        // report, and it is already out of the session.
                        guard let live = session, live.contains(id: outcome.file.id) else { break }
                        failedIDs.insert(outcome.file.id)
                        failures.append(outcome)
                        guard isViewing else { break }
                        // Mid-import failures must not sit behind a permanent
                        // spinner in the viewer: drop the file now, re-map the
                        // windows (they are position-addressed) and say so.
                        removeFilesWithoutPreviews([outcome.file])
                        if let live = session { installWindows(for: live.files) }
                        surfaceImportFailures(failures, unsupported: unsupportedFailures,
                                              order: inputOrder)
                    } else {
                        succeeded += 1
                        if isViewing {
                            if FileManager.default.fileExists(atPath: outcome.file.url.path) {
                                refreshPreview(id: outcome.file.id)
                            } else {
                                // The user trashed or moved this file while its
                                // decode was in flight. The preview it just
                                // wrote recomputed the cache key after the file
                                // was gone, so the commit's discard cannot have
                                // removed it.
                                discardCachedPreview(at: outcome.previewURL)
                            }
                        } else if let threshold = earlyViewAt, succeeded >= threshold {
                            // The threshold is met: open the scrub view now and
                            // keep decoding the rest behind it.
                            let failedSoFar = failures.map(\.file)
                            if !failedSoFar.isEmpty { removeFilesWithoutPreviews(failedSoFar) }
                            if let live = session {
                                surfaceImportFailures(failures, unsupported: unsupportedFailures,
                                                      order: inputOrder)
                                installWindows(for: live.files)
                                phase = .scrubbing
                                isViewing = true
                                backgroundDecodeProgress = ImportProgress(
                                    completed: processed, total: files.count)
                            }
                        }
                    }
                case .progress(let completed, let total):
                    processed = completed
                    if isViewing {
                        backgroundDecodeProgress = ImportProgress(completed: completed, total: total)
                    } else {
                        phase = .decoding(completed: completed, total: total)
                    }
                case .completed(let outcomes):
                    backgroundDecodeProgress = nil
                    if !isViewing {
                        // Spec: the session proceeds without the failed files.
                        // The failures were tracked as they landed; remove them
                        // all at once so the window is installed over the
                        // post-removal list.
                        removeFilesWithoutPreviews(
                            outcomes.compactMap { failedIDs.contains($0.file.id) ? $0.file : nil })
                    }
                    surfaceImportFailures(failures, unsupported: unsupportedFailures,
                                          order: inputOrder)
                    if let live = session {
                        if isViewing {
                            // Retarget onto the post-removal list; already
                            // decoded images survive.
                            installWindows(for: live.files)
                        } else {
                            finishDecoding(files: live.files)
                        }
                    } else if phase != .empty {
                        // All failed: the banner surfaces the failures.
                        transitionToEmptySession()
                    }
                }
            }
        }
    }

    /// Removes files whose full-size preview could not be cached, so the
    /// session never keeps a slot that can never render. A session that loses
    /// every file returns to the empty state (its banner names the failures).
    private func removeFilesWithoutPreviews(_ files: [SessionFile]) {
        guard !files.isEmpty, let session else { return }
        session.remove(files)
        gridSelection = gridSelection.filter { session.contains(id: $0) }
        if session.totalCount == 0 { transitionToEmptySession() }
    }

    /// Decode failures reach the banner in completion order; re-sort them into
    /// the import's order so the same import reports the same banner. Failures
    /// the user already dismissed stay dismissed: the banner is re-surfaced as
    /// the background decode finds more failures.
    private func surfaceImportFailures(_ failures: [DecodeOutcome],
                                       unsupported: [DecodeOutcome],
                                       order: [String: Int]) {
        importFailures = (unsupported + failures.sorted {
            (order[$0.file.id] ?? 0) < (order[$1.file.id] ?? 0)
        }).filter { !dismissedImportFailureIDs.contains($0.file.id) }
    }

    /// A failure whose photo was cached but could not be stored is reported
    /// like any other decode failure. A commit can land while the import is
    /// still decoding, so a failure for a file the commit removed must not be
    /// reported (or re-surfaced at the completed event) as if the photo were
    /// broken.
    private func pruneImportFailures(forRemoved removed: [SessionFile]) {
        guard !removed.isEmpty else { return }
        let ids = Set(removed.map(\.id))
        importFailures.removeAll { ids.contains($0.file.id) }
        dismissedImportFailureIDs.formUnion(ids)
    }

    /// A decode landed after culling opened: fill in window slots that loaded
    /// before their photo's preview existed.
    private func refreshPreview(id: String) {
        thumbWindow?.refresh(id: id)
        gridThumbs?.refresh(id: id)
        displayImages?.refresh(id: id)
    }

    /// Deletes a preview whose file the user removed while the decode was in
    /// flight (see the success branch in `importFiles`).
    private func discardCachedPreview(at url: URL?) {
        guard let url else { return }
        let cache = self.cache
        Task.detached(priority: .utility) { await cache.deleteCachedPreviews(at: url) }
    }

    private func finishDecoding(files: [SessionFile]) {
        installWindows(for: files)
        phase = .scrubbing
    }

    private func installWindows(for files: [SessionFile]) {
        let ids = files.map(\.id)
        if thumbWindow == nil || gridThumbs == nil || displayImages == nil
            || windowsGeneration != sessionGeneration {
            // The strip stays bounded by its window plus scroll slack; the grid
            // is bounded by the viewport its cells report.
            thumbWindow = ImageWindow.thumbnails(files: files, cache: cache)
            gridThumbs = ImageWindow.gridThumbnails(files: files, cache: cache)
            displayImages = ImageWindow.display(files: files, cache: cache)
            windowsGeneration = sessionGeneration
        } else {
            // Filter switch, flag drop-out, commit: retarget in place so every
            // already-decoded image survives (a rebuild re-decodes the whole
            // window, which used to cost one decode per file in the shoot on
            // each flag toggle under a filter). An empty projection empties the
            // windows too — returning to All then re-decodes the bounded window,
            // which keeps the windows consistent with the session at a cost
            // that only the empty-placeholder path pays.
            thumbWindow?.retarget(ids: ids)
            gridThumbs?.retarget(ids: ids)
            displayImages?.retarget(ids: ids)
        }
        syncWindows()
    }

    /// Dismisses the import-failure banner once the user has seen it.
    /// Failures persist past the decoding → scrubbing transition so the
    /// scrub phase can surface them.
    public func dismissImportFailures() {
        for failure in importFailures { dismissedImportFailureIDs.insert(failure.file.id) }
        importFailures = []
    }

    public func handle(_ action: CullAction) {
        guard let session, phase == .scrubbing, !isMoving, !isCommitting,
              pendingCommitCount == 0, pendingMoveCount == 0 else { return }
        switch action {
        case .next, .previous, .jumpForward, .jumpBack:
            // Grid shows no current photo and never scrolls to one, so a scrub
            // key there only changes which photo Single opens on — invisible
            // input whose only effect surfaces later.
            guard viewMode != .grid else { return }
            switch action {
            case .next: session.move(by: 1)
            case .previous: session.move(by: -1)
            case .jumpForward: session.move(by: 10)
            default: session.move(by: -10)
            }
        case .toggleFlag(let color):
            if viewMode == .grid {
                // Grid marks no current photo, so a flag key with an empty
                // selection has no visible target: the photo it would flag is
                // where scrub left off, possibly off-screen. Batch-flag only
                // what is selected and on screen.
                guard !gridSelection.isEmpty else { return }
                // A selection outlives a filter switch on purpose (returning to
                // All restores it), so flag only the ids on screen right now —
                // a batch action must never reach a photo the user cannot see.
                let visible = gridSelection.intersection(Set(session.files.map(\.id)))
                guard !visible.isEmpty else { return }
                let changed = session.toggleFlags(ids: visible, color: color)
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
                if session.toggleFlag(color: color) {
                    installWindows(for: session.files)
                } else {
                    syncWindows()
                }
            }
        }
        syncWindows()
    }

    public func setCurrentIndex(_ index: Int) {
        guard let session, phase == .scrubbing, !isMoving, !isCommitting else { return }
        session.setIndex(index)
        syncWindows()
    }

    /// Switches the visible sequence to `filter` and rebuilds both image
    /// windows over the new projection (same path commit uses). No-op
    /// outside the scrubbing phase, and when `filter` is already active
    /// (the windows already cover that projection).
    public func setFilter(_ filter: CullFilter) {
        guard !isMoving, !isCommitting else { return }
        guard let session, phase == .scrubbing else { return }
        guard session.filter != filter else { return }
        session.setFilter(filter)
        installWindows(for: session.files)
    }

    public func setViewMode(_ mode: ViewMode) {
        guard !isCommitting, !isMoving else { return }
        guard phase == .scrubbing else { return }
        guard viewMode != mode else { return }
        viewMode = mode
    }

    public func selectSingle(id: String) {
        guard !isCommitting, !isMoving else { return }
        gridSelection = [id]
        gridAnchorID = id
    }

    public func toggleSelection(id: String) {
        guard !isCommitting, !isMoving else { return }
        if gridSelection.contains(id) { gridSelection.remove(id) }
        else { gridSelection.insert(id) }
        // Cmd-click toggles selection without moving the Shift-range anchor
        // (Finder semantics); Shift-clicks anchor on selectSingle/selectAll.
    }

    public func selectRange(to targetID: String) {
        guard !isCommitting, !isMoving else { return }
        guard let anchor = gridAnchorID,
              let session,
              let anchorIdx = session.files.firstIndex(where: { $0.id == anchor }),
              let targetIdx = session.files.firstIndex(where: { $0.id == targetID }) else {
            selectSingle(id: targetID); return
        }
        let lo = min(anchorIdx, targetIdx), hi = max(anchorIdx, targetIdx)
        let rangeIDs = session.files[lo...hi].map(\.id)
        // Finder semantics: shift-click replaces the range anchored at the
        // original anchor, so shrinking the target shrinks the selection.
        // (Unioning made a range only ever grow.)
        gridSelection = Set(rangeIDs)
    }

    public func handleGridTap(id: String, isCmd: Bool, isShift: Bool) {
        guard !isCommitting, !isMoving else { return }
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
        guard !isCommitting, !isMoving, let idx = session?.files.firstIndex(where: { $0.id == id }) else { return }
        session?.setIndex(idx)
        syncWindows()
        viewMode = .scrub
    }

    public func selectAllInGrid() {
        guard phase == .scrubbing, viewMode == .grid, !isCommitting, !isMoving,
              let session else { return }
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
        // Optional: if the window were tight, ensureLoaded would be called, but
        // the display window (behind/ahead policy) suffices for the panes.
    }

}


/// Destructive-action flow: request a target set, confirm it, apply the
/// outcomes. Their own extension because they are one state machine
/// (`pending*` -> `isCommitting`/`isMoving` -> `installWindows` or the empty
/// transition) and never touch the import/scrub paths.
extension AppState {
    @discardableResult
    public func requestCommit(color: FlagColor? = nil) -> Bool {
        // One pending request per app, because `AppState` is shared by every
        // window: without this, window B's request would overwrite the set
        // window A's dialog already named, and A's confirm would commit B's.
        guard phase == .scrubbing, !isMoving, !isCommitting,
              pendingCommitCount == 0, pendingMoveCount == 0 else { return false }
        let files = session?.flaggedFiles(color) ?? []
        // Nothing to confirm: leave the slot untouched rather than half-set.
        guard !files.isEmpty else { return false }
        pendingCommitFiles = files
        pendingCommitColor = color
        pendingCommitCount = files.count
        return true
    }

    public func confirmCommit() async {
        guard let session, phase == .scrubbing, !isCommitting, !isMoving else { return }
        let generation = sessionGeneration
        let color = pendingCommitColor
        let flagged = pendingCommitFiles
        guard !flagged.isEmpty else {
            pendingCommitCount = 0
            pendingCommitColor = nil
            pendingCommitFiles = []
            return
        }
        isCommitting = true
        let previews = resolvedPreviewURLs(for: flagged)
        let outcomes = await Task.detached(priority: .userInitiated) {
            TrashCommit(trasher: self.trasher).commit(files: flagged)
        }.value
        // The session can be torn down or replaced while this runs (New Session
        // is reachable from the menu bar). A stale completion must not write
        // windows or flags for a session that no longer exists.
        guard generation == sessionGeneration else { return }
        let succeeded = outcomes.filter(\.succeeded).map(\.file)
        session.remove(succeeded)
        pruneImportFailures(forRemoved: succeeded)
        gridSelection = gridSelection.filter { session.contains(id: $0) }
        commitFailures = outcomes.filter { !$0.succeeded }
        commitFailureRevision += 1
        lastCommitColor = commitFailures.isEmpty ? nil : color
        pendingCommitCount = 0
        pendingCommitColor = nil
        pendingCommitFiles = []
        isCommitting = false
        // `isEmpty` is the projection; a commit made from the empty-filter
        // placeholder leaves it empty while files remain, and that must not
        // read as "the session is finished".
        if session.totalCount == 0 {
            transitionToEmptySession()
        } else {
            installWindows(for: session.files)
        }
        discardCachedPreviews(at: succeeded.compactMap { previews[$0.id] })
    }

    public func cancelCommit() {
        guard !isMoving, !isCommitting else { return }
        pendingCommitCount = 0
        pendingCommitColor = nil
        pendingCommitFiles = []
    }

    @discardableResult
    public func requestMove(to dest: URL, color: FlagColor? = nil) -> Bool {
        // See `requestCommit`: the pending slot is app-wide.
        guard phase == .scrubbing, !isMoving, !isCommitting,
              pendingCommitCount == 0, pendingMoveCount == 0 else { return false }
        let files = session?.flaggedFiles(color) ?? []
        guard !files.isEmpty else { return false }
        pendingMoveFiles = files
        pendingMoveCount = files.count
        pendingMoveDestination = dest
        pendingMoveColor = color
        return true
    }
    public func cancelMove() {
        guard !isMoving, !isCommitting else { return }
        pendingMoveCount = 0
        pendingMoveDestination = nil
        pendingMoveColor = nil
        pendingMoveFiles = []
    }
    public func confirmMove() async {
        guard let session, phase == .scrubbing, !isCommitting, !isMoving,
              let dest = pendingMoveDestination else { return }
        let generation = sessionGeneration
        let color = pendingMoveColor
        let flagged = pendingMoveFiles
        guard !flagged.isEmpty else {
            pendingMoveCount = 0
            pendingMoveDestination = nil
            pendingMoveColor = nil
            pendingMoveFiles = []
            return
        }
        isMoving = true
        let previews = resolvedPreviewURLs(for: flagged)
        let outcomes = await Task.detached(priority: .userInitiated) {
            MoveCommit(mover: self.mover).commit(files: flagged, to: dest)
        }.value
        // See confirmCommit: never write over a session that was replaced or
        // discarded while the move was in flight.
        guard generation == sessionGeneration else { return }
        let succeeded = outcomes.filter(\.succeeded).map(\.file)
        session.remove(succeeded)
        pruneImportFailures(forRemoved: succeeded)
        gridSelection = gridSelection.filter { session.contains(id: $0) }
        moveFailures = outcomes.filter { !$0.succeeded }
        moveFailureRevision += 1
        lastMoveColor = moveFailures.isEmpty ? nil : color
        pendingMoveCount = 0
        pendingMoveDestination = nil
        pendingMoveColor = nil
        pendingMoveFiles = []
        isMoving = false
        // See `confirmCommit`: `totalCount`, not the projection.
        if session.totalCount == 0 {
            transitionToEmptySession()
        } else {
            installWindows(for: session.files)
        }
        discardCachedPreviews(at: succeeded.compactMap { previews[$0.id] })
    }

    /// Cache locations of the files about to be trashed or moved, resolved
    /// while the source files still exist: the key embeds their size and mtime,
    /// so once they are gone it cannot be recomputed.
    private func resolvedPreviewURLs(for files: [SessionFile]) -> [String: URL] {
        var urls: [String: URL] = [:]
        urls.reserveCapacity(files.count)
        for file in files {
            if let url = try? cache.cacheURL(for: file) { urls[file.id] = url }
        }
        return urls
    }

    /// A trashed or moved file can never be viewed again, so its decoded
    /// previews must not keep occupying the cache.
    private func discardCachedPreviews(at urls: [URL]) {
        guard !urls.isEmpty else { return }
        let cache = self.cache
        Task.detached(priority: .utility) {
            for url in urls { await cache.deleteCachedPreviews(at: url) }
        }
    }
}