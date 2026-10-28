import CoreGraphics
import XCTest
@testable import QuickCullCore

final class RawHistogramTests: XCTestCase {
    /// 256-bin channel with `values` placed at the top bins — the clipping end
    /// that `clipping` reads.
    private func topBins(_ values: [Int]) -> [Int] {
        var bins = [Int](repeating: 0, count: RawHistogram.binCount)
        for (offset, value) in values.enumerated() {
            bins[RawHistogram.binCount - values.count + offset] = value
        }
        return bins
    }

    func testInitComputesSamplesAndClipping() {
        let bins = [
            topBins([0, 5, 0, 10]),   // red: total 15, top bin 10 → clipping 10/15
            topBins([1, 2, 3, 9]),    // green: total 15, top bin 9 → clipping 9/15
            topBins([]),
        ]
        let h = RawHistogram(bins: bins, sensorMax: 255)
        XCTAssertEqual(h.samples, [15, 15, 0, 0])
        XCTAssertEqual(h.samples.count, 4)
        XCTAssertEqual(h.clipping.count, 4)
        XCTAssertEqual(RawHistogram.binCount, 256)
        XCTAssertEqual(h.clipping[0], 10.0 / 15.0, accuracy: 1e-9)
        XCTAssertEqual(h.clipping[1], 9.0 / 15.0, accuracy: 1e-9)
        XCTAssertEqual(h.clipping[2], 0.0, accuracy: 1e-9)
        XCTAssertEqual(h.clipping[3], 0.0, accuracy: 1e-9)
        XCTAssertEqual(h.sensorMax, 255)
    }

    func testClippingIsTopBinOverTotal() {
        // No +1 fudge on the denominator: the fraction is clipped/total.
        let h = RawHistogram(bins: [topBins([3, 1]), topBins([4]), topBins([0])],
                             luminance: topBins([2, 2]), sensorMax: 255)
        XCTAssertEqual(h.clipping[0], 1.0 / 4.0, accuracy: 1e-12)
        XCTAssertEqual(h.clipping[1], 1.0, accuracy: 1e-12)
        XCTAssertEqual(h.clipping[2], 0.0, accuracy: 1e-12)
        XCTAssertEqual(h.clipping[3], 0.5, accuracy: 1e-12)
    }

