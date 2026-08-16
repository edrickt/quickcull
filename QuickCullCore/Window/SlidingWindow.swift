import CoreGraphics
import Foundation

/// Holds the filmstrip window: at most 2*radius+1 (61) thumbnail renderings,
/// loaded from the cached full-res JPEGs. Loads current-first, then outward;
/// evicts everything outside the window immediately.
@MainActor
public final class SlidingWindow {
    public let radius: Int
    public let count: Int
    public private(set) var thumbnails: [Int: CGImage] = [:]

    private let thumbnailLoader: (Int) async -> CGImage?
    private var inFlight: Set<Int> = []
    private var currentIndex: Int = 0

    public init(radius: Int, count: Int, thumbnailLoader: @escaping (Int) async -> CGImage?) {
        self.radius = radius
        self.count = count
        self.thumbnailLoader = thumbnailLoader
    }

    public func setCurrent(_ index: Int) {
        currentIndex = min(max(index, 0), max(count - 1, 0))
        let policy = WindowPolicy(radius: radius)

        let evict = policy.toEvict(resident: Set(thumbnails.keys),
                                   current: currentIndex, count: count)
        for i in evict {
            thumbnails.removeValue(forKey: i)
            inFlight.remove(i)
        }

        for i in policy.loadOrder(current: currentIndex, count: count)
        where thumbnails[i] == nil && !inFlight.contains(i) {
            inFlight.insert(i)
            Task { [weak self] in
                let image = await thumbnailLoader(i)
                guard let self else { return }
                self.inFlight.remove(i)
                guard policy.window(around: self.currentIndex, count: self.count).contains(i) else { return }
                if let image { self.thumbnails[i] = image }
            }
        }
        assert(thumbnails.count <= 2 * radius + 1, "filmstrip window invariant violated")
    }

    public func image(at index: Int) -> CGImage? { thumbnails[index] }

    /// Awaits until all in-flight loads settle (used by tests).
    public func waitUntilSettled() async {
        while !inFlight.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// Holds the main-view display renderings: current ±1 (max 3 images),
/// sized by the loader (2× screen long edge in production).
@MainActor
public final class DisplayImageProvider {
    public private(set) var images: [Int: CGImage] = [:]

    private let loader: (Int) async -> CGImage?
    private var currentIndex: Int = 0
    private var inFlight: Set<Int> = []

    public init(loader: @escaping (Int) async -> CGImage?) {
        self.loader = loader
    }

    public func setCurrent(_ index: Int) {
        currentIndex = index
        let desired = Set([index - 1, index, index + 1])
        for i in images.keys where !desired.contains(i) {
            images.removeValue(forKey: i)
            inFlight.remove(i)
        }
        for i in desired.sorted() where images[i] == nil && !inFlight.contains(i) {
            inFlight.insert(i)
            Task { [weak self] in
                let image = await loader(i)
                guard let self else { return }
                self.inFlight.remove(i)
                guard Set([self.currentIndex - 1, self.currentIndex, self.currentIndex + 1]).contains(i) else { return }
                if let image { self.images[i] = image }
            }
        }
        assert(images.count <= 3, "display window invariant violated")
    }

    public func image(at index: Int) -> CGImage? { images[index] }

    public func waitUntilSettled() async {
        while !inFlight.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
