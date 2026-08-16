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
    public private(set) var session: Session?
    public private(set) var importFailures: [DecodeOutcome] = []
    public private(set) var commitFailures: [TrashOutcome] = []
    public private(set) var pendingCommitCount: Int = 0
    public private(set) var isCommitting: Bool = false

    public private(set) var thumbWindow: ImageWindow?
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

    /// Import: validate + dedupe, then Phase 1 (decode everything), then scrub.
    public func importFiles(urls: [URL]) {
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
                    }
                    if session?.isEmpty == true {
                        // All failed: back to the empty state; its banner
                        // surfaces the failures.
                        session = nil
                        thumbWindow = nil
                        displayImages = nil
                        phase = .empty
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
        thumbWindow = ImageWindow.thumbnails(files: files, cache: cache)
        displayImages = ImageWindow.display(files: files, cache: cache)
        syncWindows()
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
        case .toggleFlag: session.toggleFlag()
        }
        syncWindows()
    }

    public func setCurrentIndex(_ index: Int) {
        guard let session, phase == .scrubbing else { return }
        session.setIndex(index)
        syncWindows()
    }

    private func syncWindows() {
        guard let session else { return }
        thumbWindow?.setCurrent(session.currentIndex)
        displayImages?.setCurrent(session.currentIndex)
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
        commitFailures = outcomes.filter { !$0.succeeded }
        pendingCommitCount = 0
        isCommitting = false
        if session.isEmpty {
            self.session = nil
            thumbWindow = nil
            displayImages = nil
            phase = .empty
        } else {
            installWindows(for: session.files)
        }
    }

    public func cancelCommit() {
        pendingCommitCount = 0
    }
}
