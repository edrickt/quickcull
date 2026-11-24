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
        // Change only the mtime: rewriting the contents also changed the size,
        // which made the test pass even with mtime dropped from the key.
        let sameSize = try Data(contentsOf: file.url)
        try sameSize.write(to: file.url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: file.url.path)
        let key2 = try await store.cacheURL(for: file)
        XCTAssertNotEqual(key1, key2)
    }

    /// QC-01: the key embeds the source's size and mtime, and every read
    /// recomputes it. When the source leaves the volume (card ejected, file
    /// moved or deleted) a live stat fails; falling back to the path alone
    /// created a second key that could never name the preview written while
    /// the file existed. The key captured at import must be the fallback.
    func testCacheKeyIsStableWhenTheSourceDisappears() async throws {
        let source = try TestFixtures.makeRawFile(named: "ejected.cr2", in: base)
        let file = SessionFile(url: source)
        let stored = try await store.storeJPEG(
            RawBitmap(image: TestFixtures.makeCGImage(width: 32, height: 16, color: 128),
                      width: 32, height: 16, flip: 0), for: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))

        // The card leaves the reader; the preview stays on disk.
        try FileManager.default.removeItem(at: source)

        let afterEject = try await store.cacheURL(for: file)
        XCTAssertEqual(afterEject, stored,
                       "a missing source must not change the cache key")
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterEject.path),
                      "the stored preview must still be reachable")
    }

    /// QC-01 edge: the fallback must name the preview that was last written,
    /// not the one the import started with. A file whose mtime changes while
    /// the session runs gets a new key; if it is removed afterwards, falling
    /// back to the import-time signature would split read from write again.
    func testCacheKeyAfterRemovalFallsBackToTheLastObservedStat() async throws {
        let source = try TestFixtures.makeRawFile(named: "changed.cr2", in: base)
        let file = SessionFile(url: source)
        _ = try await store.cacheURL(for: file)

        // Same size, newer mtime: the live key changes (as it must).
        let sameSize = try Data(contentsOf: source)
        try sameSize.write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(300)], ofItemAtPath: source.path)
        let whilePresent = try await store.cacheURL(for: file)
        let stored = try await store.storeJPEG(
            RawBitmap(image: TestFixtures.makeCGImage(width: 32, height: 16, color: 128),
                      width: 32, height: 16, flip: 0), for: file)
        XCTAssertEqual(stored, whilePresent)

        try FileManager.default.removeItem(at: source)
        let afterRemoval = try await store.cacheURL(for: file)
        XCTAssertEqual(afterRemoval, whilePresent,
                       "the fallback must be the last stat the file was keyed under")
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterRemoval.path))
    }

    /// QS-04: identity is the resolved target, so the cache key's stat must be
    /// the target's too — a symlink's own size and mtime describe the link, not
    /// the photo. Both the write and the fallback must name the same key when
    /// the link (and the card) are gone.
    func testCacheKeyForASymlinkedPhotoUsesTheTarget() async throws {
        let card = try TestFixtures.makeTempDir(name: "symlink-card")
        let picks = try TestFixtures.makeTempDir(name: "symlink-picks")
        defer { try? FileManager.default.removeItem(at: card)
                try? FileManager.default.removeItem(at: picks) }
        let target = try TestFixtures.makeRawFile(named: "IMG_0001.CR2", in: card)
        let link = picks.appendingPathComponent("IMG_0001.CR2")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let file = SessionFile(url: link)

        let stored = try await store.storeJPEG(
            RawBitmap(image: TestFixtures.makeCGImage(width: 32, height: 16, color: 128),
                      width: 32, height: 16, flip: 0), for: file)
        // The picks folder and the card both leave.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.removeItem(at: target)

        let after = try await store.cacheURL(for: file)
        XCTAssertEqual(after, stored, "the link's own stat is not the photo's cache key")
        XCTAssertTrue(FileManager.default.fileExists(atPath: after.path))
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
        let hist = TestFixtures.makeFullHistogram()
        try await store.storeHistogram(hist, beside: try await store.cacheURL(for: file))
        let loaded = try await store.loadHistogram(for: file)
        XCTAssertEqual(loaded, hist)
    }

    func testStoreAndLoadHistogramWithLuminance() async throws {
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "e.cr2", in: base))
        var lum = [Int](repeating: 0, count: RawHistogram.binCount); lum[5]=42; lum[200]=7
        let hist = TestFixtures.makeFullHistogram(luminance: lum)
        try await store.storeHistogram(hist, beside: try await store.cacheURL(for: file))
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
        let notJSON = try await store.loadHistogram(for: file)
        XCTAssertNil(notJSON)

        // Valid JSON, wrong shape (2 channels of 2 bins): decoding must fail
        // instead of handing the views a histogram they would subscript out of
        // range. Regression for a crash on a truncated or hand-edited sidecar.
        let wrongShape = #"{"bins":[[1,2],[3,4]],"sensorMax":255}"#
        try Data(wrongShape.utf8).write(to: url)
        let shapeMismatch = try await store.loadHistogram(for: file)
        XCTAssertNil(shapeMismatch)
    }

    func testHistogramURLSharesCacheKey() async throws {
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "d.cr2", in: base))
        let jpg = try await store.cacheURL(for: file)
        let hist = try await store.histogramURL(for: file)
        XCTAssertEqual(hist.deletingPathExtension().deletingPathExtension().lastPathComponent,
                       jpg.lastPathComponent)
        XCTAssertTrue(hist.lastPathComponent.hasSuffix(".hist.json"))
    }

    func testStoreJPEGWithQualityProducesDecodableAndClamped() async throws {
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "q.cr2", in: base))
        // A flat colour compresses to nearly the same bytes at any quality, so
        // the fixture must carry detail for the quality to be observable (the
        // old assertion only checked that a file appeared, which an ignored
        // quality argument also satisfied).
        let bmp = RawBitmap(image: Self.noiseImage(width: 48, height: 32), width: 48, height: 32, flip: 0)

        let dest70 = try await store.storeJPEG(bmp, for: file, quality: 0.70)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest70.path))
        let size70 = try Data(contentsOf: dest70).count

        let dest95 = try await store.storeJPEG(bmp, for: file, quality: 0.95)
        let size95 = try Data(contentsOf: dest95).count
        XCTAssertLessThan(size70, size95, "lower quality must produce a smaller JPEG")

        // Out-of-range clamped, not thrown: 2.0 encodes exactly like 0.95.
        let destClamped = try await store.storeJPEG(bmp, for: file, quality: 2.0)
        XCTAssertEqual(try Data(contentsOf: destClamped).count, size95, "quality is clamped to 0.95")
    }

    private static func noiseImage(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 3)
        var seed: UInt32 = 1_234_567
        for index in 0..<bytes.count {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8((seed >> 16) & 0xFF)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                       bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    /// A sidecar written by a session that was wiped mid-write must not land in
    /// the fresh cache (AUD-31 closed this for the JPEG; the histogram is the
    /// same boundary and is written right after it).
    func testHistogramBegunBeforeAWipeDoesNotLand() async throws {
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "h.cr2", in: base))
        let jpeg = try await store.cacheURL(for: file)
        let generation = await store.currentStoreGeneration()
        try await store.wipe()
        do {
            try await store.storeHistogram(TestFixtures.makeFullHistogram(),
                                           beside: jpeg, assuming: generation)
            XCTFail("a sidecar from before the wipe must be rejected")
        } catch CacheError.staleGeneration {
            // expected
        }
        let afterWipe = try await store.loadHistogram(for: file)
        XCTAssertNil(afterWipe)
    }

    /// Two stores of the same identity used to share one `.tmp` path, truncating
    /// each other's encode and failing the loser with ENOENT.
    func testConcurrentStoresOfTheSameFileAllSucceed() async throws {
        let file = SessionFile(url: try TestFixtures.makeRawFile(named: "c.cr2", in: base))
        let bitmap = RawBitmap(image: Self.noiseImage(width: 48, height: 32), width: 48, height: 32, flip: 0)
        let dest = try await store.cacheURL(for: file)

        let cache = store!
        for _ in 0..<5 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<4 {
                    group.addTask { _ = try await cache.storeJPEG(bitmap, for: file, quality: 0.75) }
                }
                try await group.waitForAll()
            }
        }
        guard let source = CGImageSourceCreateWithURL(dest as CFURL, nil) else {
            return XCTFail("the surviving entry must be a decodable JPEG")
        }
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
    }

    /// New Session cancels the import and wipes fire-and-forget, so a decode
    /// already past its cancellation check can still be holding a bitmap. Its
    /// write must not land in the fresh cache.
    func testWriteStartedBeforeAWipeDoesNotLandInTheFreshCache() async throws {
        let file = SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/stale.cr2"))
        let bitmap = RawBitmap(image: TestFixtures.makeCGImage(width: 8, height: 8, color: 3),
                               width: 8, height: 8, flip: 0)
        let generation = await store.currentStoreGeneration()
        try await store.wipe()
        do {
            _ = try await store.storeJPEG(bitmap, for: file, quality: 0.75, assuming: generation)
            XCTFail("a write started before the wipe must not land")
        } catch CacheError.staleGeneration {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: (try store.cacheURL(for: file)).path))
    }
}
