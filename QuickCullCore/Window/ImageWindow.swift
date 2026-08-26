import CoreGraphics
import Foundation
import ImageIO
import Observation

/// Bounded in-memory window of rendered images keyed by position: current ±
/// radius, loaded current-first by an async loader. @Observable so the UI
/// re-renders when async loads populate `images`. One type serves both the
/// filmstrip (radius 30, thumbnails) and the main viewer (radius 1, display
/// size).
@MainActor
@Observable
public final class ImageWindow {
    public let radius: Int
    public let count: Int
    public private(set) var images: [Int: CGImage] = [:]

    private let loader: (Int) async -> CGImage?
    private var inFlight: Set<Int> = []
    private var currentIndex: Int = 0

    public init(radius: Int, count: Int, loader: @escaping (Int) async -> CGImage?) {
        self.radius = radius
        self.count = count
        self.loader = loader
    }

    public func setCurrent(_ index: Int) {
        currentIndex = min(max(index, 0), max(count - 1, 0))
        let policy = WindowPolicy(radius: radius)
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
                guard Set(WindowPolicy(radius: self.radius).window(around: self.currentIndex, count: self.count)).union(self.ensuredIndices).contains(i) else { return }
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
        let policy = WindowPolicy(radius: radius)
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
                let currentKeep = Set(WindowPolicy(radius: self.radius).window(around: self.currentIndex, count: self.count)).union(self.ensuredIndices)
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

    /// Main-viewer window: radius 30 — the whole ±30 sliding window decodes
    /// at FULL resolution (no 2× screen cap). The current image and every
    /// neighbor land as true source pixels, so the Space loupe's "100%" is
    /// genuine 1:1 even for 45-60 MP raws, and scrubbing never waits on a
    /// downsample. Memory is bounded by the window (at most 61 full-res
    /// previews), not the shoot size: a 45-60 MP raw is ~135-180 MB decoded,
    /// so a full window runs ~8-11 GB on large-sensor shoots (see README
    /// "Memory stays flat"). Decodes share a gate so a window fill never
    /// fires 61 parallel ~180 MB decodes at once.
    public static func display(files: [SessionFile], cache: ImageCacheStore) -> ImageWindow {
        ImageWindow(radius: 30, count: files.count) { [cache] index in
            guard index >= 0, index < files.count else { return nil }
            let url = try? await cache.cacheURL(for: files[index])
            guard let url else { return nil }
            // A full-res 45 MP decode takes ~100-400 ms; run it off the main
            // actor (detached task) and throttle it through the shared gate
            // so a window fill decodes at most `limit` images concurrently.
            return await Task.detached(priority: .userInitiated) {
                displayDecodeGate.acquire()
                defer { displayDecodeGate.release() }
                return loadJPEGFullRes(at: url)
            }.value
        }
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
