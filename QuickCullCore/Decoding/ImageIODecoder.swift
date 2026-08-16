import CoreGraphics
import Foundation
import ImageIO

/// Decodes common image formats (JPEG, PNG, HEIC/HEIF) via ImageIO at full
/// resolution. EXIF orientation is baked into the pixels, so the cache's
/// JPEGs and the scrub view both show upright images (mirroring how LibRaw
/// output is already rotated).
public final class ImageIODecoder: RawDecoding {

    public init() {}

    public func decodeRaw(at url: URL) throws -> RawBitmap {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw DecodeError.cannotOpen("cannot open image source")
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw DecodeError.invalidOutput
        }

        // Full-resolution decode; the thumbnail API with transform bakes the
        // EXIF orientation into the pixels (mirrors AppState.loadJPEG).
        let maxPixel = max(width, height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw DecodeError.cannotProcess("image decode failed")
        }

        return RawBitmap(image: image,
                         width: image.width,
                         height: image.height,
                         flip: 0)   // orientation baked in
    }
}

/// Routes files to the right decoder pipeline by extension.
public struct RoutingDecoder: RawDecoding {
    private let librawDecoder: RawDecoding
    private let imageIODecoder: RawDecoding

    public init(librawDecoder: RawDecoding, imageIODecoder: RawDecoding) {
        self.librawDecoder = librawDecoder
        self.imageIODecoder = imageIODecoder
    }

    public func decodeRaw(at url: URL) throws -> RawBitmap {
        switch RawFileIdentity.decoderKind(for: url) {
        case .libraw: return try librawDecoder.decodeRaw(at: url)
        case .imageIO: return try imageIODecoder.decodeRaw(at: url)
        case nil: throw DecodeError.cannotOpen("Unsupported format")
        }
    }
}
