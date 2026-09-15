import Foundation

/// Bounds how many decodes run at once **without blocking a thread**.
///
/// A `DispatchSemaphore` waited on inside a `Task.detached` parks a
/// cooperative-pool thread per waiter, so a burst of queued decodes (a fast
/// scrub, a grid fill) can starve the pool while those waiters do nothing.
/// Here a waiter suspends instead, and `release` hands its slot straight to the
/// next waiter (FIFO), so no wakeup can be lost.
///
/// The class is lock-based rather than an actor on purpose: `withSlot` runs its
/// body in the *caller's* context, so several slots really do decode in
/// parallel — an actor would serialize every body on its own executor.
public final class DecodeLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Slots currently held (diagnostics/tests).
    public var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    /// Runs `body` while holding a slot. `body` is synchronous: decoding is
    /// CPU-bound, and suspending while holding a slot would deadlock the pool
    /// at the limit.
    public func withSlot<T>(_ body: () -> T) async -> T {
        await acquire()
        let result = body()
        release()
        return result
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if active < limit {
                active += 1
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func release() {
        lock.lock()
        guard !waiters.isEmpty else {
            active -= 1
            lock.unlock()
            return
        }
        let next = waiters.removeFirst()   // slot handed over, `active` unchanged
        lock.unlock()
        next.resume()
    }
}
