import CoreGraphics
import Foundation

/// Rendered sRGB histogram (8-bit post-demosaic, post-WB, post-gamma) plus
/// weighted luminance (Rec.709 Y). sensorMax is 255 for rendered histograms.
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
    /// Fraction of samples at the top bin per entry (0...1).
    public var clipping: [Double] {
        (bins + [luminance]).map { b in
            guard !b.isEmpty else { return 0 }
            return Double(b[b.count - 1]) / Double(b.reduce(0, +) + 1)
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
        bins = try c.decode([[Int]].self, forKey: .bins)
        sensorMax = try c.decode(Int.self, forKey: .sensorMax)
        luminance = try c.decodeIfPresent([Int].self, forKey: .luminance) ?? [Int](repeating: 0, count: Self.binCount)
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
    public static func compute(from cgImage: CGImage) -> RawHistogram {
        let width = cgImage.width, height = cgImage.height
        var bins = [[Int]](repeating: [Int](repeating: 0, count: RawHistogram.binCount), count: 3)
        var lum = [Int](repeating: 0, count: RawHistogram.binCount)
        guard width > 0, height > 0 else { return RawHistogram(bins: bins, luminance: lum, sensorMax: 255) }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return RawHistogram(bins: bins, luminance: lum, sensorMax: 255)
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: pixels.count, by: 4) {
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
