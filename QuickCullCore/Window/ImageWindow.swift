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

        // Materialize the key set: mutating `images` while iterating its
        // keys is technically undefined.
        for i in Set(images.keys) where !policy.window(around: currentIndex, count: count).contains(i) {
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
                guard policy.window(around: self.currentIndex, count: self.count).contains(i) else { return }
                if let image { self.images[i] = image }
            }
        }
        assert(images.count <= 2 * radius + 1, "window invariant violated")
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
            return loadJPEG(at: try? await cache.cacheURL(for: files[index]),
                            maxPixelSize: 320)
        }
    }

    /// Main-viewer window: radius 1, display size (2× screen long edge).
    public static func display(files: [SessionFile], cache: ImageCacheStore) -> ImageWindow {
        let pixels = displayPixelLimit()
        return ImageWindow(radius: 1, count: files.count) { [cache] index in
            guard index >= 0, index < files.count else { return nil }
            return loadJPEG(at: try? await cache.cacheURL(for: files[index]),
                            maxPixelSize: pixels)
        }
    }

    private static func displayPixelLimit() -> Int {
        Int(max(NSScreen.main?.frame.width ?? 1920,
                NSScreen.main?.frame.height ?? 1080) * 2)
    }

    /// Downsamples a cached JPEG (thumbnail API = memory-bounded).
    private static func loadJPEG(at url: URL?, maxPixelSize: Int) -> CGImage? {
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
