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
    public func cacheURL(for file: SessionFile) throws -> URL {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.url.path)
        let size = (attrs[.size] as? UInt64) ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(file.id)|\(size)|\(Int(mtime * 1_000_000))"
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return baseURL.appendingPathComponent(hex + ".jpg")
    }

    /// Encode the bitmap to a q75 JPEG and write it atomically (tmp + rename).
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
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: Self.jpegQuality]
        if let orientation = exifOrientation(forFlip: bitmap.flip) {
            props[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(sink, bitmap.image, props as CFDictionary)
        guard CGImageDestinationFinalize(sink) else {
            throw CacheError.cannotEncode
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
        return destination
    }

    public func deleteCachedJPEG(for file: SessionFile) {
        if let url = try? cacheURL(for: file) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// dcraw flip code -> EXIF orientation (1-8); nil when unknown.
    public func exifOrientation(forFlip flip: Int) -> Int? {
        switch flip {
        case 0: return 1
        case 1: return 2
        case 2: return 4
        case 3: return 3
        case 4: return 5
        case 5: return 8
        case 6: return 6
        case 7: return 7
        default: return nil
        }
    }
}

public enum CacheError: Error {
    case cannotCreateDestination
    case cannotEncode
}
