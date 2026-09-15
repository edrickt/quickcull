import CoreGraphics
import Foundation
import ImageIO
@testable import QuickCullCore

/// Shared fixture helpers for the QuickCullCore test target. Bodies were
/// relocated from the per-file private copies they replace; behavior is
/// identical to what each test file used before.
enum TestFixtures {
    /// Creates a fresh throwaway directory under the system temp dir.
    static func makeTempDir(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A solid-color RGB (no alpha) CGImage.
    static func makeCGImage(width: Int, height: Int, color: UInt8) -> CGImage {
        var bytes = [UInt8](repeating: color, count: width * height * 3)
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                            bitsPerPixel: 24, bytesPerRow: width * 3,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        return image
    }

    /// Writes a solid-color JPEG of the given size.
    static func writeJPEG(color: UInt8, width: Int = 64, height: Int = 40, to url: URL) throws {
        let image = makeCGImage(width: width, height: height, color: color)
        let sink = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(sink, image, nil)
        CGImageDestinationFinalize(sink)
    }

    /// Writes a raw file with arbitrary bytes (content is irrelevant to the
    /// decoders and to file identity, which is path-based).
    static func makeRawFile(named: String, in dir: URL, size: Int = 100) throws -> URL {
        let url = dir.appendingPathComponent(named)
        try Data(repeating: 7, count: size).write(to: url)
        return url
    }

    /// Session files under /tmp/shoot/, matching StubDecoder's file ids.
    static func makeFiles(_ names: [String]) -> [SessionFile] {
        names.map { SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/\($0)")) }
    }

    /// A throwaway ImageCacheStore plus its base directory.
    static func makeTempCache() async throws -> (ImageCacheStore, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (ImageCacheStore(baseURL: base), base)
    }

    /// A full-shape histogram (3 × 256 bins plus 256 luminance bins) with a
    /// couple of populated bins per channel — the only shape the decoders write
    /// and the cache validates on load.
    static func makeFullHistogram(sensorMax: Int = 16383,
                                  luminance: [Int]? = nil) -> RawHistogram {
        var bins = [[Int]](repeating: [Int](repeating: 0, count: RawHistogram.binCount), count: 3)
        for channel in 0..<3 {
            bins[channel][channel] = channel + 1
            bins[channel][RawHistogram.binCount - 1] = 9 + channel
        }
        return RawHistogram(bins: bins,
                            luminance: luminance ?? [Int](repeating: 0, count: RawHistogram.binCount),
                            sensorMax: sensorMax)
    }
}
