import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Owns the decoded-JPEG cache directory. Full-res q75 JPEGs keyed by
/// source file identity (path + size + mtime). Wiped on every launch.
public actor ImageCacheStore {

    public static let jpegQuality: CGFloat = 0.75

    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public static func defaultBaseURL() -> URL {
        // `applicationSupportDirectory` is effectively always present, but a
        // force-unwrap here would crash the app on first launch if it ever
        // were not (managed / locked-down volumes). Fall back to the temp
        // dir rather than dying: the cache is disposable by design.
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("QuickCull/cache", isDirectory: true)
    }

    private var baseDirEnsured = false
    private func ensureBaseDir() throws {
        if baseDirEnsured { return }
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        baseDirEnsured = true
    }

    /// Bumped by every `wipe()`. A store call that began before a wipe must not
    /// write into the fresh cache: `startNewSession` cancels the import and then
    /// wipes fire-and-forget, so a decode already past its cancellation check
    /// can still hold a bitmap. Without this guard that dead session's preview
    /// reappears in the new cache directory.
    private var storeGeneration = 0

    func currentStoreGeneration() -> Int { storeGeneration }

    private func isCurrentGeneration(_ generation: Int) -> Bool { storeGeneration == generation }

    /// Authoritative launch-time cleanup: delete everything, recreate.
    public func wipe() throws {
        storeGeneration += 1
        let fm = FileManager.default
        if fm.fileExists(atPath: baseURL.path) {
            try fm.removeItem(at: baseURL)
        }
        try fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
        baseDirEnsured = false
    }

    /// Cache key: SHA256 of "<standardized path>|<size>|<mtime-us>".
    /// When the source file cannot be stat-ed (deleted mid-session, or a
    /// synthetic/test file), falls back to the path-only key so the decoded
    /// bitmap can still be cached deterministically.
    ///
    /// `nonisolated`: it reads no actor state, and every decode worker needs
    /// it, so it must not queue behind the cache's isolation.
    public nonisolated func cacheURL(for file: SessionFile) throws -> URL {
        var key = file.id
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.url.path) {
            let size = (attrs[.size] as? UInt64) ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            key = "\(file.id)|\(size)|\(Int(mtime * 1_000_000))"
        }
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return baseURL.appendingPathComponent(hex + ".jpg")
    }

    /// Encode the bitmap to a q75 JPEG and write it atomically (tmp + rename).
    ///
    /// The bitmap is already upright: `dcraw_process` applies the raw's flip
    /// to the pixel buffer before we ever see it. No EXIF orientation tag is
    /// written, so consumers must not transform the pixels again.
    ///
    /// `nonisolated` on purpose: the encode of a 45 MP frame is 100-400 ms of
    /// CPU, and running it inside the actor would serialize every decode
    /// worker behind one encoder. Only the directory check takes isolation;
    /// each file has its own destination, so concurrent encodes cannot race.
    @discardableResult
    public nonisolated func storeJPEG(_ bitmap: RawBitmap, for file: SessionFile,
                                      quality: CGFloat) async throws -> URL {
        // Snapshot before the encode: the write must not land if a wipe lands
        // while this is working.
        let generation = await currentStoreGeneration()
        return try await storeJPEG(bitmap, for: file, quality: quality, assuming: generation)
    }

    /// `assuming` is the cache generation the caller saw when it started.
    /// Internal so a test can drive a pre-wipe snapshot deterministically.
    @discardableResult
    nonisolated func storeJPEG(_ bitmap: RawBitmap, for file: SessionFile, quality: CGFloat,
                               assuming generation: Int) async throws -> URL {
        try await ensureBaseDirExists()
        let destination = try cacheURL(for: file)
        // Unique per write: two stores of the same identity (a re-import racing a
        // post-cancel store from the previous import) would otherwise share one
        // temp path, truncate each other's encode, and fail the loser with ENOENT.
        let tmp = destination.appendingPathExtension("tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let sink = CGImageDestinationCreateWithURL(
            tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CacheError.cannotCreateDestination
        }
        let q = min(0.95, max(0.5, quality))
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: q]
        CGImageDestinationAddImage(sink, bitmap.image, props as CFDictionary)
        guard CGImageDestinationFinalize(sink) else {
            throw CacheError.cannotEncode
        }
        guard await isCurrentGeneration(generation) else {
            throw CacheError.staleGeneration
        }
        try Self.moveIntoPlace(tmp: tmp, destination: destination)
        return destination
    }

    /// Publishes a fully written temp file at its cache location.
    ///
    /// Two stores of the same identity can race (a re-import overlapping a
    /// post-cancel store from the previous import), and both can see no
    /// destination before either moves: the loser's `moveItem` then fails with
    /// "item with the same name already exists". Replacing is the same outcome —
    /// both writes carry this key — so the loser falls back to it.
    private static func moveIntoPlace(tmp: URL, destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: tmp, to: destination)
        } catch {
            guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
            _ = try? FileManager.default.replaceItemAt(destination, withItemAt: tmp)
        }
    }

    @discardableResult
    public nonisolated func storeJPEG(_ bitmap: RawBitmap, for file: SessionFile) async throws -> URL {
        try await storeJPEG(bitmap, for: file, quality: Self.jpegQuality)
    }

    private func ensureBaseDirExists() throws {
        try ensureBaseDir()
    }

    /// Sidecar URL for the raw histogram: same cache key, `.hist.json`.
    public nonisolated func histogramURL(for file: SessionFile) throws -> URL {
        Self.histogramURL(beside: try cacheURL(for: file))
    }

    /// The histogram sidecar that belongs beside a cached JPEG.
    public nonisolated static func histogramURL(beside jpegURL: URL) -> URL {
        jpegURL.appendingPathExtension("hist").appendingPathExtension("json")
    }

    /// Store the raw histogram as an atomic JSON sidecar next to the JPEG it
    /// describes. Takes the JPEG's URL rather than re-deriving the key: the key
    /// embeds the source's size and mtime, and a key computed at a later instant
    /// could split a sidecar from its JPEG (leaving the HUD on the rendered
    /// fallback for no reason).
    public nonisolated func storeHistogram(_ hist: RawHistogram, beside jpegURL: URL) async throws {
        let generation = await currentStoreGeneration()
        try await storeHistogram(hist, beside: jpegURL, assuming: generation)
    }

    /// `assuming` is the cache generation the caller saw (see `storeJPEG`): a
    /// sidecar whose session was wiped mid-write must not land in the fresh
    /// cache, which would leave an orphan `.hist.json` behind the wipe.
    nonisolated func storeHistogram(_ hist: RawHistogram, beside jpegURL: URL,
                                    assuming generation: Int) async throws {
        try await ensureBaseDirExists()
        guard await isCurrentGeneration(generation) else { throw CacheError.staleGeneration }
        let destination = Self.histogramURL(beside: jpegURL)
        let tmp = destination.appendingPathExtension("tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let data = try JSONEncoder().encode(hist)
        try data.write(to: tmp)
        try Self.moveIntoPlace(tmp: tmp, destination: destination)
    }

    /// Load the raw histogram sidecar; nil when missing or corrupt.
    public func loadHistogram(for file: SessionFile) throws -> RawHistogram? {
        let url = try histogramURL(for: file)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let hist = try? JSONDecoder().decode(RawHistogram.self, from: data) else {
            return nil
        }
        return hist
    }

    public func deleteCachedHistogram(for file: SessionFile) {
        if let url = try? histogramURL(for: file) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func deleteCachedJPEG(for file: SessionFile) {
        if let url = try? cacheURL(for: file) {
            deleteCachedPreviews(at: url)
        }
    }

    /// Deletes a preview and its histogram from a location resolved while the
    /// source file still existed. The cache key embeds the source's size and
    /// mtime, so after a trash or a move the key can no longer be recomputed:
    /// callers resolve the URL first and pass it here.
    public func deleteCachedPreviews(at jpegURL: URL) {
        try? FileManager.default.removeItem(at: jpegURL)
        try? FileManager.default.removeItem(at: Self.histogramURL(beside: jpegURL))
    }
}

public enum CacheError: Error {
    case cannotCreateDestination
    case cannotEncode
    /// The cache was wiped while this write was in flight.
    case staleGeneration
}
