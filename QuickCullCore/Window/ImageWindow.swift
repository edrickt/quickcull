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
/// Each position carries a stable identity (`ids`): loaders are addressed by
/// identity, and `retarget(ids:)` re-maps a window onto a new ordering while
/// keeping every decoded image, in-flight load and degraded flag whose
/// identity survives. That is what lets a filter switch or a flag drop-out
/// change the visible sequence without re-decoding the shoot.
///
/// Optional tiering: when `reducedLoader` + `upgradePolicy` are supplied,
/// indices outside the full tier load a reduced-size placeholder (half-size
/// decode) and are automatically re-run at full resolution once they enter
/// the tier (i.e. when the user lands on them). This keeps full-res memory
/// bounded by the tier while the window still pre-loads its whole extent.
@MainActor
@Observable
public final class ImageWindow {
    /// Ordered identity of each position. Loaders are addressed by identity
    /// rather than by position, so a `retarget(ids:)` can change the order
    /// without invalidating in-flight work or forcing re-decodes.
    public private(set) var ids: [String]
    public private(set) var images: [Int: CGImage] = [:]
    public var count: Int { ids.count }

    private let policy: WindowPolicy
    private let loader: (String) async -> CGImage?
    private let reducedLoader: ((String) async -> CGImage?)?
    /// True when the identity at `index` is outside the full tier of `current`.
    private let upgradePolicy: ((Int, Int) -> Bool)?
    /// Identity → position in `ids`; rebuilt whenever `ids` changes.
    private var positionsByID: [String: Int] = [:]
    /// Identities whose resident image is a reduced-size placeholder; the
    /// upgrade pass re-runs them once they enter the tier.
    private var degradedIDs: Set<String> = []
    /// Identities with a load in flight, and the task that owns it, so a
    /// superseded load can be cancelled before it burns a decode.
    private var inFlightIDs: Set<String> = []
    private var taskByID: [String: Task<Void, Never>] = [:]
    /// Token per identity so a cancelled load's completion can't clear the
    /// bookkeeping of a newer load that replaced it.
    private var loadTokens: [String: Int] = [:]
    private var nextLoadToken = 0
    private var currentIndex: Int = 0

    /// Symmetric window: `radius` images before and after current.
    ///
    /// Position-addressed convenience: identities are synthesized from the
    /// index (`"#0"`, `"#1"`, …). Use the identity initializer when the window
    /// must survive a projection change (see `retarget(ids:)`).
    public convenience init(radius: Int, count: Int, loader: @escaping (Int) async -> CGImage?) {
        self.init(policy: WindowPolicy(radius: radius), ids: Self.syntheticIDs(count),
                  loader: Self.positionalLoader(loader))
    }

    /// Asymmetric window: `behind` images before current, `ahead` after.
    public convenience init(behind: Int, ahead: Int, count: Int, loader: @escaping (Int) async -> CGImage?) {
        self.init(policy: WindowPolicy(behind: behind, ahead: ahead), ids: Self.syntheticIDs(count),
                  loader: Self.positionalLoader(loader))
    }

    /// Tiered window: see the type doc for `reducedLoader`/`upgradePolicy`.
    convenience init(behind: Int, ahead: Int, count: Int,
                     loader: @escaping (Int) async -> CGImage?,
                     reducedLoader: @escaping (Int) async -> CGImage?,
                     upgradePolicy: @escaping (Int, Int) -> Bool) {
        self.init(policy: WindowPolicy(behind: behind, ahead: ahead), ids: Self.syntheticIDs(count),
                  loader: Self.positionalLoader(loader),
                  reducedLoader: Self.positionalLoader(reducedLoader),
                  upgradePolicy: upgradePolicy)
    }

    /// Identity-addressed window. Every other initializer is a convenience
    /// over this one; `retarget(ids:)` requires identities.
    init(policy: WindowPolicy, ids: [String], loader: @escaping (String) async -> CGImage?,
         reducedLoader: ((String) async -> CGImage?)? = nil,
         upgradePolicy: ((Int, Int) -> Bool)? = nil) {
        assert(Set(ids).count == ids.count, "ImageWindow identities must be unique")
        self.policy = policy
        self.ids = ids
        self.loader = loader
        self.reducedLoader = reducedLoader
        self.upgradePolicy = upgradePolicy
        for (position, id) in ids.enumerated() { positionsByID[id] = position }
    }

    private static func syntheticIDs(_ count: Int) -> [String] {
        (0..<max(0, count)).map { "#\($0)" }
    }

    private static func positionalLoader(_ loader: @escaping (Int) async -> CGImage?) -> (String) async -> CGImage? {
        { id in
            guard let position = Int(id.dropFirst()) else { return nil }
            return await loader(position)
        }
    }

