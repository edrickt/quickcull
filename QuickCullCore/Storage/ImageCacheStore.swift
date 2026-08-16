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

    /// Authoritative launch-time cleanup: delete everything, recreate.
    public func wipe() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: baseURL.path) {
            try fm.removeItem(at: baseURL)
        }
        try fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    /// Cache key: SHA256 of "<standardized path>|<size>|<mtime-us>".
    /// When the source file cannot be stat-ed (deleted mid-session, or a
    /// synthetic/test file), falls back to the path-only key so the decoded
    /// bitmap can still be cached deterministically.
    public func cacheURL(for file: SessionFile) throws -> URL {
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
    @discardableResult
    public func storeJPEG(_ bitmap: RawBitmap, for file: SessionFile) throws -> URL {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let destination = try cacheURL(for: file)
        let tmp = destination.appendingPathExtension("tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let sink = CGImageDestinationCreateWithURL(
            tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CacheError.cannotCreateDestination
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: Self.jpegQuality]
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

    public func deleteCachedJPEG(for file: SessionFile) {
        if let url = try? cacheURL(for: file) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

public enum CacheError: Error {
    case cannotCreateDestination
    case cannotEncode
}
