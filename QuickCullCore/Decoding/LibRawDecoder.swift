import CoreGraphics
import Foundation

/// LibRaw-backed decoder: full-resolution demosaic via the C API.
/// Stateless and thread-safe: every call creates its own libraw handle.
public final class LibRawDecoder: RawDecoding {

    public init() {}

    public func decodeRaw(at url: URL) throws -> RawBitmap {
        guard let handle = libraw_init(0) else {
            throw DecodeError.initFailed
        }
        defer { libraw_close(handle) }

        var ret = libraw_open_file(handle, url.path)
        guard ret == LIBRAW_SUCCESS.rawValue else {
            throw DecodeError.cannotOpen(errorString(ret))
        }

        ret = libraw_unpack(handle)
        guard ret == LIBRAW_SUCCESS.rawValue else {
            throw DecodeError.cannotUnpack(errorString(ret))
        }

        handle.pointee.params.output_bps = 8
        handle.pointee.params.use_camera_wb = 1
        handle.pointee.params.output_color = 1 // sRGB
        withUnsafeMutablePointer(to: &handle.pointee.params.gamm) { gPtr in
            gPtr.withMemoryRebound(to: Double.self, capacity: 6) { buf in
                buf[0] = 1.0 / 2.222
                buf[1] = 4.5
            }
        }
        ret = libraw_dcraw_process(handle)
        guard ret == LIBRAW_SUCCESS.rawValue else {
            throw DecodeError.cannotProcess(errorString(ret))
        }

        var memError: Int32 = 0
        guard let processed = libraw_dcraw_make_mem_image(handle, &memError) else {
            throw DecodeError.cannotProcess(errorString(memError))
        }
        defer { libraw_dcraw_clear_mem(processed) }

        let p = processed.pointee
        let expected = Int(p.width) * Int(p.height) * 3
        guard p.type == LIBRAW_IMAGE_BITMAP, p.colors == 3, p.bits == 8,
              p.width > 0, p.height > 0, Int(p.data_size) == expected else {
            throw DecodeError.invalidOutput
        }

        let histogram = Self.renderedHistogram(from: processed)

        // `data` is a C flexible-array member (`unsigned char data[1]`), which
        // Swift imports as a `UInt8` scalar; the pixel buffer lives immediately
        // after the struct in libraw's allocation, so take its address through
        // the heap pointee (a `let p = processed.pointee` copy would not do).
        let data = withUnsafePointer(to: &processed.pointee.data) { ptr in
            Data(bytes: ptr, count: Int(p.data_size))
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: Int(p.width), height: Int(p.height),
                  bitsPerComponent: 8, bitsPerPixel: 24,
                  bytesPerRow: Int(p.width) * 3,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil,
                  shouldInterpolate: false, intent: .defaultIntent) else {
            throw DecodeError.invalidOutput
        }

        return RawBitmap(image: image,
                         width: Int(p.width),
                         height: Int(p.height),
                         flip: Int(handle.pointee.sizes.flip),
                         histogram: histogram)
    }

    private static func renderedHistogram(from p: UnsafeMutablePointer<libraw_processed_image_t>) -> RawHistogram {
        var bins = [[Int]](repeating: [Int](repeating: 0, count: RawHistogram.binCount), count: 3)
        var luma = [Int](repeating: 0, count: RawHistogram.binCount)
        let total = Int(p.pointee.data_size)
        guard total > 0, total % 3 == 0 else { return RawHistogram(bins: bins, luminance: luma, sensorMax: 255) }
        withUnsafePointer(to: &p.pointee.data) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: total) { buf in
                for i in stride(from: 0, to: total, by: 3) {
                    let r = Int(buf[i]), g = Int(buf[i+1]), b = Int(buf[i+2])
                    bins[0][r] += 1
                    bins[1][g] += 1
                    bins[2][b] += 1
                    let yFloat = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
                    let y = min(255, max(0, Int(yFloat.rounded())))
                    luma[y] += 1
                }
            }
        }
        return RawHistogram(bins: bins, luminance: luma, sensorMax: 255)
    }

    private func errorString(_ code: Int32) -> String {
        String(cString: libraw_strerror(code))
    }
}
