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
                         flip: Int(handle.pointee.sizes.flip))
    }

    private func errorString(_ code: Int32) -> String {
        String(cString: libraw_strerror(code))
    }
}
