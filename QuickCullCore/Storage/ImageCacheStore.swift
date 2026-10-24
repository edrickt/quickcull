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
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("QuickCull/cache", isDirectory: true)
    }

    private var baseDirEnsured = false
    private func ensureBaseDir() throws {
        if baseDirEnsured { return }
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        baseDirEnsured = true
    }

    /// Authoritative launch-time cleanup: delete everything, recreate.
    public func wipe() throws {
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
        try await ensureBaseDirExists()
        let destination = try cacheURL(for: file)
        let tmp = destination.appendingPathExtension("tmp")
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
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: destination)
        }
        return destination
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

    /// Store the raw histogram as an atomic JSON sidecar next to the JPEG.
    public func storeHistogram(_ hist: RawHistogram, for file: SessionFile) throws {
        try ensureBaseDir()
        let destination = try histogramURL(for: file)
        let tmp = destination.appendingPathExtension("tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let data = try JSONEncoder().encode(hist)
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: destination)
        }
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
}
