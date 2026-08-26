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
///
/// Optional tiering: when `reducedLoader` + `upgradePolicy` are supplied,
/// indices outside the full tier load a reduced-size placeholder (half-size
/// decode) and are automatically re-run at full resolution once they enter
/// the tier (i.e. when the user lands on them). This keeps full-res memory
/// bounded by the tier while the window still pre-loads its whole extent.
@MainActor
@Observable
public final class ImageWindow {
    public let count: Int
    public private(set) var images: [Int: CGImage] = [:]

    private let policy: WindowPolicy
    private let loader: (Int) async -> CGImage?
    private let reducedLoader: ((Int) async -> CGImage?)?
    /// True when `index` is outside the full tier of `current`.
    private let upgradePolicy: ((Int, Int) -> Bool)?
    /// Indices whose resident image is a reduced-size placeholder; the
    /// upgrade pass re-runs them once they enter the tier.
    private var degradedIndices: Set<Int> = []
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

    /// Tiered window: see the type doc for `reducedLoader`/`upgradePolicy`.
    convenience init(behind: Int, ahead: Int, count: Int,
                     loader: @escaping (Int) async -> CGImage?,
                     reducedLoader: @escaping (Int) async -> CGImage?,
                     upgradePolicy: @escaping (Int, Int) -> Bool) {
        self.init(policy: WindowPolicy(behind: behind, ahead: ahead), count: count,
                  loader: loader, reducedLoader: reducedLoader, upgradePolicy: upgradePolicy)
    }

    private init(policy: WindowPolicy, count: Int, loader: @escaping (Int) async -> CGImage?,
                 reducedLoader: ((Int) async -> CGImage?)? = nil,
                 upgradePolicy: ((Int, Int) -> Bool)? = nil) {
        self.policy = policy
        self.count = count
        self.loader = loader
        self.reducedLoader = reducedLoader
        self.upgradePolicy = upgradePolicy
    }

    /// Queues the loader for `index` (reduced or full per the tier policy)
    /// and publishes the result if the index is still wanted.
    private func startLoad(_ index: Int) {
        guard index >= 0, index < count, !inFlight.contains(index) else { return }
        inFlight.insert(index)
        let useReduced = reducedLoader != nil && (upgradePolicy?(index, currentIndex) ?? false)
        if useReduced { degradedIndices.insert(index) } else { degradedIndices.remove(index) }
        let load = useReduced ? reducedLoader! : loader
        Task { [weak self] in
            let image = await load(index)
            guard let self else { return }
            self.inFlight.remove(index)
            let currentKeep = Set(self.policy.window(around: self.currentIndex, count: self.count)).union(self.ensuredIndices)
            guard currentKeep.contains(index) else {
                self.degradedIndices.remove(index)
                return
            }
            if let image { self.images[index] = image }
        }
    }

