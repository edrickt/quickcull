import CoreGraphics
import XCTest
@testable import QuickCullCore

final class RawHistogramTests: XCTestCase {
    func testInitComputesSamplesAndClipping() {
        let bins = [
            [0, 5, 0, 10],   // red: total 15, last=10 → clipping 10/16
            [1, 2, 3, 9],    // green: total 15, last=9 → clipping 9/16
            [0, 0, 0, 0],
        ]
        let h = RawHistogram(bins: bins, sensorMax: 255)
        XCTAssertEqual(h.samples, [15, 15, 0])
        XCTAssertEqual(RawHistogram.binCount, 256)
        XCTAssertEqual(h.clipping[0], 10.0 / 16.0, accuracy: 1e-9)
        XCTAssertEqual(h.clipping[2], 0.0, accuracy: 1e-9)
        XCTAssertEqual(h.sensorMax, 255)
    }

    func testCodableRoundTrip() throws {
        let h = RawHistogram(bins: [[0, 1, 2], [3, 4, 5], [6, 7, 8]], sensorMax: 16383)
        let data = try JSONEncoder().encode(h)
        let decoded = try JSONDecoder().decode(RawHistogram.self, from: data)
        XCTAssertEqual(decoded, h)
    }

    func testDisplayHistogramOfFlatGrayImage() {
        let img = TestFixtures.makeCGImage(width: 32, height: 16, color: 128)
        let h = DisplayHistogram.compute(from: img)
        XCTAssertEqual(h.bins.count, 3)
        XCTAssertTrue(h.bins.allSatisfy { $0.count == RawHistogram.binCount })
        // flat gray: every channel pegged at 128
        let expectedBin = 128 * (RawHistogram.binCount - 1) / 255
        for channel in 0..<3 {
            XCTAssertEqual(h.bins[channel][expectedBin], 32 * 16)
            XCTAssertEqual(h.samples[channel], 32 * 16)
        }
        XCTAssertEqual(h.sensorMax, 255)
    }
}
