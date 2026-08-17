import AppKit
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
        let keep = Set(policy.window(around: currentIndex, count: count)).union(ensuredIndices)
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
        // images.count may now exceed 2*radius+1 due to ensured grid cells; cap assertion relaxed for grid
        // assert(images.count <= 2 * radius + 1, "window invariant violated")
    }

    private var ensuredIndices: Set<Int> = []

    public func ensureLoaded(indices: [Int]) {
        let policy = WindowPolicy(radius: radius)
        let windowSet = Set(policy.window(around: currentIndex, count: count))
        for idx in indices where idx >= 0 && idx < count {
            ensuredIndices.insert(idx)
        }
        // Evict anything outside window ∪ ensured
        let keep = windowSet.union(ensuredIndices)
        for i in Set(images.keys) where !keep.contains(i) {
            images.removeValue(forKey: i)
            inFlight.remove(i)
        }
        // But actually only queue the explicitly ensured indices; window already queued by setCurrent. So filter to ensured:
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
        // Also prune ensuredIndices that are now out of window and not recently re-ensured? Keep for simplicity; eviction already handles images.
        // But to avoid unbounded ensuredIndices growth, intersect with count range:
        ensuredIndices = Set(ensuredIndices.filter { $0 >= 0 && $0 < count })
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

    /// Main-viewer window: radius 1, display size (2× screen long edge).
    public static func display(files: [SessionFile], cache: ImageCacheStore) -> ImageWindow {
        let pixels = displayPixelLimit()
        return ImageWindow(radius: 1, count: files.count) { [cache] index in
            guard index >= 0, index < files.count else { return nil }
            let url = try? await cache.cacheURL(for: files[index])
            // Downsampling a 45 MP cache entry takes ~100-400 ms; decode it
            // off the main actor so the UI stays responsive while scrubbing.
            return await Task.detached(priority: .userInitiated) {
                loadJPEG(at: url, maxPixelSize: pixels)
            }.value
        }
    }

    private static func displayPixelLimit() -> Int {
        Int(max(NSScreen.main?.frame.width ?? 1920,
                NSScreen.main?.frame.height ?? 1080) * 2)
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
