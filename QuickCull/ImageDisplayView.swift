import SwiftUI
import QuickCullCore
#if canImport(AppKit)
import AppKit
#endif

struct ImageDisplayView: View {
    @Environment(AppState.self) private var appState
    @Binding var zoomScale: CGFloat
    @Binding var zoomLastScale: CGFloat
    @Binding var zoomOffset: CGSize
    @Binding var zoomLastOffset: CGSize
    @Binding var hudVisible: Bool

    var body: some View {
        let index = appState.session?.currentIndex ?? 0
        // Resolve the current file HERE, guarded: `files` shrinks on commit
        // and on filter drop-outs, and a child view re-evaluated with a
        // captured index would trap on `files[index]` (crash). Passing the
        // file — not the index — keeps the badge lookup safe and
        // id-based, like the filmstrip cells.
        let currentFile = (appState.session?.files.indices.contains(index) ?? false)
            ? appState.session?.files[index]
            : nil
        let rightIndex = index + 1
        let rightFile: SessionFile? = (appState.session?.files.indices.contains(rightIndex) ?? false)
            ? appState.session?.files[rightIndex]
            : nil
        let leftCG = appState.displayImages?.image(at: index) ?? appState.thumbWindow?.image(at: index)
        let rightCG = rightFile != nil ? (appState.displayImages?.image(at: rightIndex) ?? appState.thumbWindow?.image(at: rightIndex)) : nil

        ZStack {
            Color.black
            if appState.session?.files.isEmpty == true {
                // Filter matches nothing (Flagged 0 or Keepers 0) — nothing to load, show empty black instead of spinner
                Color.black
            } else if appState.viewMode == .split {
                HStack(spacing: 8) {
                    if hudVisible, let file = currentFile, let lcg = leftCG {
                        MetadataHUDView(file: file, cgImage: lcg, cache: appState.cache)
                            .frame(width: 240)
                            .background(.ultraThinMaterial)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack {
                                Color.black
                                if let img = leftCG, let file = currentFile {
                                    ZoomableImageView(cgImage: img, fileID: file.id, scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
                                        .overlay(alignment: .topTrailing) { FlagBadgeOverlay(file: file) }
                                } else { Color.black }
                            }.frame(width: geo.size.width, height: geo.size.height)
                        }.clipped()
                        GeometryReader { geo in
                            ZStack {
                                Color.black
                                if let img = rightCG, rightFile != nil {
                                    ZoomableImageView(cgImage: img, fileID: currentFile?.id, scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
                                } else if rightFile == nil {
                                    VStack(spacing: 8) { Image(systemName:"photo.slash").font(.title2).foregroundStyle(.secondary)
                                                         Text("No next image").font(.caption).foregroundStyle(.secondary) }
                                } else {
                                    Color.black
                                }
                            }.frame(width: geo.size.width, height: geo.size.height)
                        }.clipped()
                    }
                    if hudVisible {
                        if let rFile = rightFile, let rcg = rightCG {
                            MetadataHUDView(file: rFile, cgImage: rcg, cache: appState.cache)
                                .frame(width: 240)
                                .background(.ultraThinMaterial)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        } else if rightFile == nil {
                            VStack(spacing: 8) {
                                Image(systemName: "photo.slash").font(.title2).foregroundStyle(.secondary)
                                Text("No next image").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: 240)
                            .frame(maxHeight: .infinity, alignment: .center)
                            .background(.ultraThinMaterial)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        } else {
                            // rightFile exists but rightCG still nil (thumb pending) — show Loading HUD via MetadataHUDView with nil cgImage
                            if let rFile = rightFile {
                                MetadataHUDView(file: rFile, cgImage: nil, cache: appState.cache)
                                    .frame(width: 240)
                                    .background(.ultraThinMaterial)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                    }
                }
                .overlay(alignment: .topTrailing) { /* no right badge */ }
                .animation(.easeInOut(duration: 0.2), value: hudVisible)
                .animation(.easeInOut(duration: 0.15), value: appState.viewMode)
            } else if let cgImage = leftCG { // Single (existing)
                HStack(spacing: 8) { // was spacing:0 with Divider() after HUD — gap via spacing 8 + Color.black
                    if hudVisible, let file = currentFile {
                        MetadataHUDView(file: file, cgImage: cgImage, cache: appState.cache).frame(width: 240).background(.ultraThinMaterial).transition(.move(edge:.leading).combined(with:.opacity))
                        // Divider() removed — gap via HStack spacing 8
                    }
                    GeometryReader { geo in
                        ZStack {
                            Color.black
                            ZoomableImageView(cgImage: cgImage, fileID: currentFile?.id, scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
                        }.frame(width: geo.size.width, height: geo.size.height)
                    }.clipped()
                }
                .overlay(alignment: .topTrailing) { FlagBadgeOverlay(file: currentFile) }
                .animation(.easeInOut(duration: 0.2), value: hudVisible)
            } else {
                ProgressView().controlSize(.large)
            }
        }
    }

}

/// Zoomable container for the main viewer image.
/// - Pinch (trackpad) scales 1x…4x.
/// - Double-click toggles fit (1x) ↔ 200% (2x). Any zoomed state double-click unzooms.
/// - Drag pans when zoomed (mouse drag + trackpad two-finger scroll), clamped so the image never leaves the viewport.
private struct ZoomableImageView: View {
    let cgImage: CGImage
    let fileID: String?

    @Binding var scale: CGFloat
    @Binding var lastScale: CGFloat
    @Binding var offset: CGSize
    @Binding var lastOffset: CGSize

    @State private var globalFrame: CGRect = .zero
    @State private var scrollMonitor: Any?
    @State private var liveContainer: CGSize = .zero
    @State private var liveFitted: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let container = geo.size
            let fitted = fittedSize(for: cgImage, in: container)
            ZStack {
                Color.black
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: fitted.width, height: fitted.height)
                    .scaleEffect(scale)
                    .offset(offset)
            }
            .frame(width: container.width, height: container.height)
            .contentShape(Rectangle())
            .clipped()
            .onTapGesture(count: 2) {
                handleDoubleClick()
            }
            .gesture(magnificationGesture(container: container, fitted: fitted))
            .simultaneousGesture(dragGesture(container: container, fitted: fitted))
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { globalFrame = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { _, newFrame in globalFrame = newFrame }
                }
            )
            .onAppear {
                liveContainer = container
                liveFitted = fitted
                installScrollMonitor()
            }
            .onDisappear { removeScrollMonitor() }
            .onChange(of: container) { _, newValue in
                liveContainer = newValue
                liveFitted = fittedSize(for: cgImage, in: newValue)
                if scale > 1.01 {
                    let clamped = clampedOffset(offset, container: newValue, fitted: liveFitted, scale: scale)
                    if clamped != offset { offset = clamped; lastOffset = clamped }
                }
                installScrollMonitor()
            }
            .onChange(of: fitted) { _, newFitted in
                liveFitted = newFitted
                installScrollMonitor()
            }
            .onChange(of: fileID) { _, _ in
                // Persist zoom scale across images; re-center pan for the new photo.
                // Keep scale/lastScale, reset offset so each new image appears centered
                // at the same magnification (avoids leftover pan pushing new image out of bounds
                // when aspect changes). Thumb->display for same fileID does not trigger this.
                offset = .zero
                lastOffset = .zero
            }
        }
    }

