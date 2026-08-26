import CoreGraphics
import Foundation
import ImageIO
import Observation

/// Bounded in-memory window of rendered images keyed by position: a
/// (possibly asymmetric) window around the current index, loaded
/// current-first by an async loader. @Observable so the UI re-renders when
/// async loads populate `images`. One type serves the filmstrip (radius 30,
/// thumbnails), the grid (all thumbs) and the main viewer (asymmetric
/// behind/ahead, full resolution).
@MainActor
@Observable
public final class ImageWindow {
    public let count: Int
    public private(set) var images: [Int: CGImage] = [:]

    private let policy: WindowPolicy
    private let loader: (Int) async -> CGImage?
    private var inFlight: Set<Int> = []
    private var currentIndex: Int = 0

    /// Symmetric window: `radius` images before and after current.
    public convenience init(radius: Int, count: Int, loader: @escaping (Int) async -> CGImage?) {
        self.init(policy: WindowPolicy(radius: radius), count: count, loader: loader)
    }

    /// Asymmetric window: `behind` images before current, `ahead` after.
    public convenience init(behind: Int, ahead: Int, count: Int, loader: @escaping (Int) async -> CGImage?) {
        self.init(policy: WindowPolicy(behind: behind, ahead: ahead), count: count, loader: loader)
    }

    private init(policy: WindowPolicy, count: Int, loader: @escaping (Int) async -> CGImage?) {
        self.policy = policy
        self.count = count
        self.loader = loader
    }

    public func setCurrent(_ index: Int) {
        currentIndex = min(max(index, 0), max(count - 1, 0))
        let windowSet = Set(policy.window(around: currentIndex, count: count))
        let keep = windowSet.union(ensuredIndices)
        for i in Set(images.keys) where !keep.contains(i) {
            images.removeValue(forKey: i)
            inFlight.remove(i)
        }
        for i in policy.loadOrder(current: currentIndex, count: count)
        where images[i] == nil && !inFlight.contains(i) {
            inFlight.insert(i)
            Task { [weak self] in
                let image = await loader(i)
                guard let self else { return }
                self.inFlight.remove(i)
                guard Set(self.policy.window(around: self.currentIndex, count: self.count)).union(self.ensuredIndices).contains(i) else { return }
                if let image { self.images[i] = image }
            }
        }
        // Prune ensuredIndices to keep set to avoid unbounded growth.
        // Without this, ensuredIndices grows monotonically and retains 500 thumbs
        // for 500 files (keep = window ∪ ensuredIndices), violating memory bounded
        // viewport+61 invariant. Keep only window ∪ recently ensured viewport.
        ensuredIndices = ensuredIndices.intersection(keep)
        ensuredIndices = Set(ensuredIndices.filter { $0 >= 0 && $0 < count })
        ensuredOrder = ensuredOrder.filter { ensuredIndices.contains($0) }
        // Further bound to viewport (~20-40) + window (61) with LRU eviction
        pruneEnsuredIndices(windowSet: windowSet, recent: [])
    }

    private var ensuredIndices: Set<Int> = []
    private var ensuredOrder: [Int] = [] // insertion order for LRU bounding

    public func ensureLoaded(indices: [Int]) {
        let windowSet = Set(policy.window(around: currentIndex, count: count))
        let validNew = indices.filter { $0 >= 0 && $0 < count }
        for idx in validNew {
            if ensuredIndices.contains(idx) {
                // Move to end to mark recent for LRU
                ensuredOrder.removeAll { $0 == idx }
                ensuredOrder.append(idx)
            } else {
                ensuredIndices.insert(idx)
                ensuredOrder.append(idx)
            }
        }
        // Evict anything outside window ∪ ensured
        let keep = windowSet.union(ensuredIndices)
        for i in Set(images.keys) where !keep.contains(i) {
            images.removeValue(forKey: i)
            inFlight.remove(i)
        }
        // Only queue the explicitly ensured indices; window already queued by setCurrent.
        for i in ensuredIndices where images[i] == nil && !inFlight.contains(i) {
            inFlight.insert(i)
            Task { [weak self] in
                let image = await loader(i)
                guard let self else { return }
                self.inFlight.remove(i)
                // Still keep if current moved but still in ensured/window
                let currentKeep = Set(self.policy.window(around: self.currentIndex, count: self.count)).union(self.ensuredIndices)
                guard currentKeep.contains(i) else { return }
                if let image { self.images[i] = image }
            }
        }
        // Prune ensuredIndices to keep set to keep memory bounded (viewport + 61).
        ensuredIndices = ensuredIndices.intersection(keep)
        ensuredIndices = Set(ensuredIndices.filter { $0 >= 0 && $0 < count })
        ensuredOrder = ensuredOrder.filter { ensuredIndices.contains($0) }
        pruneEnsuredIndices(windowSet: windowSet, recent: validNew)
    }

