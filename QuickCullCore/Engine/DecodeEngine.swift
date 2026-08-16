import Foundation

public struct DecodeOutcome: Equatable {
    public let file: SessionFile
    public let error: DecodeError?

    public init(file: SessionFile, error: DecodeError?) {
        self.file = file
        self.error = error
    }
}

/// Phase 1: decode every file to a cached full-res q75 JPEG in parallel,
/// bounded by the number of performance cores. Emits strictly monotonic
/// progress events, then exactly one completed event with per-file outcomes.
public actor DecodeEngine {
    public enum Event {
        case progress(completed: Int, total: Int)
        case completed([DecodeOutcome])
    }

    private let decoder: RawDecoding
    private let cache: ImageCacheStore

    public init(decoder: RawDecoding, cache: ImageCacheStore) {
        self.decoder = decoder
        self.cache = cache
    }

    public func decodeAll(files: [SessionFile]) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                let workerCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
                let queue = JobQueue<SessionFile>()
                for file in files { await queue.enqueue(file) }

                let total = files.count
                let reporter = ProgressReporter(total: total, continuation: continuation)
                let outcomes = AtomicOutcomeAccumulator()

                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<workerCount {
                        group.addTask {
                            while let file = await queue.dequeue() {
                                let outcome: DecodeOutcome
                                do {
                                    let bitmap = try self.decoder.decodeRaw(at: file.url)
                                    try await self.cache.storeJPEG(bitmap, for: file)
                                    outcome = DecodeOutcome(file: file, error: nil)
                                } catch let error as DecodeError {
                                    outcome = DecodeOutcome(file: file, error: error)
                                } catch {
                                    outcome = DecodeOutcome(file: file,
                                                            error: .cannotProcess("\(error)"))
                                }
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
