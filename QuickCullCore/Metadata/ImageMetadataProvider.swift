import CoreGraphics
import Foundation
import ImageIO

public struct ImageMetadata: Equatable, Sendable {
    public let filename: String
    public let filePath: String
    public let dimensions: String?
    public let fileSize: String?
    public let camera: String?
    public let lens: String?
    public let iso: String?
    public let aperture: String?
    public let shutter: String?
    public let focalLength: String?
    public let dateTaken: String?
    public let exposureBias: String?
    public let whiteBalance: String?
}

public enum ImageMetadataProvider {
    /// EXIF DateTimeOriginal parser. Cached: metadata() runs per file and
    /// DateFormatter allocation is expensive. Thread-safe per Foundation's
    /// NSDateFormatter guarantee (macOS 10.9+).
    private static let exifDateParser: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    /// - Parameter cacheJPEGURL: URL of the file's decoded cache JPEG
    ///   (full-res, orientation baked in). The displayed `cgImage` is often a
    ///   320px thumbnail or a screen-limited downsample, so its dimensions
    ///   must never be treated as the file's true resolution.
    public static func metadata(for file: SessionFile, cgImage: CGImage?, cacheJPEGURL: URL? = nil) -> ImageMetadata {
        let filename = file.url.lastPathComponent
        let filePath = file.url.standardizedFileURL.path
        // Dimensions: decoded cache JPEG → source file props → displayed
        // CGImage (last resort only; see `cacheJPEGURL` doc).
        var dimensions: String?
        if let cacheJPEGURL {
            dimensions = pixelDimensions(at: cacheJPEGURL)
        }
        // File size
        var fileSize: String?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.url.path),
           let bytes = attrs[.size] as? NSNumber {
            fileSize = ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file)
        }
        // EXIF via CGImageSource
        var camera: String?
        var lens: String?
        var iso: String?
        var aperture: String?
        var shutter: String?
        var focalLength: String?
        var dateTaken: String?
        var exposureBias: String?
        var whiteBalance: String?

        if let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if dimensions == nil {
                dimensions = pixelDimensions(props)
            }
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                let make = tiff[kCGImagePropertyTIFFMake] as? String
                let model = tiff[kCGImagePropertyTIFFModel] as? String
                if make != nil || model != nil {
                    camera = [make, model].compactMap { $0 }.joined(separator: " ")
                }
            }
            // Lens: EXIF LensModel / AuxLensModel (TIFF LensModel does not exist as kCG constant)
            var exifLens: String?
            if let exifTmp = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exifLens = exifTmp[kCGImagePropertyExifLensModel] as? String
                    ?? exifTmp[kCGImagePropertyExifAuxLensModel] as? String
            }
            if let exifLens {
                lens = exifLens
            }

            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                if let isoArr = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = isoArr.first {
                    iso = "ISO \(first.intValue)"
                } else if let isoNum = exif[kCGImagePropertyExifISOSpeedRatings] as? NSNumber {
                    iso = "ISO \(isoNum.intValue)"
                }
                if let fnum = exif[kCGImagePropertyExifFNumber] as? NSNumber {
                    aperture = String(format: "f/%.1f", fnum.doubleValue)
                }
                if let exp = exif[kCGImagePropertyExifExposureTime] as? NSNumber {
                    let v = exp.doubleValue
                    if v > 0 && v < 1 {
                        shutter = String(format: "1/%.0fs", 1 / v)
                    } else {
                        shutter = String(format: "%gs", v)
                    }
                }
                if let fl = exif[kCGImagePropertyExifFocalLength] as? NSNumber {
                    focalLength = String(format: "%g mm", fl.doubleValue)
                }
                if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? NSNumber {
                    exposureBias = String(format: "%+.1f EV", bias.doubleValue)
                }
                if let wb = exif[kCGImagePropertyExifWhiteBalance] as? NSNumber {
                    whiteBalance = wb.intValue == 0 ? "Auto" : "Manual"
                }
                if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                    if let d = exifDateParser.date(from: dateStr) {
                        dateTaken = DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short)
                    } else {
                        dateTaken = dateStr
                    }
                }
            }
        }
        // Fallback dateTaken (runs whether or not the CGImageSource opened —
        // e.g., unsupported raw) — file creation date. EXIF date always
        // outranks it.
        if dateTaken == nil,
           let attrs = try? FileManager.default.attributesOfItem(atPath: file.url.path),
           let cdate = attrs[.creationDate] as? Date {
            dateTaken = DateFormatter.localizedString(from: cdate, dateStyle: .medium, timeStyle: .short)
        }
        // Last resort: the displayed image itself. This is what the user sees
        // on screen, but it may be a 320px thumbnail or a screen-limited
        // downsample, so it must never outrank the file's own metadata.
        if dimensions == nil, let img = cgImage {
            dimensions = "\(img.width)×\(img.height)"
        }

        return ImageMetadata(
            filename: filename,
            filePath: filePath,
            dimensions: dimensions,
            fileSize: fileSize,
            camera: camera,
            lens: lens,
            iso: iso,
            aperture: aperture,
            shutter: shutter,
            focalLength: focalLength,
            dateTaken: dateTaken,
            exposureBias: exposureBias,
            whiteBalance: whiteBalance
        )
    }

    /// Reads "W×H" from an image file's own properties (header only, no
    /// pixel decode). The cache JPEG is written from the full-res decode
    /// with orientation baked in, so its dimensions are the file's true
    /// resolution.
    private static func pixelDimensions(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        return pixelDimensions(props)
    }

    /// Parses "W×H" from an ImageIO properties dictionary (width/height may
    /// arrive as Int or NSNumber depending on the source format).
    private static func pixelDimensions(_ props: [CFString: Any]) -> String? {
        let w = (props[kCGImagePropertyPixelWidth] as? Int)
            ?? (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let h = (props[kCGImagePropertyPixelHeight] as? Int)
            ?? (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        guard let w, let h, w > 0, h > 0 else { return nil }
        return "\(w)×\(h)"
    }
}