    private func installScrollMonitor() {
        removeScrollMonitor()
#if canImport(AppKit)
        let offsetBinding = $offset
        let lastOffsetBinding = $lastOffset
        let scaleBinding = $scale
        let frameBinding = $globalFrame
        let containerBinding = $liveContainer
        let fittedBinding = $liveFitted
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let currentScale = scaleBinding.wrappedValue
            guard currentScale > 1.01 else { return event }
            // Only handle event over this pane — prevents Split double-apply.
            // If globalFrame is still .zero (pre-layout), allow handling so initial
            // two-finger pan isn't blocked until the first layout pass / click-drag.
            let gf = frameBinding.wrappedValue
            let mouse = NSEvent.mouseLocation
            if !gf.isEmpty && !gf.contains(mouse) { return event }
            let dx: CGFloat = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : CGFloat(event.deltaX) * 10
            let dy: CGFloat = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : CGFloat(event.deltaY) * 10
            if abs(dx) < 0.02 && abs(dy) < 0.02 { return event }
            let currentOffset = offsetBinding.wrappedValue
            // Inverted on both axes (e254e00): +dx/+dy
            let new = CGSize(width: currentOffset.width + dx, height: currentOffset.height + dy)
            let clamped = clampedOffset(new, container: containerBinding.wrappedValue, fitted: fittedBinding.wrappedValue, scale: currentScale)
            // Synchronous — no DispatchQueue.main.async
            offsetBinding.wrappedValue = clamped
            lastOffsetBinding.wrappedValue = clamped
            return nil // consume while zoomed
        }
#endif
    }

    private func removeScrollMonitor() {
#if canImport(AppKit)
        if let m = scrollMonitor {
            NSEvent.removeMonitor(m)
            scrollMonitor = nil
        }
#endif
    }

    // MARK: - Gestures

    private func magnificationGesture(container: CGSize, fitted: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                var tx = Transaction()
                tx.animation = nil
                tx.disablesAnimations = true
                withTransaction(tx) {
                    let newScale = lastScale * value
                    let clamped = min(max(newScale, 1), 4)
                    scale = clamped
                    if clamped <= 1.01 {
                        offset = .zero
                    } else {
                        offset = clampedOffset(offset, container: container, fitted: fitted, scale: clamped)
                    }
                }
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.01 {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        scale = 1
                        offset = .zero
                    }
                    lastScale = 1
                    lastOffset = .zero
                } else {
                    let clamped = clampedOffset(offset, container: container, fitted: fitted, scale: scale)
                    if clamped != offset {
                        var tx = Transaction(); tx.animation = nil; tx.disablesAnimations = true
                        withTransaction(tx) { offset = clamped }
                    }
                    lastOffset = offset
                }
            }
    }

    private func dragGesture(container: CGSize, fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { val in
                guard scale > 1.01 else { return }
                var tx = Transaction()
                tx.animation = nil
                tx.disablesAnimations = true
                withTransaction(tx) {
                    let new = CGSize(
                        width: lastOffset.width + val.translation.width,
                        height: lastOffset.height + val.translation.height
                    )
                    offset = clampedOffset(new, container: container, fitted: fitted, scale: scale)
                }
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private func handleDoubleClick() {
        if scale > 1.01 {
            withAnimation(.easeInOut(duration: 0.2)) {
                scale = 1
                offset = .zero
            }
            lastScale = 1
            lastOffset = .zero
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                scale = 2
                offset = .zero
            }
            lastScale = 2
            lastOffset = .zero
        }
    }

    // MARK: - Math

    private func fittedSize(for image: CGImage, in container: CGSize) -> CGSize {
        guard container.width > 0, container.height > 0 else { return .zero }
        let imageAspect = CGFloat(image.width) / CGFloat(image.height)
        let containerAspect = container.width / container.height
        if imageAspect > containerAspect {
            let w = container.width
            return CGSize(width: w, height: w / imageAspect)
        } else {
            let h = container.height
            return CGSize(width: h * imageAspect, height: h)
        }
    }

    private func clampedOffset(_ off: CGSize, container: CGSize, fitted: CGSize, scale: CGFloat) -> CGSize {
        let scaledW = fitted.width * scale
        let scaledH = fitted.height * scale
        let maxX = max((scaledW - container.width) / 2, 0)
        let maxY = max((scaledH - container.height) / 2, 0)
        return CGSize(
            width: min(max(off.width, -maxX), maxX),
            height: min(max(off.height, -maxY), maxY)
        )
    }
}

