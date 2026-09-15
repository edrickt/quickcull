import CoreGraphics
import Foundation

/// FastRawViewer-style RAW histogram: linear pre-WB/pre-gamma Bayer counts
/// plus luminance (all raw values). sensorMax is the sensor maximum (e.g.
/// 16383); 255 is used only for rendered DisplayHistogram fallback.
public struct RawHistogram: Codable, Equatable, Sendable {
    public static let binCount = 256
    /// Per-channel counts: [red, green, blue], 256 bins each.
    public let bins: [[Int]]
    /// Overall-exposure luminance (Rec. 709 Y), 256 bins.
    public let luminance: [Int]
    /// 255 for rendered histograms; legacy linear sidecars stored sensor maximum (e.g. 16383).
    public let sensorMax: Int
    /// Total samples per entry (R, G, B, luminance).
    public var samples: [Int] { (bins + [luminance]).map { $0.reduce(0, +) } }
    /// Fraction of samples at the top bin per entry (0...1): clipped samples
    /// over total samples.
    public var clipping: [Double] {
        (bins + [luminance]).map { b in
            guard let top = b.last else { return 0 }
            let total = b.reduce(0, +)
            guard total > 0 else { return 0 }
            return Double(top) / Double(total)
        }
    }
    private enum CodingKeys: String, CodingKey { case bins, luminance, sensorMax }
    public init(bins: [[Int]], luminance: [Int], sensorMax: Int) {
        self.bins = bins
        self.luminance = luminance
        self.sensorMax = sensorMax
    }
    // Backwards compat for existing 3-property initializers in tests: keep convenience
    public init(bins: [[Int]], sensorMax: Int) {
        self.init(bins: bins, luminance: [Int](repeating: 0, count: Self.binCount), sensorMax: sensorMax)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let bins = try c.decode([[Int]].self, forKey: .bins)
        // Sidecars are written by this app, but a truncated or hand-edited file
        // must not be able to crash the histogram views with an out-of-range
        // subscript: anything that isn't the expected shape is rejected here,
        // and callers treat a decode failure as "no histogram".
        guard bins.count == 3, bins.allSatisfy({ $0.count == Self.binCount }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .bins, in: c,
                debugDescription: "expected 3 channels of \(Self.binCount) bins, got \(bins.count) of \(bins.map(\.count))")
        }
        let luminance = try c.decodeIfPresent([Int].self, forKey: .luminance)
            ?? [Int](repeating: 0, count: Self.binCount)
        guard luminance.count == Self.binCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .luminance, in: c,
                debugDescription: "expected \(Self.binCount) luminance bins, got \(luminance.count)")
        }
        self.bins = bins
        self.luminance = luminance
        self.sensorMax = try c.decode(Int.self, forKey: .sensorMax)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bins, forKey: .bins)
        try c.encode(luminance, forKey: .luminance)
        try c.encode(sensorMax, forKey: .sensorMax)
    }
}

/// Histogram of a rendered CGImage (fallback for non-RAW files).
public enum DisplayHistogram {
    /// Long edge of the buffer the rendered histogram is computed from.
    /// A display histogram is a statistical shape, and walking a full-res
    /// 45 MP image would materialize a ~180 MB RGBA buffer and ~45 M pixel
    /// reads for every metadata refresh; sampling at this size is
    /// statistically indistinguishable and keeps the HUD cheap.
    public static let maxSampleEdge = 1024

    public static func compute(from cgImage: CGImage) -> RawHistogram {
        let width = cgImage.width, height = cgImage.height
        var bins = [[Int]](repeating: [Int](repeating: 0, count: RawHistogram.binCount), count: 3)
        var lum = [Int](repeating: 0, count: RawHistogram.binCount)
        guard width > 0, height > 0 else { return RawHistogram(bins: bins, luminance: lum, sensorMax: 255) }
        let scale = min(1.0, Double(maxSampleEdge) / Double(max(width, height)))
        let sampleWidth = max(1, Int((Double(width) * scale).rounded()))
        let sampleHeight = max(1, Int((Double(height) * scale).rounded()))
        let bytesPerRow = sampleWidth * 4
        // The context allocates and owns its backing store, so no pointer has
        // to outlive the initializer call. (Passing `&pixels` for a local array
        // does exactly that: the context keeps writing through it during
        // `draw`, long after the inout access's guaranteed lifetime.)
        guard let ctx = CGContext(data: nil, width: sampleWidth, height: sampleHeight,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else {
            return RawHistogram(bins: bins, luminance: lum, sensorMax: 255)
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * sampleHeight)
        for i in stride(from: 0, to: bytesPerRow * sampleHeight, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i+1]), b = Int(pixels[i+2])
            bins[0][r * (RawHistogram.binCount - 1) / 255] += 1
            bins[1][g * (RawHistogram.binCount - 1) / 255] += 1
            bins[2][b * (RawHistogram.binCount - 1) / 255] += 1
            let y = min(255, max(0, Int((0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)).rounded())))
            let yBin = min(RawHistogram.binCount - 1, max(0, y * (RawHistogram.binCount - 1) / 255))
            lum[yBin] += 1
        }
        return RawHistogram(bins: bins, luminance: lum, sensorMax: 255)
    }
}
