import CoreGraphics
import Foundation
import ImageIO

/// Fast placeholder image for a file whose cache JPEG does not exist yet
/// (progressive scrub): the raw's embedded camera JPEG for LibRaw files, a
/// small ImageIO thumbnail for standard formats. Must be fast (~10-100 ms)
/// and thread-safe — every call creates its own LibRaw handle.
///
/// The placeholder is transient: when the real decode lands, the windows
/// retry the index and the full-res cache JPEG replaces it.
public enum FastPreview {
    public static func image(for url: URL) -> CGImage? {
        switch RawFileIdentity.decoderKind(for: url) {
        case .libraw: return LibRawDecoder.embeddedPreview(at: url)
        case .imageIO: return thumbnail(at: url)
        case nil: return nil
        }
    }

    /// Standard formats: the file IS the image, so a capped thumbnail
    /// decode is the fast preview (JPEG DCT-subsampled, HEIC embedded
    /// preview). Orientation baked in, mirroring the ingest path.
    static func thumbnail(at url: URL, maxPixelSize: Int = 1920) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