private struct MetadataHUDView: View {
    let file: SessionFile
    let cgImage: CGImage?
    let cache: ImageCacheStore
    @State private var metadata: ImageMetadata?
    @State private var histogram: RawHistogram?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let hist = histogram {
                    VStack(spacing: 8) {
                        RawHistogramView(histogram: hist)
                            .frame(height: 72)
                        RawLuminanceHistogramView(histogram: hist)
                            .frame(height: 72)
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
        // Note: Task.detached is not a child of the outer .task, so cancellation of the outer
        // task (on rapid scrub) does not automatically cancel the detached work; the outer
        // .task discards its result when cancelled and only the latest file/dimensions wins.
        .task(id: "\(file.id)-\(cgImage?.width ?? 0)x\(cgImage?.height ?? 0)") {
            histogram = nil
            async let meta = Task.detached(priority: .utility) {
                ImageMetadataProvider.metadata(for: file, cgImage: cgImage)
            }.value
            async let hist = Task.detached(priority: .utility) {
                (try? await cache.loadHistogram(for: file)) ?? cgImage.map { DisplayHistogram.compute(from: $0) }
            }.value
            metadata = await meta
            histogram = await hist
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

/// RGB histogram overlay with log-y scaling and a clipping marker at
/// sensorMax. 256 bins span the width; channels are additive fills.
private struct RawHistogramView: View {
    let histogram: RawHistogram

    var body: some View {
        Canvas { ctx, size in
            let binCount = RawHistogram.binCount
            guard size.width > 0, size.height > 0 else { return }
            let rawMax = histogram.bins
                .flatMap { $0 }
                .map { log10(Double($0) + 1) }
                .max() ?? 0
            let logMax = rawMax > 0 ? rawMax : 1
            func yFor(_ count: Int) -> Double {
                size.height * (1 - log10(Double(count) + 1) / logMax)
            }
            let binW = size.width / Double(binCount)
            let colors: [Color] = [.red.opacity(0.55), .green.opacity(0.55), .blue.opacity(0.55)]
            for channel in 0..<3 {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for bin in 0..<binCount {
                    let x = Double(bin) * binW
                    let y = yFor(histogram.bins[channel][bin])
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                ctx.fill(path, with: .color(colors[channel]))
            }
            if histogram.clipping.prefix(3).contains(where: { $0 > 0.001 }) {
                var line = Path()
                line.move(to: CGPoint(x: size.width - 1, y: 0))
                line.addLine(to: CGPoint(x: size.width - 1, y: size.height))
                ctx.stroke(line, with: .color(.white), lineWidth: 1)
            }
        }
        .background(.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("RAW histogram")
    }
}

/// Single-channel overall-exposure histogram, same log-y and clipping marker as RGB.
private struct RawLuminanceHistogramView: View {
    let histogram: RawHistogram
    var body: some View {
        Canvas { ctx, size in
            let binCount = RawHistogram.binCount
            guard size.width > 0, size.height > 0 else { return }
            let rawMax = histogram.luminance.map { log10(Double($0) + 1) }.max() ?? 0
            let logMax = rawMax > 0 ? rawMax : 1
            func yFor(_ count: Int) -> Double { size.height * (1 - log10(Double(count) + 1) / logMax) }
            let binW = size.width / Double(binCount)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for bin in 0..<binCount {
                let x = Double(bin) * binW
                let y = yFor(histogram.luminance[bin])
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            ctx.fill(path, with: .color(.white.opacity(0.85)))
            if histogram.clipping.count > 3 && histogram.clipping[3] > 0.001 {
                var line = Path()
                line.move(to: CGPoint(x: size.width - 1, y: 0))
                line.addLine(to: CGPoint(x: size.width - 1, y: size.height))
                ctx.stroke(line, with: .color(.white), lineWidth: 1)
            }
        }
        .background(.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("Luminance histogram")
    }
}

/// The reject-flag badge for the current photo, pinned to the image's own
/// corner so it follows the image bounds even when letterboxed.
/// Uses `FlagBadgeLogic.shouldShow` — badge belongs to photo, not container.
private struct FlagBadgeOverlay: View {
    let file: SessionFile?
    @Environment(AppState.self) private var appState

    var body: some View {
        if let file {
            let isFlagged = appState.session?.isFlagged(file) == true
            // hasImage is true here: overlay exists only on the Image branch (display or thumb), never on ProgressView
            if FlagBadgeLogic.shouldShow(isFlagged: isFlagged, hasImage: true) {
                FlagBadge(size: 44)
            }
        }
    }
}
