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

        let histogram = Self.rawHistogram(from: handle)

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
                         flip: Int(handle.pointee.sizes.flip),
                         histogram: histogram)
    }

    private static func rawHistogram(from handle: UnsafeMutablePointer<libraw_data_t>) -> RawHistogram? {
        let raw = handle.pointee.rawdata
        let sizes = handle.pointee.sizes
        let filters = handle.pointee.idata.filters
        guard let ptr = raw.raw_image, sizes.raw_width > 0, sizes.raw_height > 0 else { return nil }
        guard filters != 9 && filters != 1 else { return nil } // 9=X-Trans 6x6, 1=16x16 non-Bayer
        let rawW = Int(sizes.raw_width), rawH = Int(sizes.raw_height)
        let left = Int(sizes.left_margin), top = Int(sizes.top_margin)
        // Visible region: exactly the raw pixels dcraw_process demosaics into
        // the output bitmap (margins and edge crops stripped). When the region
        // extends beyond the raw buffer the sensor is laid out non-rectilinearly
        // (e.g. Fuji super-CCD 45° rotation) — no Bayer column walk applies.
        let w = Int(sizes.iwidth), h = Int(sizes.iheight)
        guard rawW > 0, rawH > 0, w > 0, h > 0,
              left + w <= rawW, top + h <= rawH else { return nil }
        let maxLevel = Int(handle.pointee.color.maximum != 0 ? handle.pointee.color.maximum : 16383)
        var counts = [[Int]](repeating: [Int](repeating: 0, count: RawHistogram.binCount), count: 3)
        for row in 0..<h {
            let rowOffset = (row + top) * rawW
            for col in 0..<w {
                // dcraw fcol: Bayer color at absolute raw coordinate (row+top, col+left)
                let c = Int((filters >> (((((row + top) & 1) << 1 | ((col + left) & 1)) << 1)) & 3))
                // 0=R, 1=G, 2=B, 3=G2 → merge G2 into green (index 1)
                let channel = c == 3 ? 1 : c
                let v = Int(ptr[rowOffset + col + left])
                let bin = min(RawHistogram.binCount - 1, max(0, (v * (RawHistogram.binCount - 1)) / maxLevel))
                counts[channel][bin] += 1
            }
        }
        return RawHistogram(bins: counts, sensorMax: maxLevel)
    }

    private func errorString(_ code: Int32) -> String {
        String(cString: libraw_strerror(code))
    }
}
