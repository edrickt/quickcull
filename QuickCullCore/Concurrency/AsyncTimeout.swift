import Foundation

/// Runs an async operation with a deadline.
///
/// The operation is not interrupted when the deadline wins; the caller simply
/// stops waiting for it. That is the only safe contract for the operation this
/// exists for (deleting the decode cache): a blocking file-system call on a
/// stalled volume cannot be aborted, so a "timeout" must not keep the caller
/// hostage until the syscall returns.
///
/// A structured `withTaskGroup` cannot express this: the group waits for every
/// child, and cancellation is cooperative, so an operation that ignores it
/// (a file-system call on a stalled volume) never lets the group return past
/// the deadline. The work runs in an unstructured task and the first of
/// "operation finished" / "deadline reached" resumes the caller exactly once.
public enum AsyncTimeout {
    /// Longest deadline this accepts. Values above it are clamped before the
    /// nanoseconds conversion; non-finite and negative values mean "already
    /// elapsed". Without the clamp `UInt64(seconds * 1e9)` traps for infinite or
    /// very large inputs.
    static let maximumSeconds: Double = 24 * 60 * 60

    /// Nanoseconds for `seconds`, clamped to `0...maximumSeconds`.
    static func deadlineNanoseconds(_ seconds: Double) -> UInt64 {
        guard !seconds.isNaN else { return 0 }
        let clamped = min(max(seconds, 0), maximumSeconds)
        return UInt64(clamped * 1_000_000_000)
    }

    /// Returns when `operation` completes or `seconds` elapse, whichever is
    /// first. `operation` keeps running if the deadline wins.
    public static func run(seconds: Double,
                           operation: @escaping @Sendable () async -> Void) async {
        let resume = SingleResume()
        let deadline = deadlineNanoseconds(seconds)
        let timer = TaskBox()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            resume.install(continuation)
            // The operation keeps the caller's intent (the quit-time wipe is
            // user-initiated work, not background housekeeping); only the timer
            // is utility.
            Task.detached(priority: .userInitiated) {
                await operation()
                resume.fire()
            }
            timer.task = Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: deadline)
                resume.fire()
            }
        }
        // The operation won the race: the timer has no reason to keep running.
        // (If the deadline won instead, this cancels a finished timer.)
        timer.task?.cancel()
    }
}

/// Writer/reader box for the deadline task, which is created inside the
/// continuation and cancelled after the race.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Task<Void, Never>?

    var task: Task<Void, Never>? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Resumes a checked continuation at most once. A fire that lands before the
/// continuation is installed is remembered, and the continuation is resumed on
/// install, so no ordering of the two can lose the wakeup. (The race installs
/// first today; this keeps the class safe if that changes.)
final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if fired {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func fire() {
        lock.lock()
        guard !fired else { lock.unlock(); return }
        fired = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
