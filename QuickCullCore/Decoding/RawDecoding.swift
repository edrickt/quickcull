import CoreGraphics
import Foundation

public struct DecodeOptions: Sendable, Equatable {
    public var demosaicQuality: Int
    public var medianPasses: Int
    public var jpegQuality: CGFloat
    public init(demosaicQuality: Int = 3, medianPasses: Int = 0, jpegQuality: CGFloat = 0.75) {
        self.demosaicQuality = min(3, max(0, demosaicQuality))
        self.medianPasses = min(8, max(0, medianPasses))
        self.jpegQuality = min(0.95, max(0.5, jpegQuality))
    }
    public static let v1 = DecodeOptions()
}
/// A full-resolution, fully demosaiced image produced by a raw decoder.
public struct RawBitmap {
    public let image: CGImage
    public let width: Int
    public let height: Int
    /// LibRaw flip value (0-7). Informational only: the pixel buffer is
    /// already upright (dcraw_process applied the flip).
    public let flip: Int
    /// Rendered sRGB histogram (nil only if decode failed).
    public let histogram: RawHistogram?

    public init(image: CGImage, width: Int, height: Int, flip: Int, histogram: RawHistogram? = nil) {
        self.image = image
        self.width = width
        self.height = height
        self.flip = flip
        self.histogram = histogram
    }
}

public enum DecodeError: Error, Equatable {
    case initFailed
    case cannotOpen(String)
    case cannotUnpack(String)
    case cannotProcess(String)
    /// The source decoded, but its preview could not be written to the cache.
    /// A different failure class from the ones above: the file is fine, the
    /// cache is not, and a user can act on that distinction.
    case cannotStorePreview(String)
    case invalidOutput
}

/// Abstraction over the raw decoding engine. v1 has one implementation
/// (`LibRawDecoder`); swapping it (e.g. XPC isolation) must not affect callers.
public protocol RawDecoding {
    func decodeRaw(at url: URL, options: DecodeOptions) throws -> RawBitmap
}
public extension RawDecoding {
    func decodeRaw(at url: URL) throws -> RawBitmap { try decodeRaw(at: url, options: .v1) }
}
