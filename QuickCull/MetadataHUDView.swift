import SwiftUI
import QuickCullCore

/// Metadata sidebar: histogram stats + rows. 240pt, slides in from the left.
struct MetadataHUDView: View {
    let file: SessionFile
    let cgImage: CGImage?
    let cache: ImageCacheStore
    @State private var metadata: ImageMetadata?
    @State private var histogram: RawHistogram?
    @State private var stats: HistogramStats?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let histogram, let stats {
                    VStack(spacing: 8) {
                        HistogramStatRow(histogram: histogram, stats: stats,
                                         topLabel: stats.rgbClippingText, topMean: "Mean \(stats.rgbMean)",
                                         canvas: { RawHistogramView(histogram: histogram).frame(height: 72) })
                        HistogramStatRow(histogram: histogram, stats: stats,
                                         topLabel: stats.lumaClippingText, topMean: "Mean \(stats.lumaMean)",
                                         canvas: { RawLuminanceHistogramView(histogram: histogram).frame(height: 72) })
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                }
                ForEach(rows, id: \.label) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.label).font(.caption2).foregroundStyle(.secondary)
                        Text(row.value).font(.caption).foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(row.label == "File" ? (metadata?.filePath ?? row.value) : row.value)
                    }
                }
            }
            .padding(10)
        }
        // Compound task id includes cgImage dimensions so thumb (320px) → full-res upgrade reruns
        // and updates dimensions; detached utility task runs file I/O off main.
        // Cancellation: when the id changes (thumb→full-res or file change),
        // SwiftUI cancels this task, but the detached workers below are NOT
        // cancelled and keep running to completion. Without a guard, the
        // cancelled task body resumes after `await` and writes its stale
        // result (thumbnail dimensions, or the previous file's whole
        // metadata block) over the newer task's output. Guard each state
        // write so only the latest task wins.
        .task(id: "\(file.id)-\(cgImage?.width ?? 0)x\(cgImage?.height ?? 0)") {
            // Clear the previous photo's rows too: a stale camera/ISO/shutter
            // block under the new file's thumbnail reads as that file's EXIF.
            metadata = nil
            histogram = nil
            stats = nil
            async let meta = Task.detached(priority: .utility) {
                // True dimensions come from the decoded cache JPEG (full-res,
                // orientation baked in) — never from the displayed CGImage,
                // which may be a 320px thumbnail or a screen-limited downsample.
                let cacheURL = try? cache.cacheURL(for: file)
                return ImageMetadataProvider.metadata(for: file, cgImage: cgImage, cacheJPEGURL: cacheURL)
            }.value
            async let hist = Task.detached(priority: .utility) {
                (try? await cache.loadHistogram(for: file)) ?? cgImage.map { DisplayHistogram.compute(from: $0) }
            }.value
            let m = await meta
            guard !Task.isCancelled else { return }
            metadata = m
            let h = await hist
            guard !Task.isCancelled else { return }
            histogram = h
            stats = h.map { HistogramStats(histogram: $0) }
        }
    }

    private var rows: [(label: String, value: String)] {
        guard let m = metadata else { return [("Loading…", "")] }
        var r: [(String, String)] = []
        r.append(("File", m.filename))
        if let v = m.dimensions { r.append(("Dimensions", v)) }
        if let v = m.fileSize { r.append(("Size", v)) }
        if let v = m.camera { r.append(("Camera", v)) }
        if let v = m.lens { r.append(("Lens", v)) }
        if let v = m.iso { r.append(("ISO", v)) }
        if let v = m.aperture { r.append(("Aperture", v)) }
        if let v = m.shutter { r.append(("Shutter", v)) }
        if let v = m.focalLength { r.append(("Focal", v)) }
        if let v = m.dateTaken { r.append(("Date", v)) }
        if let v = m.exposureBias { r.append(("Exposure Bias", v)) }
        if let v = m.whiteBalance { r.append(("White Balance", v)) }
        return r
    }
}

/// Histogram stat labels computed once per histogram value (the RawHistogram
/// `samples`/`clipping` accessors each reduce all bins, so recomputing them
/// per render was wasteful).
struct HistogramStats {
    let rgbClippingText: String
    let rgbMean: Int
    let lumaClippingText: String
    let lumaMean: Int

    init(histogram hist: RawHistogram) {
        let samples = hist.samples
        let clipping = hist.clipping
        // Per-channel mean bin value; 0 when the channel has no samples.
        // Matches the original per-render math exactly (Double means,
        // averaged, then rounded once).
        func meanRatio(_ bins: [Int], total: Int) -> Double {
            guard total > 0 else { return 0 }
            let sum = bins.enumerated().map { $0.element * $0.offset }.reduce(0, +)
            return Double(sum) / Double(total)
        }
        let meanR = meanRatio(hist.bins[0], total: samples[0])
        let meanG = meanRatio(hist.bins[1], total: samples[1])
        let meanB = meanRatio(hist.bins[2], total: samples[2])
        let lumaTotal = samples.count > 3 ? samples[3] : hist.luminance.reduce(0, +)
        let lumaMean: Int
        if lumaTotal > 0 {
            let sum = hist.luminance.enumerated().map { $0.element * $0.offset }.reduce(0, +)
            lumaMean = Int(Double(sum) / Double(lumaTotal) + 0.5)
        } else {
            lumaMean = 0
        }
        self.rgbClippingText = String(format: "R:%.1f%% G:%.1f%% B:%.1f%%",
                                      clipping[0] * 100, clipping[1] * 100, clipping[2] * 100)
        self.rgbMean = Int((meanR + meanG + meanB) / 3 + 0.5)
        self.lumaClippingText = String(format: "Luma %.1f%%",
                                       (clipping.count > 3 ? clipping[3] : 0) * 100)
        self.lumaMean = lumaMean
    }
}

/// Shared stat-row layout for the two histogram panels: labels above, canvas below.
private struct HistogramStatRow<Canvas: View>: View {
    let histogram: RawHistogram
    let stats: HistogramStats
    let topLabel: String
    let topMean: String
    @ViewBuilder let canvas: () -> Canvas

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(topLabel)
                Spacer()
                Text(topMean)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            canvas()
        }
    }
}
