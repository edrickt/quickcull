import CoreGraphics
import Foundation

/// Linear sensor histogram (256 bins × RGB) computed from LibRaw's
/// unpacked raw data, plus a display-histogram fallback for non-RAW files.
public struct RawHistogram: Codable, Equatable, Sendable {
    public static let binCount = 256
    /// Per-channel counts: [red, green, blue], 256 bins each.
    public let bins: [[Int]]
    /// Highest possible sensor level (e.g. 16383 for 14-bit).
    public let sensorMax: Int
    /// Total samples per channel (sum of bins).
    public let samples: [Int]
    /// Fraction of samples at the top bin per channel (0...1).
    public let clipping: [Double]

    public init(bins: [[Int]], sensorMax: Int) {
        self.bins = bins
        self.sensorMax = sensorMax
        self.samples = bins.map { $0.reduce(0, +) }
        self.clipping = bins.map { b in
            guard !b.isEmpty else { return 0 }
            return Double(b[b.count - 1]) / Double(b.reduce(0, +) + 1)
        }
    }
}

/// Histogram of a rendered CGImage (fallback for non-RAW files).
public enum DisplayHistogram {
    public static func compute(from cgImage: CGImage) -> RawHistogram {
        let width = cgImage.width
        let height = cgImage.height
        var bins = [[Int]](repeating: [Int](repeating: 0, count: RawHistogram.binCount), count: 3)
        guard width > 0, height > 0 else {
            return RawHistogram(bins: bins, sensorMax: 255)
        }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return RawHistogram(bins: bins, sensorMax: 255)
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            bins[0][Int(pixels[i]) * (RawHistogram.binCount - 1) / 255] += 1
            bins[1][Int(pixels[i + 1]) * (RawHistogram.binCount - 1) / 255] += 1
            bins[2][Int(pixels[i + 2]) * (RawHistogram.binCount - 1) / 255] += 1
        }
        return RawHistogram(bins: bins, sensorMax: 255)
    }
}
