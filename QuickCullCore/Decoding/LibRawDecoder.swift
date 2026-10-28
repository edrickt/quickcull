import CoreGraphics
import Foundation

/// LibRaw-backed decoder: full-resolution demosaic via the C API.
/// Stateless and thread-safe: every call creates its own libraw handle.
public final class LibRawDecoder: RawDecoding {

    public init() {}

    public func decodeRaw(at url: URL, options: DecodeOptions) throws -> RawBitmap {
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
        handle.pointee.params.user_qual = Int32(options.demosaicQuality)
        handle.pointee.params.med_passes = Int32(options.medianPasses)
        ret = libraw_dcraw_process(handle)
        guard ret == LIBRAW_SUCCESS.rawValue else {
            throw DecodeError.cannotProcess(errorString(ret))
        }

        var memError: Int32 = 0
        guard let processed = libraw_dcraw_make_mem_image(handle, &memError) else {
            throw DecodeError.cannotProcess(errorString(memError))
        }
        defer { libraw_dcraw_clear_mem(processed) }

        let image = try makeCGImage(from: processed)

        return RawBitmap(image: image,
                         width: Int(processed.pointee.width),
                         height: Int(processed.pointee.height),
                         flip: Int(handle.pointee.sizes.flip),
                         histogram: histogram)
    }

    private static func rawHistogram(from handle: UnsafeMutablePointer<libraw_data_t>) -> RawHistogram? {
        let raw = handle.pointee.rawdata
        let sizes = handle.pointee.sizes
        let filters = handle.pointee.idata.filters
        guard let ptr = raw.raw_image, sizes.raw_width > 0, sizes.raw_height > 0 else { return nil }
        // 9 = X-Trans 6x6, 1 = 16x16 non-Bayer, 0 = no CFA at all (monochrome
        // sensors, where LibRaw's COLOR() returns the "0+1+2+3" special value).
        // The 2x2 LUT below would read every photosite of a mono raw as channel
        // 0 and draw an all-red histogram that looks like a sensor defect.
        guard filters != 0, filters != 9, filters != 1,
              handle.pointee.idata.colors >= 3 else { return nil }
        let rawW = Int(sizes.raw_width), rawH = Int(sizes.raw_height)
        let left = Int(sizes.left_margin), top = Int(sizes.top_margin)
        let w = Int(sizes.iwidth), h = Int(sizes.iheight)
        guard rawW > 0, rawH > 0, w > 0, h > 0,
              left + w <= rawW, top + h <= rawH else { return nil }
        let maxLevel = Int(handle.pointee.color.maximum != 0 ? handle.pointee.color.maximum : 16383)
        var counts = [[Int]](repeating: [Int](repeating: 0, count: RawHistogram.binCount), count: 3)
        var luma = [Int](repeating: 0, count: RawHistogram.binCount)
        // Bayer channel per (row, col) parity from the filters word: the
        // per-pixel shift is `filters >> ((rowParity << 1 | colParity) << 1)
        // & 3`, so the 2×2 LUT replaces two shifts + mask per pixel with one
        // lookup. Channel 3 (second green) counts as green (1).
        var channelLUT = [[Int]](repeating: [Int](repeating: 0, count: 2), count: 2)
        for rowParity in 0..<2 {
            for colParity in 0..<2 {
                let c = Int((filters >> ((rowParity << 1 | colParity) << 1)) & 3)
                channelLUT[rowParity][colParity] = c == 3 ? 1 : c
            }
        }
        for row in 0..<h {
            let rowOffset = (row + top) * rawW
            let rowLUT = channelLUT[(row + top) & 1]
            for col in 0..<w {
                let channel = rowLUT[(col + left) & 1]
                let v = Int(ptr[rowOffset + col + left])
                let bin = min(RawHistogram.binCount - 1, max(0, (v * (RawHistogram.binCount - 1)) / maxLevel))
                counts[channel][bin] += 1
                luma[bin] += 1
            }
        }
        return RawHistogram(bins: counts, luminance: luma, sensorMax: maxLevel)
    }

    private func makeCGImage(from processed: UnsafeMutablePointer<libraw_processed_image_t>) throws -> CGImage {
        let p = processed.pointee
        let expected = Int(p.width) * Int(p.height) * 3
        guard p.type == LIBRAW_IMAGE_BITMAP, p.colors == 3, p.bits == 8,
              p.width > 0, p.height > 0, Int(p.data_size) == expected else {
            throw DecodeError.invalidOutput
        }
        let dataSize = Int(p.data_size)
        let dataPtr = withUnsafePointer(to: &processed.pointee.data) { $0 }
        // Single copy via CFData; provider retains it — no extra Data copy
        let cfData: CFData? = CFDataCreate(nil, dataPtr.withMemoryRebound(to: UInt8.self, capacity: dataSize) { $0 }, dataSize)
        guard let cfData,
              let provider = CGDataProvider(data: cfData) else { throw DecodeError.invalidOutput }
        guard let image = CGImage(width: Int(p.width), height: Int(p.height),
                                  bitsPerComponent: 8, bitsPerPixel: 24,
                                  bytesPerRow: Int(p.width) * 3,
                                  // The demosaic is processed with
                                  // `output_color = sRGB`, so tag the pixels
                                  // with the space they are actually in. Device
                                  // RGB left the cache JPEG untagged, which
                                  // made colour-managed viewers guess.
                                  space: CGColorSpace(name: CGColorSpace.sRGB)
                                      ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else {
            throw DecodeError.invalidOutput
        }
        return image
    }

    private func errorString(_ code: Int32) -> String {
        String(cString: libraw_strerror(code))
    }
}
