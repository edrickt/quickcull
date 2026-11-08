import Foundation
import XCTest
@testable import QuickCullCore

/// `AsyncTimeout` is the quit-time cache wipe's deadline: quit must never wait
/// longer than a few seconds for a volume that stopped responding. The
/// structured-concurrency shape (`withTaskGroup` + `cancelAll`) cannot deliver
/// that, because the group waits for every child and a blocking file-system
/// call ignores cancellation.
final class AsyncTimeoutTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.lock(); raised = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }

    /// An operation the test controls: it parks until `open()`.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters = []
            for continuation in pending { continuation.resume() }
        }
    }

    func testReturnsWhenTheOperationCompletesBeforeTheDeadline() async {
        let finished = Flag()
        let started = Date()
        await AsyncTimeout.run(seconds: 5) { finished.raise() }
        XCTAssertTrue(finished.isRaised)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5,
                          "the caller must not wait for the deadline when work finishes first")
    }

    func testReturnsAtTheDeadlineWhenTheOperationIgnoresCancellation() async {
        let gate = Gate()
        let started = Date()
        await AsyncTimeout.run(seconds: 0.05) { await gate.wait() }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                          "a stalled operation must not hold the caller past its deadline")
        // Let the abandoned operation finish so no continuation is left parked.
        await gate.open()
    }

    /// Infinite, NaN and huge inputs must be clamped, not trapped by the
    /// `UInt64` nanoseconds conversion.
    func testDeadlineNanosecondsClampsNonFiniteAndHugeInputs() {
        XCTAssertEqual(AsyncTimeout.deadlineNanoseconds(.nan), 0)
        XCTAssertEqual(AsyncTimeout.deadlineNanoseconds(-5), 0)
        XCTAssertEqual(AsyncTimeout.deadlineNanoseconds(0), 0)
        XCTAssertEqual(AsyncTimeout.deadlineNanoseconds(0.05), 50_000_000)
        let maximum = UInt64(AsyncTimeout.maximumSeconds * 1_000_000_000)
        XCTAssertEqual(AsyncTimeout.deadlineNanoseconds(.infinity), maximum)
        XCTAssertEqual(AsyncTimeout.deadlineNanoseconds(1e30), maximum)
    }

    /// A deadline that would overflow the conversion must still return when the
    /// operation finishes; only clamping makes this not trap.
    func testHugeOrInfiniteDeadlineDoesNotTrap() async {
        for seconds in [Double.infinity, 1e30, .nan] {
            let started = Date()
            await AsyncTimeout.run(seconds: seconds) { }
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.5,
                              "no deadline conversion may trap or stall (seconds: \(seconds))")
        }
    }

    /// `SingleResume` is installed before the race starts today; if that ever
    /// changes, a fire that lands first must not lose the wakeup.
    func testFireBeforeInstallStillResumesTheContinuation() async {
        let resume = SingleResume()
        resume.fire()   // no continuation installed yet

        let resumed = expectation(description: "continuation resumed after install")
        Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                resume.install(continuation)
            }
            resumed.fulfill()
        }
        await fulfillment(of: [resumed], timeout: 1)
    }
}
