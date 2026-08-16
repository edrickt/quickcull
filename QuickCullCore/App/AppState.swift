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

    public private(set) var thumbWindow: SlidingWindow?
    public private(set) var displayImages: DisplayImageProvider?

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
        guard let session else { return }
        thumbWindow = SlidingWindow(radius: 30, count: session.count,
                                    thumbnailLoader: makeThumbLoader(files: files))
        displayImages = DisplayImageProvider(loader: makeDisplayLoader(files: files))
        syncWindows()
        phase = .scrubbing
    }

    /// Dismisses the import-failure banner once the user has seen it.
    /// Failures persist past the decoding → scrubbing transition so the
    /// scrub phase can surface them; this clears them.
    public func dismissImportFailures() {
        importFailures = []
    }

    private func makeThumbLoader(files: [SessionFile]) -> (Int) async -> CGImage? {
        { [cache] index in
            guard index >= 0, index < files.count else { return nil }
            return Self.loadJPEG(at: try? await cache.cacheURL(for: files[index]),
                                 maxPixelSize: 320)
        }
    }

    private func makeDisplayLoader(files: [SessionFile]) -> (Int) async -> CGImage? {
        let pixels = Self.displayPixelLimit()
        return { [cache] index in
            guard index >= 0, index < files.count else { return nil }
            return Self.loadJPEG(at: try? await cache.cacheURL(for: files[index]),
                                 maxPixelSize: pixels)
        }
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

    public func confirmCommit() {
        guard let session else { return }
        let flagged = session.flaggedFiles
        let outcomes = TrashCommit(trasher: trasher).commit(files: flagged)
        let succeeded = outcomes.filter(\.succeeded).map(\.file)
        session.remove(succeeded)
        commitFailures = outcomes.filter { !$0.succeeded }
        pendingCommitCount = 0
        if session.isEmpty {
            // Nothing left to scrub: back to the empty state for a new import.
            self.session = nil
            thumbWindow = nil
            displayImages = nil
            phase = .empty
        } else {
            rebuildWindows()
        }
    }

    public func cancelCommit() {
        pendingCommitCount = 0
    }

    private func rebuildWindows() {
        thumbWindow = nil
        displayImages = nil
        if let session, !session.isEmpty {
            thumbWindow = SlidingWindow(radius: 30, count: session.count,
                                        thumbnailLoader: makeThumbLoader(files: session.files))
            displayImages = DisplayImageProvider(loader: makeDisplayLoader(files: session.files))
            syncWindows()
        }
    }

    private static func displayPixelLimit() -> Int {
        Int(max(NSScreen.main?.frame.width ?? 1920,
                NSScreen.main?.frame.height ?? 1080) * 2)
    }

    /// Downsamples a cached JPEG (thumbnail API = memory-bounded).
    static func loadJPEG(at url: URL?, maxPixelSize: Int) -> CGImage? {
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
