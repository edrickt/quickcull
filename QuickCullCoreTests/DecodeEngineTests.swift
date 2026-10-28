import CoreGraphics
import XCTest
@testable import QuickCullCore

final class DecodeEngineTests: XCTestCase {
    private func collect(_ stream: AsyncStream<DecodeEngine.Event>) async -> [DecodeEngine.Event] {
        var events: [DecodeEngine.Event] = []
        for await event in stream { events.append(event) }
        return events
    }

    func testDecodesEveryFileExactlyOnce() async throws {
        let files = TestFixtures.makeFiles((0..<20).map { "img_\($0).cr2" })
        let decoder = StubDecoder()
        let (cache, base) = try await TestFixtures.makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: decoder, cache: cache)

        let events = await collect(engine.decodeAll(files: files))
        XCTAssertEqual(decoder.callCount(), 20)

        guard case .completed(let outcomes) = events.last else {
            return XCTFail("expected completed event")
        }
        XCTAssertEqual(outcomes.count, 20)
        XCTAssertTrue(outcomes.allSatisfy { $0.error == nil })
    }

    func testFailuresAreCollectedNotFatal() async throws {
        let files = TestFixtures.makeFiles(["ok.cr2", "bad.cr2", "also_ok.cr2"])
        let decoder = StubDecoder(failIDs: ["/tmp/shoot/bad.cr2"])
        let (cache, base) = try await TestFixtures.makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: decoder, cache: cache)

        let events = await collect(engine.decodeAll(files: files))
        guard case .completed(let outcomes) = events.last else {
            return XCTFail("expected completed event")
        }
        let failures = outcomes.filter { $0.error != nil }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.file.id, "/tmp/shoot/bad.cr2")
        XCTAssertEqual(failures.first?.error, .cannotUnpack("stub failure"))
    }

    func testProgressReachesTotalAndIsMonotonic() async throws {
        let files = TestFixtures.makeFiles((0..<16).map { "img_\($0).nef" })
        let (cache, base) = try await TestFixtures.makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: StubDecoder(), cache: cache)

        let events = await collect(engine.decodeAll(files: files))
        let progressEvents = events.compactMap { event -> Int? in
            if case .progress(let completed, let total) = event {
                XCTAssertEqual(total, 16)
                return completed
            }
            return nil
        }
        XCTAssertEqual(progressEvents.last, 16)
        var previous = 0
        for p in progressEvents {
            XCTAssertGreaterThan(p, previous)
            previous = p
        }
    }

    func testDecodedJPEGsAreWrittenToCache() async throws {
        let files = TestFixtures.makeFiles(["a.cr2", "b.cr2"])
        let (cache, base) = try await TestFixtures.makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: StubDecoder(), cache: cache)

        _ = await collect(engine.decodeAll(files: files))
        let contents = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(contents.count, 2)
        XCTAssertTrue(contents.allSatisfy { $0.hasSuffix(".jpg") })
    }

    func testWorkerCountFormula() {
        let gb = UInt64(1024 * 1024 * 1024)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 8 * gb, limit: nil), 8)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 16, physicalMemoryBytes: 16 * gb, limit: nil), 16)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 32, physicalMemoryBytes: 32 * gb, limit: nil), 32)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 2, physicalMemoryBytes: 8 * gb, limit: nil), 2)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 8 * gb, limit: 2), 2)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 8 * gb, limit: 0), 1)
        // Load-bearing floor: a <2 GB machine must still get at least one
        // worker, or decodeAll would emit `.completed([])` (fake success).
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 1 * gb, limit: nil), 1)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 512 * 1024 * 1024, limit: nil), 1)
    }

    func testWorkerCountRetunedFormula() {
        let gb = UInt64(1024 * 1024 * 1024)
        // Spec: min(cores, max(1, mem / 1 GiB)) with pressure guard inactive
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 8 * gb, limit: nil), 8) // was 4
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 10, physicalMemoryBytes: 16 * gb, limit: nil), 10) // was 8
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 4 * gb, limit: nil), 4) // was 2
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 4, physicalMemoryBytes: 4 * gb, limit: nil), 4)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 32, physicalMemoryBytes: 32 * gb, limit: nil), 32)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 2, physicalMemoryBytes: 8 * gb, limit: nil), 2)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 8 * gb, limit: 2), 2)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 1 * gb, limit: nil), 1)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 512 * 1024 * 1024, limit: nil), 1)
    }

    func testCancellationStopsWorkers() async throws {
        let files = TestFixtures.makeFiles((0..<20).map { "img_\($0).cr2" })
        let decoder = SlowStubDecoder(delay: 50_000_000)   // 50 ms per decode
        let (cache, base) = try await TestFixtures.makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: decoder, cache: cache, workerLimit: 2)

        let consumer = Task {
            var events: [DecodeEngine.Event] = []
            for await event in await engine.decodeAll(files: files) { events.append(event) }
            return events
        }
        // Let a couple of files decode, then cancel the consumer.
        try? await Task.sleep(nanoseconds: 150_000_000)
        consumer.cancel()
        _ = await consumer.value
        // Let in-flight decodes (≤ workerLimit × delay) settle, then sample
        // twice: the first sample sanity-checks early stopping, the second
        // proves the pool is truly stopped (a removed cancel check would let
        // the count keep growing here).
        try? await Task.sleep(nanoseconds: 300_000_000)
        let settled = decoder.callCount()
        XCTAssertLessThan(settled, 20, "cancellation must stop the worker pool")
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(decoder.callCount(), settled,
                       "cancellation must stop the worker pool")
    }

    func testRealDecoderIntegrationWithFixtures() async throws {
        // Uses the real LibRawDecoder on the small 8-file fixture set.
        let bundle = Bundle(for: Self.self)
        let rawURLs = try FileManager.default
            .contentsOfDirectory(at: bundle.resourceURL!
                .appendingPathComponent("Fixtures/raws", isDirectory: true),
                includingPropertiesForKeys: nil)
            .filter { RawFileIdentity.isSupported($0) && !$0.lastPathComponent.hasPrefix("bad_") }
        XCTAssertEqual(rawURLs.count, 8)

        let (cache, base) = try await TestFixtures.makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: LibRawDecoder(), cache: cache)

        let events = await collect(engine.decodeAll(files: rawURLs.map(SessionFile.init)))
        guard case .completed(let outcomes) = events.last else {
            return XCTFail("expected completed event")
        }
        XCTAssertTrue(outcomes.allSatisfy { $0.error == nil },
                      "all fixture files must decode: \(outcomes)")
        let contents = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(contents.filter { $0.hasSuffix(".jpg") }.count, 8)
        // FastRawViewer RAW: 7 Bayer fixtures produce a raw histogram; fuji_e550 (super-CCD/X-Trans) returns nil
        XCTAssertEqual(contents.filter { $0.hasSuffix(".hist.json") }.count, 7)
    }

    func testHistogramSidecarWrittenWhenBitmapHasHistogram() async throws {
        let files = TestFixtures.makeFiles(["a.cr2", "b.cr2"])
        let hist = TestFixtures.makeFullHistogram(sensorMax: 255)
        let (cache, base) = try await TestFixtures.makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: StubDecoder(histogram: hist), cache: cache)

        _ = await collect(engine.decodeAll(files: files))
        // 2 JPEGs + 2 sidecars
        let contents = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(contents.filter { $0.hasSuffix(".jpg") }.count, 2)
        XCTAssertEqual(contents.filter { $0.hasSuffix(".hist.json") }.count, 2)
        for file in files {
            let loaded = try await cache.loadHistogram(for: file)
            XCTAssertEqual(loaded, hist)
        }
    }

    func testNoHistogramSidecarWhenBitmapHasNone() async throws {
        let files = TestFixtures.makeFiles(["a.cr2", "b.cr2"])
        let (cache, base) = try await TestFixtures.makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: StubDecoder(), cache: cache)

        _ = await collect(engine.decodeAll(files: files))
        let contents = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(contents.count, 2)
        XCTAssertTrue(contents.allSatisfy { $0.hasSuffix(".jpg") })
    }

    func testDecodeOptionsV1IsDefaultAndSourceCompatible() throws {
        let bundleURL = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        let canonURL = bundleURL.appendingPathComponent("Fixtures/raws/canon_eos6d.cr2")
        let url: URL
        if FileManager.default.fileExists(atPath: canonURL.path) {
            url = canonURL
        } else {
            url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "img_0062", withExtension: "cr2", subdirectory: "Fixtures/raws"))
        }
        let decoder = LibRawDecoder()
        let a = try decoder.decodeRaw(at: url) // old signature
        let b = try decoder.decodeRaw(at: url, options: .v1) // new signature
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
    }

    /// A decoder that finishes the first file last, so completion order differs
    /// from input order.
    private final class ReversedLatencyDecoder: RawDecoding, @unchecked Sendable {
        func decodeRaw(at url: URL, options: DecodeOptions) throws -> RawBitmap {
            if url.lastPathComponent.hasPrefix("a") {
                let semaphore = DispatchSemaphore(value: 0)
                Task { try? await Task.sleep(nanoseconds: 150_000_000); semaphore.signal() }
                semaphore.wait()
            }
            let width = 4, height = 2
            let provider = CGDataProvider(data: Data(repeating: 9, count: width * height * 3) as CFData)!
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                                bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent)!
            return RawBitmap(image: image, width: width, height: height, flip: 0)
        }
    }

    /// The failure banner names the first three failures, so the same import must
    /// report them in the same order every time; outcomes used to arrive in
    /// completion order.
    func testOutcomesAreReportedInImportOrder() async throws {
        let files = TestFixtures.makeFiles(["a.cr2", "b.cr2", "c.cr2", "d.cr2"])
        let (cache, base) = try await TestFixtures.makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: ReversedLatencyDecoder(), cache: cache, workerLimit: 4)

        let events = await collect(engine.decodeAll(files: files))
        guard case .completed(let outcomes) = events.last else {
            return XCTFail("expected completed event")
        }
        XCTAssertEqual(outcomes.map { $0.file.url.lastPathComponent },
                       ["a.cr2", "b.cr2", "c.cr2", "d.cr2"])
    }
}
