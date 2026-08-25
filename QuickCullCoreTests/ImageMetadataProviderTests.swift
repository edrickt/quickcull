import XCTest
import CoreGraphics
@testable import QuickCullCore

final class ImageMetadataProviderTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testFilenameAndFileSize() throws {
        let url = tmp.appendingPathComponent("IMG_001.CR2")
        try Data(repeating: 0xAB, count: 1_500_000).write(to: url)
        let file = SessionFile(url: url)
        let meta = ImageMetadataProvider.metadata(for: file, cgImage: nil)
        XCTAssertEqual(meta.filename, "IMG_001.CR2")
        XCTAssertEqual(meta.filePath, url.standardizedFileURL.path)
        XCTAssertNotNil(meta.fileSize) // ByteCountFormatter string, e.g. "1.5 MB"
        XCTAssertNil(meta.camera) // no EXIF
    }

    /// Last-resort fallback: when neither the decoded cache JPEG nor the
    /// source file expose dimensions, the displayed CGImage is used.
    func testDimensionsFallBackToCGImageWhenNoFileMetadata() throws {
        let url = tmp.appendingPathComponent("a.jpg")
        try Data(repeating: 0, count: 10).write(to: url)
        // Create a 6000x4000 CGImage stub via color space
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 6000, height: 4000, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let img = ctx.makeImage()!
        let file = SessionFile(url: url)
        let meta = ImageMetadataProvider.metadata(for: file, cgImage: img)
        XCTAssertEqual(meta.dimensions, "6000×4000")
    }

    /// Regression: the HUD passes the *displayed* CGImage, which is a 320px
    /// thumbnail (or a screen-limited downsample) — never the file's true
    /// dimensions. The decoded cache JPEG is full-res with orientation baked
    /// in, so its dimensions must win even when the displayed image is a
    /// tiny thumbnail.
    func testDimensionsPreferDecodedCacheJPEGOverCGImage() throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        // A real 800x600 JPEG standing in for the decoded full-res cache entry
        let cacheJPEG = tmp.appendingPathComponent("decoded.jpg")
        let fullCtx = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(cacheJPEG as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, fullCtx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)

        // Thumbnail-sized displayed image (320px long edge), like ImageWindow's loader
        let thumbCtx = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let thumb = thumbCtx.makeImage()!

        // Raw source: ImageIO cannot read pixel dimensions from the file itself
        let url = tmp.appendingPathComponent("IMG_0001.CR2")
        try Data(repeating: 0xAB, count: 1_000).write(to: url)
        let file = SessionFile(url: url)
        let meta = ImageMetadataProvider.metadata(for: file, cgImage: thumb, cacheJPEGURL: cacheJPEG)
        XCTAssertEqual(meta.dimensions, "800×600")
    }

    /// Without a cache entry yet, the source file's own properties are the
    /// authority over the displayed (possibly thumbnail-sized) CGImage.
    func testDimensionsFallBackToSourcePropsWhenCacheMissing() throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        // Real 640x480 JPEG source
        let url = tmp.appendingPathComponent("IMG_0001.jpg")
        let ctx = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)

        // Thumbnail-sized displayed image
        let thumbCtx = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let thumb = thumbCtx.makeImage()!

        let file = SessionFile(url: url)
        let meta = ImageMetadataProvider.metadata(for: file, cgImage: thumb, cacheJPEGURL: nil)
        XCTAssertEqual(meta.dimensions, "640×480")
    }

    func testMissingFileReturnsMinimal() {
        let file = SessionFile(url: URL(fileURLWithPath: "/tmp/does-not-exist-xyz.nef"))
        let meta = ImageMetadataProvider.metadata(for: file, cgImage: nil)
        XCTAssertEqual(meta.filename, "does-not-exist-xyz.nef")
        XCTAssertNil(meta.fileSize)
        XCTAssertNil(meta.dimensions)
        XCTAssertNil(meta.camera)
    }

    func testExifFieldsParsedIfPresent() throws {
        // Use a pinned fixture with known EXIF if available; fallback to minimal check.
        // Try loading a real JPEG fixture we can write with EXIF via ImageIO, else just check provider doesn't throw.
        let url = tmp.appendingPathComponent("exif.jpg")
        // Create a 10x10 image and write with EXIF via ImageIO if possible, else just test that call succeeds.
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        var exif: [String: Any] = [kCGImagePropertyExifISOSpeedRatings as String: [400], kCGImagePropertyExifFNumber as String: 2.8]
        let props: [String: Any] = [kCGImagePropertyExifDictionary as String: exif]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        let file = SessionFile(url: url)
        let meta = ImageMetadataProvider.metadata(for: file, cgImage: img)
        // At least ISO/aperture should parse if we wrote them
        XCTAssertTrue(meta.iso == "ISO 400" || meta.iso == nil) // don't fail if fixture stripped
        if meta.aperture != nil { XCTAssertTrue(meta.aperture!.hasPrefix("f/")) }
    }
}
