import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import QuickCullCore

final class ImageIODecoderTests: XCTestCase {
    private var fixtureDir: URL!

    override func setUp() async throws {
        fixtureDir = try TestFixtures.makeTempDir(name: "imageio")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    /// Writes a solid-color image in the given format. `orientation` is the
    /// EXIF orientation (1-8) written into the file when non-nil.
    private func writeImage(format: String, name: String, width: Int = 64, height: Int = 40,
                            orientation: Int? = nil) throws -> URL {
        let url = fixtureDir.appendingPathComponent("\(name).\(format)")
        var bytes = [UInt8](repeating: 200, count: width * height * 3)
        for i in 0..<width * height { bytes[i * 3] = UInt8(i % 256) }
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                            bitsPerPixel: 24, bytesPerRow: width * 3,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        // The system has no HEIF encoder; a HEIC-encoded container with the
        // .heif extension exercises the same decode path (ImageIO sniffs
        // content, not extension).
        let types: [String: UTType] = [
            "jpg": .jpeg, "jpeg": .jpeg, "png": .png,
            "heic": .heic, "heif": .heic,
        ]
        guard let type = types[format] else {
            XCTFail("no UTType for \(format)")
            throw NSError(domain: "test", code: 1)
        }
        guard let sink = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            XCTFail("cannot create destination for \(format)")
            throw NSError(domain: "test", code: 2)
        }
        var props: [CFString: Any] = [:]
        if let orientation {
            props[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(sink, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(sink), "encoding \(format) failed")
        return url
    }

    func testDecodesAllSupportedFormats() throws {
        let decoder = ImageIODecoder()
        let cases: [(String, Int, Int)] = [
            ("jpg", 64, 40),
            ("jpeg", 64, 40),
            ("png", 64, 40),
            ("heic", 64, 40),
            ("heif", 64, 40),
        ]
        for (format, w, h) in cases {
            let url = try writeImage(format: format, name: "img")
            let bitmap = try decoder.decodeRaw(at: url)
            XCTAssertEqual(bitmap.width, w, format)
            XCTAssertEqual(bitmap.height, h, format)
            XCTAssertEqual(bitmap.image.width, w, format)
        }
    }

    func testExifOrientationIsBakedIntoPixels() throws {
        // Source is 64x40 landscape; orientation 6 = rotate 90 CW -> upright
        // pixels must be 40x64.
        let url = try writeImage(format: "jpg", name: "rotated", orientation: 6)
        let bitmap = try ImageIODecoder().decodeRaw(at: url)
        XCTAssertEqual(bitmap.width, 40)
        XCTAssertEqual(bitmap.height, 64)
        XCTAssertEqual(bitmap.image.width, 40)
        XCTAssertEqual(bitmap.flip, 0, "orientation is baked; flip must be 0")
    }

    func testCorruptFileThrows() {
        let url = fixtureDir.appendingPathComponent("broken.jpg")
        try? Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00]).write(to: url)
        XCTAssertThrowsError(try ImageIODecoder().decodeRaw(at: url))
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try ImageIODecoder().decodeRaw(at: fixtureDir.appendingPathComponent("nope.jpg")))
    }
}

@MainActor
final class RoutingDecoderTests: XCTestCase {
    private final class RecordingDecoder: RawDecoding, @unchecked Sendable {
        private let lock = NSLock()
        private var called: [String] = []
        let fail: Bool

        init(fail: Bool = false) { self.fail = fail }

        func decodeRaw(at url: URL) throws -> RawBitmap {
            lock.lock(); defer { lock.unlock() }
            called.append(url.pathExtension.lowercased())
            if fail {
                throw DecodeError.cannotOpen("stub failure")
            }
            let width = 8, height = 4
            var bytes = [UInt8](repeating: 50, count: width * height * 3)
            let data = Data(bytes)
            let provider = CGDataProvider(data: data as CFData)!
            let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                bitsPerPixel: 24, bytesPerRow: width * 3,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent)!
            return RawBitmap(image: image, width: width, height: height, flip: 0)
        }

        func calledExtensions() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return called
        }
    }

    func testRoutesByDecoderKind() throws {
        let libraw = RecordingDecoder()
        let imageIO = RecordingDecoder()
        let router = RoutingDecoder(librawDecoder: libraw, imageIODecoder: imageIO)

        _ = try router.decodeRaw(at: URL(fileURLWithPath: "/tmp/a.cr2"))
        _ = try router.decodeRaw(at: URL(fileURLWithPath: "/tmp/b.nef"))
        _ = try router.decodeRaw(at: URL(fileURLWithPath: "/tmp/c.jpg"))
        _ = try router.decodeRaw(at: URL(fileURLWithPath: "/tmp/d.heic"))

        XCTAssertEqual(libraw.calledExtensions(), ["cr2", "nef"])
        XCTAssertEqual(imageIO.calledExtensions(), ["jpg", "heic"])
    }

    func testUnsupportedExtensionThrows() {
        let router = RoutingDecoder(librawDecoder: RecordingDecoder(),
                                    imageIODecoder: RecordingDecoder())
        XCTAssertThrowsError(try router.decodeRaw(at: URL(fileURLWithPath: "/tmp/a.txt")))
    }
}
