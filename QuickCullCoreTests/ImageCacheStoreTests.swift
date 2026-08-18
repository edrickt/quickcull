import CoreGraphics
import ImageIO
import XCTest
@testable import QuickCullCore

final class ImageCacheStoreTests: XCTestCase {
    private var base: URL!
    private var store: ImageCacheStore!

    override func setUp() async throws {
        base = try TestFixtures.makeTempDir(name: "tests")
        store = ImageCacheStore(baseURL: base)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testWipeRecreatesEmptyDirectory() async throws {
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "x.cr2", in: base))
        _ = try await store.storeJPEG(RawBitmap(image: TestFixtures.makeCGImage(width: 32, height: 16, color: 128),
            width: 32, height: 16, flip: 0), for: file)
        try await store.wipe()
        let contents = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertTrue(contents.isEmpty)
    }

    func testCacheKeyIsStableForUnchangedFile() async throws {
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "a.cr2", in: base))
        let key1 = try await store.cacheURL(for: file)
        let key2 = try await store.cacheURL(for: file)
        XCTAssertEqual(key1, key2)
    }

    func testCacheKeyChangesWhenMtimeChanges() async throws {
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "a.cr2", in: base))
        let key1 = try await store.cacheURL(for: file)
        // touch the file: mtime changes
        try Data([0x01]).write(to: file.url)
        let key2 = try await store.cacheURL(for: file)
        XCTAssertNotEqual(key1, key2)
    }

    func testStoreJPEGWritesDecodableJPEGAtQ75() async throws {
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "a.cr2", in: base))
        let destination = try await store.storeJPEG(RawBitmap(image: TestFixtures.makeCGImage(width: 32, height: 16, color: 128),
            width: 32, height: 16, flip: 0), for: file)
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
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "a.cr2", in: base))
        var bitmap = RawBitmap(image: TestFixtures.makeCGImage(width: 32, height: 16, color: 128),
            width: 32, height: 16, flip: 0)
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
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "a.cr2", in: base))
        _ = try await store.storeJPEG(RawBitmap(image: TestFixtures.makeCGImage(width: 32, height: 16, color: 128),
            width: 32, height: 16, flip: 0), for: file)
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })
    }

    func testDeleteCachedJPEGRemovesFile() async throws {
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "a.cr2", in: base))
        let destination = try await store.storeJPEG(RawBitmap(image: TestFixtures.makeCGImage(width: 32, height: 16, color: 128),
            width: 32, height: 16, flip: 0), for: file)
        await store.deleteCachedJPEG(for: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testStoreJPEGReplacesExistingEntryAtomically() async throws {
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "a.cr2", in: base))
        let first = try await store.storeJPEG(RawBitmap(image: TestFixtures.makeCGImage(width: 32, height: 16, color: 128),
            width: 32, height: 16, flip: 0), for: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        // Overwrite; the entry must still exist and stay decodable.
        let second = try await store.storeJPEG(RawBitmap(image: TestFixtures.makeCGImage(width: 32, height: 16, color: 128),
            width: 32, height: 16, flip: 0), for: file)
        XCTAssertEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        guard let source = CGImageSourceCreateWithURL(second as CFURL, nil) else {
            return XCTFail("replaced entry not decodable")
        }
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })
    }

    func testStoreAndLoadHistogramRoundTrip() async throws {
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "a.cr2", in: base))
        let hist = RawHistogram(bins: [[0, 1, 2], [3, 4, 5], [6, 7, 8]], sensorMax: 16383)
        try await store.storeHistogram(hist, for: file)
        let loaded = try await store.loadHistogram(for: file)
        XCTAssertEqual(loaded, hist)
    }

    func testStoreAndLoadHistogramWithLuminance() async throws {
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "e.cr2", in: base))
        var lum = [Int](repeating: 0, count: RawHistogram.binCount); lum[5]=42; lum[200]=7
        let hist = RawHistogram(bins: [[0,1,2],[3,4,5],[6,7,8]], luminance: lum, sensorMax: 16383)
        try await store.storeHistogram(hist, for: file)
        let loaded = try await store.loadHistogram(for: file)
        XCTAssertEqual(loaded, hist)
    }

    func testLoadHistogramMissingReturnsNil() async throws {
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "b.cr2", in: base))
        let loaded = try await store.loadHistogram(for: file)
        XCTAssertNil(loaded)
    }

    func testLoadHistogramCorruptReturnsNil() async throws {
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "c.cr2", in: base))
        let url = try await store.histogramURL(for: file)
        try Data("not json".utf8).write(to: url)
        let loaded = try await store.loadHistogram(for: file)
        XCTAssertNil(loaded)
    }

    func testHistogramURLSharesCacheKey() async throws {
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "d.cr2", in: base))
        let jpg = try await store.cacheURL(for: file)
        let hist = try await store.histogramURL(for: file)
        XCTAssertEqual(hist.deletingPathExtension().deletingPathExtension().lastPathComponent,
                       jpg.lastPathComponent)
        XCTAssertTrue(hist.lastPathComponent.hasSuffix(".hist.json"))
    }
}
