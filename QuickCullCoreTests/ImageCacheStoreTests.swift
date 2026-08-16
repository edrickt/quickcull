import CoreGraphics
import ImageIO
import XCTest
@testable import QuickCullCore

final class ImageCacheStoreTests: XCTestCase {
    private var base: URL!
    private var store: ImageCacheStore!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = ImageCacheStore(baseURL: base)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeFile(_ name: String, size: Int = 100) throws -> SessionFile {
        let url = base.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: size).write(to: url)
        return SessionFile(url: url)
    }

    private func makeBitmap() -> RawBitmap {
        let width = 32, height = 16
        var bytes = [UInt8](repeating: 128, count: width * height * 3)
        for i in 0..<width * height { bytes[i * 3] = UInt8(i % 256) }
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

    func testWipeRecreatesEmptyDirectory() async throws {
        let file = try makeFile("x.cr2")
        _ = try await store.storeJPEG(makeBitmap(), for: file)
        try await store.wipe()
        let contents = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertTrue(contents.isEmpty)
    }

    func testCacheKeyIsStableForUnchangedFile() async throws {
        let file = try makeFile("a.cr2")
        let key1 = try await store.cacheURL(for: file)
        let key2 = try await store.cacheURL(for: file)
        XCTAssertEqual(key1, key2)
    }

    func testCacheKeyChangesWhenMtimeChanges() async throws {
        let file = try makeFile("a.cr2")
        let key1 = try await store.cacheURL(for: file)
        // touch the file: mtime changes
        try Data([0x01]).write(to: file.url)
        let key2 = try await store.cacheURL(for: file)
        XCTAssertNotEqual(key1, key2)
    }

    func testStoreJPEGWritesDecodableJPEGAtQ75() async throws {
        let file = try makeFile("a.cr2")
        let destination = try await store.storeJPEG(makeBitmap(), for: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        guard let source = CGImageSourceCreateWithURL(destination as CFURL, nil) else {
            return XCTFail("not a decodable image")
        }
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 32)
        XCTAssertEqual(props?[kCGImagePropertyPixelHeight] as? Int, 16)
    }

    func testStoreJPEGWritesNoOrientationTag() async throws {
        let file = try makeFile("a.cr2")
        var bitmap = makeBitmap()
        bitmap = RawBitmap(image: bitmap.image, width: bitmap.width,
                           height: bitmap.height, flip: 5)
        let destination = try await store.storeJPEG(bitmap, for: file)
        guard let source = CGImageSourceCreateWithURL(destination as CFURL, nil) else {
            return XCTFail("not a decodable image")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        // Pixels are already upright; an orientation tag would cause
        // consumers using kCGImageSourceCreateThumbnailWithTransform to
        // rotate the already-upright bitmap a second time.
        XCTAssertNil(props?[kCGImagePropertyOrientation])
    }

    func testStoreJPEGLeavesNoTmpFiles() async throws {
        let file = try makeFile("a.cr2")
        _ = try await store.storeJPEG(makeBitmap(), for: file)
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })
    }

    func testDeleteCachedJPEGRemovesFile() async throws {
        let file = try makeFile("a.cr2")
        let destination = try await store.storeJPEG(makeBitmap(), for: file)
        await store.deleteCachedJPEG(for: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