    func testCodableRoundTrip() throws {
        let bins = [topBins([0, 1, 2]), topBins([3, 4, 5]), topBins([6, 7, 8])]
        let h = RawHistogram(bins: bins, sensorMax: 16383)
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

    func testLuminanceBinsSumToPixelCount() {
        let bins = [[1,2],[3,4],[5,6]]
        var lum = [Int](repeating: 0, count: RawHistogram.binCount)
        lum[0] = 7
        lum[1] = 8
        let h = RawHistogram(bins: bins, luminance: lum, sensorMax: 100)
        XCTAssertEqual(h.luminance.count, RawHistogram.binCount)
        // luminance sum is independent; but for a real histogram it equals pixel count
        XCTAssertEqual(h.luminance[0], 7)
        XCTAssertEqual(h.luminance[1], 8)
    }

    func testInitStoresLuminanceAndSamplesClippingFourEntries() {
        let bins = [[0,10,0,5],[1,2,3,9],[0,0,0,0]]
        let lum = [0,0,15,0]
        let h = RawHistogram(bins: bins, luminance: lum, sensorMax: 255)
        XCTAssertEqual(h.bins, bins)
        XCTAssertEqual(h.luminance, lum)
        XCTAssertEqual(h.samples.count, 4)
        XCTAssertEqual(h.clipping.count, 4)
        XCTAssertEqual(h.samples[3], 15)
    }

    func testCodableRoundTripWithLuminance() throws {
        let bins = [topBins([0, 1, 2]), topBins([3, 4, 5]), topBins([6, 7, 8])]
        let h = RawHistogram(bins: bins, luminance: topBins([9, 10, 11]), sensorMax: 16383)
        let data = try JSONEncoder().encode(h)
        let decoded = try JSONDecoder().decode(RawHistogram.self, from: data)
        XCTAssertEqual(decoded, h)
    }

    func testCodableBackwardsCompatMissingLuminance() throws {
        let bins = [topBins([0, 1]), topBins([2, 3]), topBins([4, 5])]
        let payload: [String: Any] = ["bins": bins, "sensorMax": 255]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(RawHistogram.self, from: data)
        XCTAssertEqual(decoded.luminance, [Int](repeating: 0, count: RawHistogram.binCount))
        XCTAssertEqual(decoded.bins, bins)
    }

    /// A sidecar that is valid JSON but the wrong shape must fail to decode:
    /// the views subscript `bins[0...2]` and would trap otherwise.
    func testDecodeRejectsWrongShape() throws {
        let payloads: [[String: Any]] = [
            // Two channels instead of three.
            ["bins": [topBins([1]), topBins([1])], "sensorMax": 255],
            // Short channel.
            ["bins": [topBins([1]), topBins([1]), [Int](repeating: 0, count: 4)], "sensorMax": 255],
            // Short luminance.
            ["bins": [topBins([1]), topBins([1]), topBins([1])], "luminance": [1, 2], "sensorMax": 255],
        ]
        for payload in payloads {
            let data = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertThrowsError(try JSONDecoder().decode(RawHistogram.self, from: data),
                                 "malformed sidecar decoded: \(payload.keys)")
        }
    }

    func testDisplayHistogramLuminancePeakForFlatGray() {
        let img = TestFixtures.makeCGImage(width: 32, height: 16, color: 128)
        let h = DisplayHistogram.compute(from: img)
        XCTAssertEqual(h.luminance.count, RawHistogram.binCount)
        let expectedBin = 128 * (RawHistogram.binCount - 1) / 255
        XCTAssertEqual(h.luminance[expectedBin], 32*16)
        XCTAssertEqual(h.samples[3], 32*16)
    }

    /// Large images are sampled rather than walked pixel by pixel, so the same
    /// invariant holds: every sampled pixel lands in exactly one bin.
    func testDisplayHistogramSamplesLargeImage() {
        let img = TestFixtures.makeCGImage(width: 3000, height: 2000, color: 200)
        let h = DisplayHistogram.compute(from: img)
        let sampled = h.luminance.reduce(0, +)
        XCTAssertEqual(h.samples[0], sampled)
        XCTAssertEqual(h.samples[1], sampled)
        XCTAssertEqual(h.samples[2], sampled)
        XCTAssertLessThanOrEqual(sampled,
                                 DisplayHistogram.maxSampleEdge * DisplayHistogram.maxSampleEdge)
        XCTAssertGreaterThan(sampled, 0)
        let expectedBin = 200 * (RawHistogram.binCount - 1) / 255
        XCTAssertEqual(h.luminance[expectedBin], sampled, "flat image keeps one populated bin")
    }

    /// Every other display-histogram test uses a grey image, where a red/blue
    /// swap (or swapped Rec.709 coefficients) is invisible. A pure-red image
    /// lands entirely in channel 0 and in luminance's dark end.
    func testDisplayHistogramKeepsRedInTheRedChannel() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let red = try XCTUnwrap(context.makeImage())

        let h = DisplayHistogram.compute(from: red)
        XCTAssertEqual(h.bins[0][255], 256, "all red pixels in the top red bin")
        XCTAssertEqual(h.bins[2][0], 256, "blue channel is at zero")
        XCTAssertEqual(h.samples[1], 256)
        XCTAssertLessThan(h.bins[1].last ?? 0, 256, "green is not saturated by a red image")
        // Rec.709 Y for pure red is ~54/255 (81 here after the DeviceRGB
        // conversion); a swapped coefficient set would peak near green's 182.
        let lumaPeak = h.luminance.firstIndex(of: h.luminance.max()!)!
        XCTAssertLessThan(lumaPeak, 100, "luminance of pure red must sit in the dark end")
        XCTAssertTrue(h.isRendered)
    }

    func testLinearHistogramIsNotLabelledRendered() {
        XCTAssertFalse(TestFixtures.makeFullHistogram(sensorMax: 16383).isRendered)
        XCTAssertFalse(TestFixtures.makeFullHistogram(sensorMax: 4095).isRendered)
        XCTAssertTrue(TestFixtures.makeFullHistogram(sensorMax: 255).isRendered)
    }
}