    /// LRU viewport bounding: keep only window + most recently ensured viewport (~40).
    /// Keeps memory bounded to viewport (~20-40) + scrub window 61 even for 500+ files.
    private func pruneEnsuredIndices(windowSet: Set<Int>, recent: [Int]) {
        let maxViewport = 40
        let cap = windowSet.count + maxViewport
        guard ensuredIndices.count > cap else { return }
        // Keep window plus the most recent maxViewport ensures (LRU).
        // ensuredOrder is insertion/recency order; suffix holds most recent.
        let recentToKeep = Set(ensuredOrder.suffix(maxViewport))
        let keepSet = windowSet.union(recentToKeep).union(recent)
        let toRemove = ensuredIndices.subtracting(keepSet)
        for idx in toRemove {
            ensuredIndices.remove(idx)
        }
        ensuredOrder = ensuredOrder.filter { ensuredIndices.contains($0) }
        // If still over cap (e.g., window 61 + 40 =101 but we have large window), trim oldest beyond window
        if ensuredIndices.count > cap {
            // Keep window + most recent viewport, drop oldest viewport entries
            let keepCount = cap - windowSet.count
            let viewportToKeep = Set(ensuredOrder.filter { !windowSet.contains($0) }.suffix(keepCount))
            let finalKeep = windowSet.union(viewportToKeep).union(recentToKeep).union(recent)
            let extraRemove = ensuredIndices.subtracting(finalKeep)
            for idx in extraRemove { ensuredIndices.remove(idx) }
            ensuredOrder = ensuredOrder.filter { ensuredIndices.contains($0) }
        }
    }

    public func image(at index: Int) -> CGImage? { images[index] }

    /// Re-runs the loader for `index` even if an image (e.g. a `FastPreview`
    /// placeholder) is already resident, replacing it when the loader
    /// returns. Used when a background decode's cache JPEG lands after
    /// progressive-scrub unlock. No-op while a load is already in flight.
    public func retry(_ index: Int) {
        guard index >= 0, index < count, !inFlight.contains(index) else { return }
        inFlight.insert(index)
        Task { [weak self] in
            let image = await self?.loader(index)
            guard let self else { return }
            self.inFlight.remove(index)
            let currentKeep = Set(self.policy.window(around: self.currentIndex, count: self.count)).union(self.ensuredIndices)
            guard currentKeep.contains(index) else { return }
            if let image { self.images[index] = image }
        }
    }

    /// Awaits until all in-flight loads settle, the optional timeout
    /// expires, or the caller is cancelled (used by tests).
    public func waitUntilSettled(timeout: TimeInterval? = nil) async {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while !inFlight.isEmpty {
            if let deadline, Date() >= deadline { return }
            do { try await Task.sleep(nanoseconds: 5_000_000) }
            catch { return }   // cancelled: stop waiting
        }
    }

    // MARK: App factories

    /// Filmstrip window: radius 30, 320 px thumbnails. While a file is still
    /// decoding (progressive scrub), its cache JPEG does not exist yet, so
    /// the cell shows the fast embedded preview instead.
    public static func thumbnails(files: [SessionFile], cache: ImageCacheStore) -> ImageWindow {
        ImageWindow(radius: 30, count: files.count) { [cache] index in
            guard index >= 0, index < files.count else { return nil }
            let file = files[index]
            let url = try? await cache.cacheURL(for: file)
            // Decode off the main actor: even a small JPEG takes tens of ms,
            // and scrubbing must never block the UI thread.
            return await Task.detached(priority: .utility) {
                loadThumbnail(at: url, fallbackURL: file.url)
            }.value
        }
    }

    /// Grid window: all thumbnails (no sliding window). Used only by GridView;
    /// strip stays bounded (radius 30) for memory. Grid needs stable thumbs
    /// while scrolling — evicting on scroll would unload visible cells.
    public static func gridThumbnails(files: [SessionFile], cache: ImageCacheStore) -> ImageWindow {
        // radius >= count makes window = all indices, so the window never
        // evicts and ensureLoaded's LRU is not used. Fill with all thumbs
        // up to count, bounded by count (full grid).
        ImageWindow(radius: files.count, count: files.count) { [cache] index in
            guard index >= 0, index < files.count else { return nil }
            let file = files[index]
            let url = try? await cache.cacheURL(for: file)
            return await Task.detached(priority: .utility) {
                loadThumbnail(at: url, fallbackURL: file.url)
            }.value
        }
    }