    /// Queues the loader for the identity at `index` (reduced or full per the
    /// tier policy) and publishes the result if that identity is still wanted.
    /// The result lands at the identity's *current* position, so a load that
    /// completes after a `retarget(ids:)` can never populate the wrong slot.
    private func startLoad(_ index: Int) {
        guard index >= 0, index < ids.count else { return }
        let id = ids[index]
        guard !inFlightIDs.contains(id) else { return }
        inFlightIDs.insert(id)
        let useReduced = reducedLoader != nil && (upgradePolicy?(index, currentIndex) ?? false)
        if useReduced { degradedIDs.insert(id) } else { degradedIDs.remove(id) }
        let load = useReduced ? (reducedLoader ?? loader) : loader
        nextLoadToken += 1
        let token = nextLoadToken
        loadTokens[id] = token
        taskByID[id] = Task { [weak self] in
            let image = await load(id)
            guard let self else { return }
            if self.loadTokens[id] == token {
                self.inFlightIDs.remove(id)
                self.taskByID.removeValue(forKey: id)
                self.loadTokens.removeValue(forKey: id)
            }
            guard let position = self.positionsByID[id] else {
                self.degradedIDs.remove(id)
                return
            }
            let currentKeep = Set(self.policy.window(around: self.currentIndex, count: self.count))
                .union(self.ensuredIndices)
            guard currentKeep.contains(position) else {
                self.degradedIDs.remove(id)
                return
            }
            if let image { self.images[position] = image }
        }
    }

    /// True when the identity at `index` has a load in flight.
    private func isInFlight(_ index: Int) -> Bool {
        guard index >= 0, index < ids.count else { return false }
        return inFlightIDs.contains(ids[index])
    }

    /// True when the identity at `index` currently holds a reduced placeholder.
    private func isDegraded(_ index: Int) -> Bool {
        guard index >= 0, index < ids.count else { return false }
        return degradedIDs.contains(ids[index])
    }

    public func setCurrent(_ index: Int) {
        currentIndex = min(max(index, 0), max(count - 1, 0))
        let windowSet = Set(policy.window(around: currentIndex, count: count))
        let keep = windowSet.union(ensuredIndices)
        evictOutsideWindow()
        for i in policy.loadOrder(current: currentIndex, count: count)
        where images[i] == nil && !isInFlight(i) {
            startLoad(i)
        }
        // Upgrade pass: indices that entered the full tier (typically the
        // image the user just landed on) re-run at full resolution, so the
        // loupe is always true 1:1 even after a far jump.
        if let upgradePolicy {
            for i in windowSet
            where isDegraded(i) && !upgradePolicy(i, currentIndex) && !isInFlight(i) {
                startLoad(i)
            }
        }
        pruneEnsuredIndices(windowSet: windowSet, keep: keep, recent: [])
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
        let keep = windowSet.union(ensuredIndices)
        evictOutsideWindow()
        // Only queue the explicitly ensured indices; window already queued by setCurrent.
        for i in ensuredIndices where images[i] == nil && !isInFlight(i) {
            startLoad(i)
        }
        pruneEnsuredIndices(windowSet: windowSet, keep: keep, recent: validNew)
    }

    /// Evicts every resident image outside `window ∪ ensuredIndices` and
    /// cancels its queued load, so a superseded decode never burns CPU for an
    /// image the user has left behind. Eviction targets come from the tested
    /// `WindowPolicy.toEvict` minus the ensured viewport.
    private func evictOutsideWindow() {
        let outside = policy.toEvict(resident: Set(images.keys), current: currentIndex, count: count)
        for i in outside where !ensuredIndices.contains(i) {
            images.removeValue(forKey: i)
            guard ids.indices.contains(i) else { continue }
            let id = ids[i]
            degradedIDs.remove(id)
            // Drop the in-flight marker with the task: if the identity
            // re-enters the window it must be able to queue a fresh load.
            inFlightIDs.remove(id)
            loadTokens.removeValue(forKey: id)
            taskByID.removeValue(forKey: id)?.cancel()
        }
    }

