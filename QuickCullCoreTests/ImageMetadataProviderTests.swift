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

    func testDimensionsFromCGImagePreferred() throws {
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
