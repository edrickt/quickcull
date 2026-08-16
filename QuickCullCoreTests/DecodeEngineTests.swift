import CoreGraphics
import XCTest
@testable import QuickCullCore

final class DecodeEngineTests: XCTestCase {
    private func makeTempCache() async throws -> (ImageCacheStore, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (ImageCacheStore(baseURL: base), base)
    }

    private func makeFiles(_ names: [String]) -> [SessionFile] {
        names.map { SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/\($0)")) }
    }

    private func collect(_ stream: AsyncStream<DecodeEngine.Event>) async -> [DecodeEngine.Event] {
        var events: [DecodeEngine.Event] = []
        for await event in stream { events.append(event) }
        return events
    }

    func testDecodesEveryFileExactlyOnce() async throws {
        let files = makeFiles((0..<20).map { "img_\($0).cr2" })
        let decoder = StubDecoder()
        let (cache, base) = try await makeTempCache()
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
        let files = makeFiles(["ok.cr2", "bad.cr2", "also_ok.cr2"])
        let decoder = StubDecoder(failIDs: ["/tmp/shoot/bad.cr2"])
        let (cache, base) = try await makeTempCache()
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
        let files = makeFiles((0..<16).map { "img_\($0).nef" })
        let (cache, base) = try await makeTempCache()
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
        let files = makeFiles(["a.cr2", "b.cr2"])
        let (cache, base) = try await makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: StubDecoder(), cache: cache)

        _ = await collect(engine.decodeAll(files: files))
        let contents = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(contents.count, 2)
        XCTAssertTrue(contents.allSatisfy { $0.hasSuffix(".jpg") })
    }

    func testWorkerCountFormula() {
        let gb = UInt64(1024 * 1024 * 1024)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 8 * gb, limit: nil), 4)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 16, physicalMemoryBytes: 16 * gb, limit: nil), 8)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 32, physicalMemoryBytes: 32 * gb, limit: nil), 16)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 2, physicalMemoryBytes: 8 * gb, limit: nil), 2)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 8 * gb, limit: 2), 2)
        XCTAssertEqual(DecodeEngine.workerCount(activeProcessors: 8, physicalMemoryBytes: 8 * gb, limit: 0), 1)
    }

    func testCancellationStopsWorkers() async throws {
        let files = makeFiles((0..<20).map { "img_\($0).cr2" })
        let decoder = SlowStubDecoder(delay: 50_000_000)   // 50 ms per decode
        let (cache, base) = try await makeTempCache()
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
        // Workers stop early: far fewer than 20 files decoded.
        XCTAssertLessThan(decoder.callCount(), 20, "cancellation must stop the worker pool")
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

        let (cache, base) = try await makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: LibRawDecoder(), cache: cache)

        let events = await collect(engine.decodeAll(files: rawURLs.map(SessionFile.init)))
        guard case .completed(let outcomes) = events.last else {
            return XCTFail("expected completed event")
        }
        XCTAssertTrue(outcomes.allSatisfy { $0.error == nil },
                      "all fixture files must decode: \(outcomes)")
        let contents = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(contents.count, 8)
    }
}
