import SwiftUI
import QuickCullCore

/// Shared log-y drawing for the two metadata-HUD histogram canvases.
/// The RGB view passes one log-max computed across all three channels so
/// the channels share the same vertical scale (as before the split).
enum HistogramCanvas {
    static func logMax(values: [Int]) -> Double {
        let rawMax = values.map { log10(Double($0) + 1) }.max() ?? 0
        return rawMax > 0 ? rawMax : 1
    }

    static func yFor(_ count: Int, size: CGSize, logMax: Double) -> Double {
        size.height * (1 - log10(Double(count) + 1) / logMax)
    }

    static func drawAxes(ctx: GraphicsContext, size: CGSize) {
        var axes = Path()
        axes.move(to: CGPoint(x: 0, y: size.height))
        axes.addLine(to: CGPoint(x: size.width, y: size.height))
        axes.move(to: CGPoint(x: 0, y: 0))
        axes.addLine(to: CGPoint(x: 0, y: size.height))
        ctx.stroke(axes, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
    }

    static func drawPolyline(ctx: GraphicsContext, values: [Int], size: CGSize, logMax: Double, color: Color) {
        let binCount = RawHistogram.binCount
        guard values.count == binCount, size.width > 0, size.height > 0 else { return }
        let binW = size.width / Double(binCount)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: yFor(values[0], size: size, logMax: logMax)))
        for bin in 1..<binCount {
            path.addLine(to: CGPoint(x: Double(bin) * binW,
                                     y: yFor(values[bin], size: size, logMax: logMax)))
        }
        ctx.stroke(path, with: .color(color), lineWidth: 1.5)
    }

    static func drawClippingMarker(ctx: GraphicsContext, size: CGSize) {
        var line = Path()
        line.move(to: CGPoint(x: size.width - 1, y: 0))
        line.addLine(to: CGPoint(x: size.width - 1, y: size.height))
        ctx.stroke(line, with: .color(.white), lineWidth: 1)
    }
}

/// RGB histogram overlay with log-y scaling and a clipping marker at
/// sensorMax. 256 bins span the width; channels share one log-y scale.
struct RawHistogramView: View {
    let histogram: RawHistogram
    var body: some View {
        Canvas { ctx, size in
            guard size.width > 0, size.height > 0 else { return }
            HistogramCanvas.drawAxes(ctx: ctx, size: size)
            let logMax = HistogramCanvas.logMax(values: histogram.bins.flatMap { $0 })
            let colors: [Color] = [.red.opacity(0.9), .green.opacity(0.9), .blue.opacity(0.9)]
            for channel in 0..<3 {
                HistogramCanvas.drawPolyline(ctx: ctx, values: histogram.bins[channel],
                                             size: size, logMax: logMax, color: colors[channel])
            }
            if histogram.clipping.prefix(3).contains(where: { $0 > 0.001 }) {
                HistogramCanvas.drawClippingMarker(ctx: ctx, size: size)
            }
        }
        .background(.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel(histogram.isRendered ? "Rendered RGB histogram" : "RAW histogram")
    }
}

/// Single-channel overall-exposure histogram, same log-y and clipping marker as RGB.
struct RawLuminanceHistogramView: View {
    let histogram: RawHistogram
    var body: some View {
        Canvas { ctx, size in
            guard size.width > 0, size.height > 0 else { return }
            HistogramCanvas.drawAxes(ctx: ctx, size: size)
            let logMax = HistogramCanvas.logMax(values: histogram.luminance)
            HistogramCanvas.drawPolyline(ctx: ctx, values: histogram.luminance,
                                         size: size, logMax: logMax, color: .white.opacity(0.9))
            if histogram.clipping.count > 3 && histogram.clipping[3] > 0.001 {
                HistogramCanvas.drawClippingMarker(ctx: ctx, size: size)
            }
        }
        .background(.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel(histogram.isRendered ? "Rendered luminance histogram" : "Luminance histogram")
    }
}