    /// Retargets the window at a new ordered identity list, preserving every
    /// resident image, degraded flag and in-flight load whose identity
    /// survives. Only the position mapping changes — the loaders are addressed
    /// by identity, so they stay valid.
    ///
    /// Callers use this instead of building a new window when the projection
    /// changes (filter switch, flag drop-out, commit): a rebuild would discard
    /// every decoded image and re-decode the whole window. Follow it with
    /// `setCurrent` (AppState's `syncWindows` does) to apply the policy over
    /// the new order.
    public func retarget(ids newIDs: [String]) {
        let oldIDs = ids
        guard newIDs != oldIDs else { return }
        assert(Set(newIDs).count == newIDs.count, "ImageWindow identities must be unique")
        let currentID = oldIDs.indices.contains(currentIndex) ? oldIDs[currentIndex] : nil

        var newPositions: [String: Int] = [:]
        newPositions.reserveCapacity(newIDs.count)
        for (position, id) in newIDs.enumerated() { newPositions[id] = position }

        // Work and flags for identities that left the projection are dropped.
        for id in taskByID.keys where newPositions[id] == nil {
            taskByID.removeValue(forKey: id)?.cancel()
            loadTokens.removeValue(forKey: id)
        }
        inFlightIDs.formIntersection(newPositions.keys)
        degradedIDs.formIntersection(newPositions.keys)

        // Resident images follow their identity to its new position.
        var remapped: [Int: CGImage] = [:]
        for (oldPosition, image) in images {
            guard oldIDs.indices.contains(oldPosition),
                  let position = newPositions[oldIDs[oldPosition]] else { continue }
            remapped[position] = image
        }
        images = remapped
        ids = newIDs
        positionsByID = newPositions
        remapEnsuredIndices(oldIDs: oldIDs, newPositions: newPositions)

        if let currentID, let position = newPositions[currentID] {
            currentIndex = position
        } else {
            currentIndex = min(max(currentIndex, 0), max(count - 1, 0))
        }
        evictOutsideWindow()
    }

    /// `ensuredIndices` holds positions in the old order, so it is remapped
    /// through identity alongside the images (entries whose identity left the
    /// projection are dropped).
    private func remapEnsuredIndices(oldIDs: [String], newPositions: [String: Int]) {
        var remapped: Set<Int> = []
        var remappedOrder: [Int] = []
        for oldPosition in ensuredOrder {
            guard oldIDs.indices.contains(oldPosition),
                  let position = newPositions[oldIDs[oldPosition]] else { continue }
            remapped.insert(position)
            remappedOrder.append(position)
        }
        ensuredIndices = remapped
        ensuredOrder = remappedOrder
    }

    /// Bounds `ensuredIndices` to the window ∪ a small recent viewport:
    /// drops entries outside `keep`, then LRU-caps the remainder at the 40
    /// most recent ensures beyond the window. Without the cap, ensured
    /// indices grow monotonically and retain thumbs for the whole shoot,
    /// violating the bounded viewport + window invariant.
    private func pruneEnsuredIndices(windowSet: Set<Int>, keep: Set<Int>, recent: [Int]) {
        let maxViewport = 40
        ensuredIndices = ensuredIndices.intersection(keep).filter { $0 >= 0 && $0 < count }
        ensuredOrder = ensuredOrder.filter { ensuredIndices.contains($0) }
        let cap = windowSet.count + maxViewport
        guard ensuredIndices.count > cap else { return }
        let keepSet = windowSet
            .union(ensuredOrder.suffix(maxViewport))
            .union(recent)
        for idx in ensuredIndices.subtracting(keepSet) {
            ensuredIndices.remove(idx)
        }
        ensuredOrder = ensuredOrder.filter { ensuredIndices.contains($0) }
    }

    public func image(at index: Int) -> CGImage? { images[index] }

    /// Awaits until all in-flight loads settle, the optional timeout
    /// expires, or the caller is cancelled (used by tests).
    public func waitUntilSettled(timeout: TimeInterval? = nil) async {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while !inFlightIDs.isEmpty {
            if let deadline, Date() >= deadline { return }
            do { try await Task.sleep(nanoseconds: 5_000_000) }
            catch { return }   // cancelled: stop waiting
        }
    }

    // MARK: App factories

    /// Filmstrip window: bounded radius, 320px thumbnails. Cells call
    /// `ensureLoaded` as they appear, so a cell scrolled past the window shows
    /// a placeholder only until its own load lands — and memory stays bounded
    /// by the window, not by the shoot.
    public static func thumbnails(files: [SessionFile], cache: ImageCacheStore) -> ImageWindow {
        ImageWindow(policy: WindowPolicy(radius: Self.stripRadius),
                    ids: files.map(\.id),
                    loader: thumbnailLoader(byID: filesByID(files), cache: cache))
    }

