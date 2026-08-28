import Foundation
import os
#if canImport(Darwin)
import Darwin
#endif

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

    public struct Benchmark: Sendable {
        public let fileID: String
        public let totalMs: Double
        public let width: Int
        public let height: Int
        public init(fileID: String, totalMs: Double, width: Int, height: Int) {
            self.fileID = fileID; self.totalMs = totalMs; self.width = width; self.height = height
        }
    }
    private let benchmarkAccum = LockedAccumulator<Benchmark>()

    private let decoder: RawDecoding
    private let cache: ImageCacheStore
    private let workerCount: Int
    private let options: DecodeOptions

    public init(decoder: RawDecoding, cache: ImageCacheStore, workerLimit: Int? = nil, options: DecodeOptions = .v1) {
        self.decoder = decoder
        self.cache = cache
        self.options = options
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
#if canImport(Darwin)
        var stat = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &stat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        // free + inactive is a reasonable proxy for reclaimable memory
        return UInt64(stat.free_count) * pageSize + UInt64(stat.inactive_count) * pageSize
#else
        return nil
#endif
    }

    public func decodeAll(files: [SessionFile]) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                let queue = JobQueue<SessionFile>()
                for file in files { await queue.enqueue(file) }

                let total = files.count
                let reporter = ProgressReporter(total: total, continuation: continuation)
                let outcomes = LockedAccumulator<DecodeOutcome>()

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
                                    let bitmap = try self.decoder.decodeRaw(at: file.url, options: self.options)
                                    benchWidth = bitmap.width
                                    benchHeight = bitmap.height
                                    try await self.cache.storeJPEG(bitmap, for: file, quality: self.options.jpegQuality)
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

/// FIFO work queue shared by the worker pool. Two-stack layout: enqueue
/// appends to `incoming`, dequeue drains it into `reversed` once and pops
/// from there — amortized O(1) per operation (unlike `removeFirst`, which
/// shifts the whole array per dequeue).
actor JobQueue<Element> {
    private var incoming: [Element] = []
    private var reversed: [Element] = []

    func enqueue(_ item: Element) {
        incoming.append(item)
    }

    func dequeue() -> Element? {
        if reversed.isEmpty {
            reversed = incoming.reversed()
            incoming.removeAll(keepingCapacity: true)
        }
        return reversed.popLast()
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

/// Thread-safe append-only array (lock + array). Serves the decode outcome
/// and benchmark accumulators, which workers append to and the engine reads
/// once at completion.
final class LockedAccumulator<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ item: Element) {
        lock.lock(); defer { lock.unlock() }
        items.append(item)
    }

    func snapshot() -> [Element] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}