    /// 320 px cache-JPEG thumbnail, or the fast embedded preview when the
    /// cache JPEG does not exist yet (file still decoding).
    nonisolated private static func loadThumbnail(at url: URL?, fallbackURL: URL) -> CGImage? {
        if let url, FileManager.default.fileExists(atPath: url.path) {
            return loadJPEG(at: url, maxPixelSize: 320)
        }
        return FastPreview.image(for: fallbackURL)
    }

    /// Main-viewer window: full-resolution decode for the current image,
    /// `displayFullResBehind` behind and `displayFullResAhead` ahead
    /// (defaults: −10 … +20, 31 images). The current image is always
    /// full-res, so the Space loupe's "100%" is genuine source-pixel 1:1 at
    /// any image size, and scrubbing within the window is instant. Images
    /// beyond it fall back to the filmstrip thumb and decode full-res on
    /// landing (~100 ms for a 20 MP cache entry). The asymmetry pre-loads
    /// the direction culling moves: more ahead than behind.
    ///
    /// While a file is still decoding (progressive scrub) its cache JPEG
    /// does not exist, so the loader returns the fast embedded preview
    /// (`FastPreview`) instead; `retry(_:)` replaces it when the decode
    /// lands.
    ///
    /// Memory is bounded by the window (31 full-res bitmaps), never by shoot
    /// size: ~1.9 GB at 20 MP (fits 8 GB machines for typical shoots),
    /// ~4.2 GB at 45 MP (needs headroom). Both sides are tunable via
    /// `defaults write com.quickcull displayFullResBehind N` /
    /// `displayFullResAhead N`. Decodes share a gate so a fill never fires
    /// many parallel ~100+ MB decodes at once.
    public static func display(files: [SessionFile], cache: ImageCacheStore) -> ImageWindow {
        ImageWindow(behind: Self.displayFullResBehind,
                    ahead: Self.displayFullResAhead,
                    count: files.count) { [cache] index in
            guard index >= 0, index < files.count else { return nil }
            let file = files[index]
            let url = try? await cache.cacheURL(for: file)
            guard let url else { return nil }
            // A full-res 20-45 MP decode takes ~100-400 ms; run it off the
            // main actor (detached task) and throttle it through the shared
            // gate so concurrent fills stay bounded.
            return await Task.detached(priority: .userInitiated) {
                displayDecodeGate.acquire()
                defer { displayDecodeGate.release() }
                if FileManager.default.fileExists(atPath: url.path) {
                    return loadJPEGFullRes(at: url)
                }
                // Still decoding: fast embedded preview as placeholder;
                // replaced by `retry(_:)` when the real decode lands.
                return FastPreview.image(for: file.url)
            }.value
        }
    }

    /// Full-res window behind the current image (see `display`). Hidden
    /// override: `defaults write com.quickcull displayFullResBehind N`.
    nonisolated static var displayFullResBehind: Int {
        let n = UserDefaults.standard.integer(forKey: "displayFullResBehind")
        return n > 0 ? n : 10
    }

    /// Full-res window ahead of the current image (see `display`). Hidden
    /// override: `defaults write com.quickcull displayFullResAhead N`.
    nonisolated static var displayFullResAhead: Int {
        let n = UserDefaults.standard.integer(forKey: "displayFullResAhead")
        return n > 0 ? n : 20
    }

    /// Full-resolution decode of a cached JPEG: reads the JPEG's own header
    /// dimensions and asks the thumbnail API for exactly that long edge, so
    /// nothing is ever downsampled. Cache JPEGs are already upright (no EXIF
    /// orientation tag), so `WithTransform` is a no-op kept for symmetry with
    /// the thumbnail path. CPU-bound, so callers run it off the main actor.
    nonisolated static func loadJPEGFullRes(at url: URL?) -> CGImage? {
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Downsamples a cached JPEG (thumbnail API = memory-bounded). Decoding
    /// is CPU-bound (tens to hundreds of ms for a 45 MP cache entry), so
    /// callers run this off the main actor via a detached task.
    nonisolated private static func loadJPEG(at url: URL?, maxPixelSize: Int) -> CGImage? {
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

/// Bounds concurrent full-res display decodes across all `ImageWindow.display`
/// windows. One process-wide gate so a window rebuild never starts a second
/// parallel fill, and a fill never decodes 61 ~180 MB images at once. FIFO is
/// approximate under contention, which is fine: `loadOrder` already queues the
/// current image first, so it wins the gate.
private final class DecodeGate: @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    init(limit: Int) {
        semaphore = DispatchSemaphore(value: max(1, limit))
    }
    func acquire() { semaphore.wait() }
    func release() { semaphore.signal() }
}

private let displayDecodeGate = DecodeGate(limit: 3)
