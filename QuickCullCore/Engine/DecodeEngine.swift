import Foundation
import os

extension OSLog {
    static let decode = OSLog(subsystem: "com.quickcull", category: "decode")
}

public struct DecodeOutcome: Equatable {
    public let file: SessionFile
    public let error: DecodeError?

    public init(file: SessionFile, error: DecodeError?) {
        self.file = file
        self.error = error
    }
}

/// Phase 1: decode every file to a cached full-res q75 JPEG in parallel,
/// bounded by the memory-aware worker rule (one worker per 1 GB of RAM,
/// capped by core count). Emits strictly monotonic progress events, then
/// exactly one completed event with per-file outcomes.
public actor DecodeEngine {
    public enum Event {
        case progress(completed: Int, total: Int)
        case completed([DecodeOutcome])
    }

    public struct Benchmark: Sendable { public let fileID: String; public let totalMs: Double; public let width, height: Int }
    private let benchmarkAccum = AtomicBenchmarkAccum()

    private let decoder: RawDecoding
    private let cache: ImageCacheStore
    private let workerCount: Int

    public init(decoder: RawDecoding, cache: ImageCacheStore, workerLimit: Int? = nil) {
        self.decoder = decoder
        self.cache = cache
        self.workerCount = Self.workerCount(
            activeProcessors: ProcessInfo.processInfo.activeProcessorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            limit: workerLimit)
    }

    public func benchmarks() -> [Benchmark] {
        benchmarkAccum.snapshot()
    }

    /// Memory-bounded worker rule: one worker per 1 GB of physical RAM
    /// (LibRaw unpack + demosaic + mem image + JPEG encode for a 45 MP raw
    /// needs ≈512 MB transient per worker), capped by core count; explicit
    /// limits are floor-1.
    public static func workerCount(activeProcessors: Int,
                                   physicalMemoryBytes: UInt64,
                                   limit: Int?) -> Int {
        if let limit { return max(1, limit) }
        let byMemory = max(1, Int(physicalMemoryBytes / (1 * 1024 * 1024 * 1024)))
        var count = min(max(1, activeProcessors), byMemory)
        // Memory-pressure guard: if <1 GiB free, shed one worker
        #if canImport(Darwin)
        if let free = Self.availableMemoryBytes(), free < 1 * 1024 * 1024 * 1024 {
            count = max(1, count - 1)
        }
        #endif
        return max(1, count)
    }
    private static func availableMemoryBytes() -> UInt64? {
        // use host_statistics64 or os_proc_available_memory fallback; return nil if unavailable
        return nil // stub — implement with vm_statistics if needed, else nil keeps prior behavior
    }

    public func decodeAll(files: [SessionFile]) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                let queue = JobQueue<SessionFile>()
                for file in files { await queue.enqueue(file) }

                let total = files.count
                let reporter = ProgressReporter(total: total, continuation: continuation)
                let outcomes = AtomicOutcomeAccumulator()

                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<workerCount {
                        group.addTask {
                            while let file = await queue.dequeue() {
                                if Task.isCancelled { break }
                                let signpostID = OSSignpostID(log: OSLog.decode)
                                os_signpost(.begin, log: OSLog.decode, name: "decode", signpostID: signpostID, "file=%{public}s", file.id)
                                let t0 = CFAbsoluteTimeGetCurrent()
                                let outcome: DecodeOutcome
                                var benchWidth = 0
                                var benchHeight = 0
                                do {
                                    let bitmap = try self.decoder.decodeRaw(at: file.url)
                                    benchWidth = bitmap.width
                                    benchHeight = bitmap.height
                                    try await self.cache.storeJPEG(bitmap, for: file)
                                    // Histogram sidecar is best-effort: its failure
                                    // must never fail the import.
                                    if let hist = bitmap.histogram {
                                        try? await self.cache.storeHistogram(hist, for: file)
                                    }
                                    outcome = DecodeOutcome(file: file, error: nil)
                                } catch let error as DecodeError {
                                    outcome = DecodeOutcome(file: file, error: error)
                                } catch {
                                    outcome = DecodeOutcome(file: file,
                                                            error: .cannotProcess("\(error)"))
                                }
                                let totalMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                                self.benchmarkAccum.append(Benchmark(fileID: file.id, totalMs: totalMs, width: benchWidth, height: benchHeight))
                                os_signpost(.end, log: OSLog.decode, name: "decode", signpostID: signpostID, "file=%{public}s totalMs=%{public}f", file.id, totalMs)
                                outcomes.append(outcome)
                                await reporter.reportProgress()
                            }
                        }
                    }
                }
                continuation.yield(.completed(outcomes.snapshot()))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// FIFO work queue shared by the worker pool.
actor JobQueue<Element> {
    private var items: [Element] = []

    func enqueue(_ item: Element) {
        items.append(item)
    }

    func dequeue() -> Element? {
        items.isEmpty ? nil : items.removeFirst()
    }
}

/// Serializes progress delivery: increments and yields inside one actor
/// isolation, so there is no preemption window between the two. Delivered
/// `completed:` values are strictly monotonic by construction, not by
/// scheduling accident.
actor ProgressReporter {
    private let continuation: AsyncStream<DecodeEngine.Event>.Continuation
    private let total: Int
    private var completed = 0

    init(total: Int, continuation: AsyncStream<DecodeEngine.Event>.Continuation) {
        self.total = total
        self.continuation = continuation
    }

    func reportProgress() {
        completed += 1
        continuation.yield(.progress(completed: completed, total: total))
    }
}

final class AtomicOutcomeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DecodeOutcome] = []

    func append(_ outcome: DecodeOutcome) {
        lock.lock(); defer { lock.unlock() }
        items.append(outcome)
    }

    func snapshot() -> [DecodeOutcome] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

final class AtomicBenchmarkAccum: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DecodeEngine.Benchmark] = []

    func append(_ b: DecodeEngine.Benchmark) {
        lock.lock(); defer { lock.unlock() }
        items.append(b)
    }

    func snapshot() -> [DecodeEngine.Benchmark] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}
