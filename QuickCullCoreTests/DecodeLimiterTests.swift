import Foundation
import XCTest
@testable import QuickCullCore

final class DecodeLimiterTests: XCTestCase {
    /// Thread-safe concurrency probe: peak overlap and completion count.
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight = 0
        private var peakValue = 0
        private var completed = 0

        func enter() {
            lock.lock(); defer { lock.unlock() }
            inFlight += 1
            peakValue = max(peakValue, inFlight)
        }

        func leave() {
            lock.lock(); defer { lock.unlock() }
            inFlight -= 1
            completed += 1
        }

        var peak: Int { lock.lock(); defer { lock.unlock() }; return peakValue }
        var completions: Int { lock.lock(); defer { lock.unlock() }; return completed }
    }

    func testWithSlotNeverExceedsLimitAndEveryCallerCompletes() async {
        let limiter = DecodeLimiter(limit: 3)
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    await limiter.withSlot {
                        probe.enter()
                        var sum = 0
                        for i in 0..<200_000 { sum &+= i }
                        _ = sum
                        probe.leave()
                    }
                }
            }
        }
        XCTAssertLessThanOrEqual(probe.peak, 3, "the limiter must bound concurrent bodies")
        XCTAssertEqual(probe.completions, 24, "no waiter may be lost (a lost wakeup hangs here)")
        XCTAssertEqual(limiter.activeCount, 0, "every slot is returned")
    }

    func testWithSlotReturnsBodyValue() async {
        let limiter = DecodeLimiter(limit: 2)
        let value = await limiter.withSlot { 41 + 1 }
        XCTAssertEqual(value, 42)
        let optional = await limiter.withSlot { () -> Int? in nil }
        XCTAssertNil(optional)
        XCTAssertEqual(limiter.activeCount, 0)
    }

    /// A single slot still makes progress: bodies run one after another rather
    /// than deadlocking on the limiter.
    func testLimitOfOneSerializesButCompletes() async {
        let limiter = DecodeLimiter(limit: 1)
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await limiter.withSlot {
                        probe.enter()
                        var sum = 0
                        for i in 0..<100_000 { sum &+= i }
                        _ = sum
                        probe.leave()
                    }
                }
            }
        }
        XCTAssertEqual(probe.peak, 1)
        XCTAssertEqual(probe.completions, 8)
        XCTAssertEqual(limiter.activeCount, 0)
    }

    /// `limit` below 1 is clamped, so a misconfigured knob cannot hang decodes.
    func testZeroLimitIsClampedToOne() async {
        let limiter = DecodeLimiter(limit: 0)
        let value = await limiter.withSlot { "ok" }
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(limiter.activeCount, 0)
    }
}
