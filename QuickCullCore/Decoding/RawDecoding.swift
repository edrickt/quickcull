import CoreGraphics
import Foundation

/// A full-resolution, fully demosaiced image produced by a raw decoder.
public struct RawBitmap {
    public let image: CGImage
    public let width: Int
    public let height: Int
    /// LibRaw flip value (0-7). Informational only: the pixel buffer is
    /// already upright (dcraw_process applied the flip).
    public let flip: Int
    /// Raw linear histogram (nil only if decode failed).
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
    case invalidOutput
}

/// Abstraction over the raw decoding engine. v1 has one implementation
/// (`LibRawDecoder`); swapping it (e.g. XPC isolation) must not affect callers.
public protocol RawDecoding {
    func decodeRaw(at url: URL) throws -> RawBitmap
}