    public func setCurrent(_ index: Int) {
        currentIndex = min(max(index, 0), max(count - 1, 0))
        let windowSet = Set(policy.window(around: currentIndex, count: count))
        let keep = windowSet.union(ensuredIndices)
        for i in Set(images.keys) where !keep.contains(i) {
            images.removeValue(forKey: i)
            inFlight.remove(i)
            degradedIndices.remove(i)
        }
        for i in policy.loadOrder(current: currentIndex, count: count)
        where images[i] == nil && !inFlight.contains(i) {
            startLoad(i)
        }
        // Upgrade pass: indices that entered the full tier (typically the
        // image the user just landed on) re-run at full resolution, so the
        // loupe is always true 1:1 even after a far jump.
        if let upgradePolicy {
            for i in windowSet
            where degradedIndices.contains(i) && !upgradePolicy(i, currentIndex) && !inFlight.contains(i) {
                startLoad(i)
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
            degradedIndices.remove(i)
        }
        // Only queue the explicitly ensured indices; window already queued by setCurrent.
        for i in ensuredIndices where images[i] == nil && !inFlight.contains(i) {
            startLoad(i)
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

    /// Filmstrip window: radius 30, 320 px thumbnails.
    public static func thumbnails(files: [SessionFile], cache: ImageCacheStore) -> ImageWindow {
        ImageWindow(radius: 30, count: files.count) { [cache] index in
            guard index >= 0, index < files.count else { return nil }
            let url = try? await cache.cacheURL(for: files[index])
            // Decode off the main actor: even a small JPEG takes tens of ms,
            // and scrubbing must never block the UI thread.
            return await Task.detached(priority: .utility) {
                loadJPEG(at: url, maxPixelSize: 320)
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
            let url = try? await cache.cacheURL(for: files[index])
            return await Task.detached(priority: .utility) {
                loadJPEG(at: url, maxPixelSize: 320)
            }.value
        }
    }

    /// Main-viewer window with a full-resolution tier: the current image
    /// plus `displayFullResBehind` behind / `displayFullResAhead` ahead
    /// (defaults −5 … +10, 16 images) decodes at FULL resolution, so the
    /// Space loupe's "100%" is genuine source-pixel 1:1 at any image size
    /// and scrubbing within the tier is instant. The rest of the window
    /// extent (`displayExtentBehind`/`displayExtentAhead`, −10 … +20) is
    /// pre-loaded at HALF size (DCT-subsampled, ~25-70 ms and ~4× less
    /// memory) and upgrades to full-res the moment it enters the tier —
    /// i.e. when the user lands on it. Images beyond the extent fall back
    /// to the filmstrip thumb and decode full-res on landing.
    ///
    /// Memory is bounded by the window extent, never by shoot size: 16
    /// full-res + 15 half-size 20 MP images ≈ 1.2 GB (fits 8 GB machines
    /// for typical shoots; ~2.3 GB at 45 MP). The tier is tunable via
    /// `defaults write com.quickcull displayFullResBehind N` /
    /// `displayFullResAhead N`. Decodes share a gate so a fill never fires
    /// many parallel ~100+ MB decodes at once.
    public static func display(files: [SessionFile], cache: ImageCacheStore) -> ImageWindow {
        let fullBehind = Self.displayFullResBehind
        let fullAhead = Self.displayFullResAhead
        return ImageWindow(behind: Self.displayExtentBehind,
                           ahead: Self.displayExtentAhead,
                           count: files.count,
                           loader: { [cache] index in
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
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return loadJPEGFullRes(at: url)
            }.value
        },
        reducedLoader: { [cache] index in
            guard index >= 0, index < files.count else { return nil }
            let file = files[index]
            let url = try? await cache.cacheURL(for: file)
            guard let url else { return nil }
            return await Task.detached(priority: .utility) {
                displayDecodeGate.acquire()
                defer { displayDecodeGate.release() }
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return loadJPEGHalfRes(at: url)
            }.value
        },
        upgradePolicy: { index, current in
            index < current - fullBehind || index > current + fullAhead
        })
    }

    /// Window extent kept resident for the main viewer (see `display`).
    /// The full-res tier (knobs above) sits inside this extent; the outer
    /// ring holds half-size placeholders.
    nonisolated static var displayExtentBehind: Int { 10 }
    nonisolated static var displayExtentAhead: Int { 20 }

    /// Full-res tier behind the current image (see `display`). Hidden
    /// override: `defaults write com.quickcull displayFullResBehind N`.
    nonisolated static var displayFullResBehind: Int {
        let n = UserDefaults.standard.integer(forKey: "displayFullResBehind")
        return n > 0 ? n : 5
    }

    /// Full-res tier ahead of the current image (see `display`). Hidden
    /// override: `defaults write com.quickcull displayFullResAhead N`.
    nonisolated static var displayFullResAhead: Int {
        let n = UserDefaults.standard.integer(forKey: "displayFullResAhead")
        return n > 0 ? n : 10
    }

    /// Half-size decode of a cached JPEG: asks the thumbnail API for half
    /// the long edge, which ImageIO serves with DCT subsampling (~25-70 ms
    /// for a 20 MP entry vs ~144 ms full, at ~1/4 of the bitmap memory).
    /// Used for the outer window ring; upgraded to full-res on landing.
    nonisolated static func loadJPEGHalfRes(at url: URL?) -> CGImage? {
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height) / 2,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