    /// Grid window: every thumbnail is *eligible* (no sliding window), so
    /// scrolling the grid never unloads a visible cell — the radius-30 window
    /// did exactly that. Loading stays lazy: the grid never receives
    /// `setCurrent`, so only the cells that actually appear are decoded (each
    /// cell calls `ensureLoaded`) instead of the whole shoot at import time.
    public static func gridThumbnails(files: [SessionFile], cache: ImageCacheStore) -> ImageWindow {
        ImageWindow(policy: WindowPolicy(radius: files.count),
                    ids: files.map(\.id),
                    loader: thumbnailLoader(byID: filesByID(files), cache: cache))
    }

    /// Filmstrip window extent (see `thumbnails`).
    nonisolated static var stripRadius: Int { 30 }

    private static func filesByID(_ files: [SessionFile]) -> [String: SessionFile] {
        var byID: [String: SessionFile] = [:]
        byID.reserveCapacity(files.count)
        for file in files { byID[file.id] = file }
        return byID
    }

    /// Identity-addressed thumbnail loader, so a `retarget(ids:)` never leaves
    /// it holding a stale position → file mapping.
    private static func thumbnailLoader(byID: [String: SessionFile],
                                        cache: ImageCacheStore) -> (String) async -> CGImage? {
        { id in
            guard let file = byID[id] else { return nil }
            let url = try? await cache.cacheURL(for: file)
            return await Task.detached(priority: .utility) {
                await thumbnailDecodeLimiter.withSlot {
                    guard !Task.isCancelled else { return nil }
                    return decodeJPEG(at: url, maxPixelSize: 320)
                }
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
        let byID = filesByID(files)
        return ImageWindow(policy: WindowPolicy(behind: Self.displayExtentBehind,
                                                ahead: Self.displayExtentAhead),
                           ids: files.map(\.id),
                           loader: { id in
            guard let file = byID[id] else { return nil }
            let url = try? await cache.cacheURL(for: file)
            guard let url else { return nil }
            // A full-res 20-45 MP decode takes ~100-400 ms; run it off the
            // main actor (detached task) and throttle it through the shared
            // gate so concurrent fills stay bounded.
            return await Task.detached(priority: .userInitiated) {
                await displayDecodeLimiter.withSlot {
                    guard !Task.isCancelled else { return nil }
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return loadJPEGFullRes(at: url)
                }
            }.value
        },
        reducedLoader: { id in
            guard let file = byID[id] else { return nil }
            let url = try? await cache.cacheURL(for: file)
            guard let url else { return nil }
            return await Task.detached(priority: .utility) {
                await displayDecodeLimiter.withSlot {
                    guard !Task.isCancelled else { return nil }
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return loadJPEGHalfRes(at: url)
                }
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
        guard let longEdge = jpegLongEdge(at: url) else { return nil }
        return decodeJPEG(at: url, maxPixelSize: longEdge / 2)
    }

    /// Full-resolution decode of a cached JPEG: reads the JPEG's own header
    /// dimensions and asks the thumbnail API for exactly that long edge, so
    /// nothing is ever downsampled. Cache JPEGs are already upright (no EXIF
    /// orientation tag), so `WithTransform` is a no-op kept for symmetry with
    /// the thumbnail path. CPU-bound, so callers run it off the main actor.
    nonisolated static func loadJPEGFullRes(at url: URL?) -> CGImage? {
        guard let longEdge = jpegLongEdge(at: url) else { return nil }
        return decodeJPEG(at: url, maxPixelSize: longEdge)
    }

    /// Downsamples a cached JPEG (thumbnail API = memory-bounded). Decoding
    /// is CPU-bound (tens to hundreds of ms for a 45 MP cache entry), so
    /// callers run this off the main actor via a detached task.
    nonisolated private static func decodeJPEG(at url: URL?, maxPixelSize: Int) -> CGImage? {
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Reads a cached JPEG's own header dimensions (header only, no pixel
    /// decode) and returns the long edge, or nil when unreadable.
    nonisolated private static func jpegLongEdge(at url: URL?) -> Int? {
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return max(width, height)
    }
}

/// Bounds concurrent full-res display decodes across all `ImageWindow.display`
/// windows. One process-wide limiter so a window rebuild never starts a second
/// parallel fill, and a fill never decodes 61 ~180 MB images at once. Waiters
/// suspend rather than block a cooperative-pool thread, and a superseded load
/// (cancelled by eviction or retarget) skips its decode when it reaches the
/// front of the queue. FIFO order is approximate under contention, which is
/// fine: `loadOrder` already queues the current image first.
private let displayDecodeLimiter = DecodeLimiter(limit: 3)

/// Bounds thumbnail decodes. The strip and the grid can queue many small
/// decodes at once; a small limit keeps them from crowding the same pool the
/// display work uses.
private let thumbnailDecodeLimiter = DecodeLimiter(limit: 4)
