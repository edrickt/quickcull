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
                // Filter matches nothing (Flagged 0 or Unflagged 0) — nothing to load, show empty black instead of spinner
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
                                    let flagColor = appState.session?.flagColor(for: file)
                                    ZoomableImageView(cgImage: img, fileID: file.id, flagColor: flagColor, scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
                                } else { Color.black }
                            }.frame(width: geo.size.width, height: geo.size.height)
                        }.clipped()
                        GeometryReader { geo in
                            ZStack {
                                Color.black
                                if let img = rightCG, rightFile != nil {
                                    ZoomableImageView(cgImage: img, fileID: rightFile?.id, scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
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
                let flagColor = currentFile.flatMap { appState.session?.flagColor(for: $0) }
                HStack(spacing: 8) { // was spacing:0 with Divider() after HUD — gap via spacing 8 + Color.black
                    if hudVisible, let file = currentFile {
                        MetadataHUDView(file: file, cgImage: cgImage, cache: appState.cache).frame(width: 240).background(.ultraThinMaterial).transition(.move(edge:.leading).combined(with:.opacity))
                        // Divider() removed — gap via HStack spacing 8
                    }
                    GeometryReader { geo in
                        ZStack {
                            Color.black
                            ZoomableImageView(cgImage: cgImage, fileID: currentFile?.id, flagColor: flagColor, scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
                        }.frame(width: geo.size.width, height: geo.size.height)
                    }.clipped()
                }
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
    var flagColor: FlagColor? = nil

    @Binding var scale: CGFloat
    @Binding var lastScale: CGFloat
    @Binding var offset: CGSize
    @Binding var lastOffset: CGSize

    @Environment(AppState.self) private var appState

    @State private var globalFrame: CGRect = .zero
    @State private var scrollMonitor: Any?
    @State private var liveContainer: CGSize = .zero
    @State private var liveFitted: CGSize = .zero
    @State private var hoverLocation: CGPoint?
    @State private var isHovering: Bool = false
    @State private var isCursorHidden: Bool = false

    private let loupeDiameter: CGFloat = 280
    private let loupeOffset: CGPoint = .zero // centered over cursor per user request

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
                if let c = flagColor {
                    Color.clear
                        .frame(width: fitted.width * scale, height: fitted.height * scale)
                        .overlay(alignment: .topTrailing) {
                            FlagBadge(color: c, size: 44)
                        }
                        .offset(offset)
                        .allowsHitTesting(false)
                }

                // Loupe: 100% 1:1 magnifier lens following cursor while Space held.
                // Only at fit (scale ~1), only while hovering inside the image, not while zoomed/panned.
                if shouldShowLoupe(container: container, fitted: fitted) {
                    LoupeView(
                        cgImage: cgImage,
                        hoverLocation: hoverLocation!,
                        container: container,
                        fitted: fitted,
                        diameter: loupeDiameter,
                        offset: loupeOffset,
                        scale: scale,
                        panOffset: offset
                    )
                    .allowsHitTesting(false)
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
                }
            }
            .frame(width: container.width, height: container.height)
            .contentShape(Rectangle())
            .clipped()
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let loc):
                    hoverLocation = loc
                    isHovering = true
                case .ended:
                    isHovering = false
                    hoverLocation = nil
                @unknown default:
                    break
                }
            }
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
                syncLoupeCursor()
            }
            .onDisappear {
                removeScrollMonitor()
                if isCursorHidden {
                    NSCursor.unhide()
                    isCursorHidden = false
                }
            }
            .onChange(of: appState.isLoupeActive) { _, _ in syncLoupeCursor() }
            .onChange(of: isHovering) { _, _ in syncLoupeCursor() }
            .onChange(of: hoverLocation) { _, _ in syncLoupeCursor() }
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
                // Persist both zoom and pan across images at same magnification.
                // Keep scale/lastScale and offset/lastOffset, clamped to new image bounds
                // to avoid pushing new image out of viewport when aspect changes.
                // Thumb->display for same fileID does not trigger this.
                let newFitted = fittedSize(for: cgImage, in: liveContainer)
                let clamped = clampedOffset(offset, container: liveContainer, fitted: newFitted, scale: scale)
                if clamped != offset {
                    offset = clamped
                    lastOffset = clamped
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                if isCursorHidden { NSCursor.unhide(); isCursorHidden = false }
                Task { @MainActor in appState.setLoupeActive(false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                if isCursorHidden { NSCursor.unhide(); isCursorHidden = false }
                Task { @MainActor in appState.setLoupeActive(false) }
            }
        }
    }

    private func shouldShowLoupe(container: CGSize, fitted: CGSize) -> Bool {
        guard appState.isLoupeActive else { return false }
        guard isHovering, let loc = hoverLocation else { return false }
        guard scale <= 1.01 else { return false } // hide while zoomed; loupe is for fit inspection
        // Must be hovering over the image itself, not the letterbox
        let imageRect = imageRect(container: container, fitted: fitted)
        // When zoomed we already returned, but pan offset would shift rect; since we hide loupe when zoomed, ignore offset
        return imageRect.contains(loc)
    }

    private func imageRect(container: CGSize, fitted: CGSize) -> CGRect {
        // Image is centered in container when at fit. When zoomed we hide loupe, so no offset needed.
        CGRect(
            x: (container.width - fitted.width) / 2,
            y: (container.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private func syncLoupeCursor() {
        let shouldHide: Bool = {
            guard appState.isLoupeActive else { return false }
            guard isHovering, let loc = hoverLocation else { return false }
            guard scale <= 1.01 else { return false }
            guard liveContainer.width > 0, liveFitted.width > 0 else { return false }
            let rect = CGRect(
                x: (liveContainer.width - liveFitted.width) / 2,
                y: (liveContainer.height - liveFitted.height) / 2,
                width: liveFitted.width,
                height: liveFitted.height
            )
            return rect.contains(loc)
        }()
        setCursorHidden(shouldHide)
    }

    private func setCursorHidden(_ hidden: Bool) {
        if hidden == isCursorHidden { return }
        if hidden {
            NSCursor.hide()
            isCursorHidden = true
        } else {
            NSCursor.unhide()
            isCursorHidden = false
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
                // When loupe is active at fit, hover stops updating while mouse is down.
                // Drive loupe from drag so click-drag (no-op for pan) keeps lens glued to cursor.
                if appState.isLoupeActive && scale <= 1.01 {
                    hoverLocation = val.location
                    isHovering = true
                    return
                }
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
            .onEnded { val in
                if appState.isLoupeActive && scale <= 1.01 {
                    // Keep loupe at the final drag location so it doesn't snap back to pre-drag hover
                    hoverLocation = val.location
                    isHovering = true
                    return
                }
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

/// 100% magnifier lens that follows the cursor while Space is held.
/// Crops the displayed CGImage at 1:1 (backing-pixel aware) around the cursor's image-space coordinate.
private struct LoupeView: View {
    let cgImage: CGImage
    let hoverLocation: CGPoint
    let container: CGSize
    let fitted: CGSize
    let diameter: CGFloat
    let offset: CGPoint
    let scale: CGFloat
    let panOffset: CGSize

    var body: some View {
        GeometryReader { _ in
            let backing = NSScreen.main?.backingScaleFactor ?? 2.0
            let cropSize = diameter * backing
            let cropped: CGImage? = croppedImage(cropSize: cropSize)

            // Position lens near cursor, clamped to container so it never leaves the pane
            let lensCenter = clampedLensCenter()
            ZStack {
                if let img = cropped {
                    Image(decorative: img, scale: backing)
                        .resizable()
                        .interpolation(.none) // nearest-neighbor for true pixel view; .high would blur
                        .frame(width: diameter, height: diameter)
                        .clipped()
                } else {
                    Color.black.frame(width: diameter, height: diameter)
                }
                // crosshair for precise focus check
                Color.white.frame(width: 12, height: 0.5).opacity(0.7)
                Color.white.frame(width: 0.5, height: 12).opacity(0.7)
                // border
                Circle().stroke(Color.white.opacity(0.95), lineWidth: 2)
                Circle().stroke(Color.black.opacity(0.4), lineWidth: 0.5)
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 6)
            .overlay(
                Circle().stroke(Color.white.opacity(0.9), lineWidth: 2)
                    .shadow(color: .black.opacity(0.3), radius: 2)
            )
            .position(x: lensCenter.x, y: lensCenter.y)
            // info badge: 100% label
            .overlay(alignment: .bottom) {
                Text("100%")
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: Capsule())
                    .foregroundStyle(.white)
                    .offset(y: 16)
            }
        }
        .frame(width: container.width, height: container.height)
        .allowsHitTesting(false)
    }

    private func clampedLensCenter() -> CGPoint {
        // Center exactly over cursor; no offset, no clamping to container —
        // part of the lens may clip at the window edge, but the center stays true.
        CGPoint(x: hoverLocation.x + offset.x, y: hoverLocation.y + offset.y)
    }

    private func croppedImage(cropSize: CGFloat) -> CGImage? {
        // Image rect centered in container at fit
        let imageRect = CGRect(
            x: (container.width - fitted.width) / 2,
            y: (container.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
        // Hover relative inside image (0...1)
        let relX = (hoverLocation.x - imageRect.minX) / fitted.width
        let relY = (hoverLocation.y - imageRect.minY) / fitted.height
        // Clamp 0...1 to avoid NaN when cursor at edge due to float error
        let clampedRelX = min(max(relX, 0), 1)
        let clampedRelY = min(max(relY, 0), 1)
        let pixelX = clampedRelX * CGFloat(cgImage.width)
        let pixelY = clampedRelY * CGFloat(cgImage.height)

        var cropX = pixelX - cropSize / 2
        var cropY = pixelY - cropSize / 2
        // Clamp crop to image bounds
        cropX = min(max(cropX, 0), CGFloat(cgImage.width) - cropSize)
        cropY = min(max(cropY, 0), CGFloat(cgImage.height) - cropSize)
        // If image smaller than cropSize (tiny thumbnail before display load), just return original centered
        if cropSize > CGFloat(cgImage.width) || cropSize > CGFloat(cgImage.height) {
            return cgImage
        }
        let rect = CGRect(x: cropX, y: cropY, width: cropSize, height: cropSize)
        return cgImage.cropping(to: rect)
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
                        VStack(spacing: 2) {
                            let rClip = String(format: "%.1f%%", hist.clipping[0] * 100)
                            let gClip = String(format: "%.1f%%", hist.clipping[1] * 100)
                            let bClip = String(format: "%.1f%%", hist.clipping[2] * 100)
                            let totalR = hist.samples[0], totalG = hist.samples[1], totalB = hist.samples[2]
                            let meanR: Double = totalR > 0 ? Double(hist.bins[0].enumerated().map{ $0.element * $0.offset }.reduce(0,+)) / Double(totalR) : 0
                            let meanG: Double = totalG > 0 ? Double(hist.bins[1].enumerated().map{ $0.element * $0.offset }.reduce(0,+)) / Double(totalG) : 0
                            let meanB: Double = totalB > 0 ? Double(hist.bins[2].enumerated().map{ $0.element * $0.offset }.reduce(0,+)) / Double(totalB) : 0
                            let mean = Int((meanR + meanG + meanB) / 3 + 0.5)
                            HStack {
                                Text("R:\(rClip) G:\(gClip) B:\(bClip)")
                                Spacer()
                                Text("Mean \(mean)")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                            RawHistogramView(histogram: hist)
                                .frame(height: 72)
                        }
                        VStack(spacing: 2) {
                            let lClip = String(format: "%.1f%%", hist.clipping.count > 3 ? hist.clipping[3]*100 : 0)
                            let totalL = hist.samples.count > 3 ? hist.samples[3] : hist.luminance.reduce(0,+)
                            let meanL: Int = {
                                guard totalL > 0 else { return 0 }
                                let sum = hist.luminance.enumerated().map{ $0.element * $0.offset }.reduce(0,+)
                                return Int(Double(sum)/Double(totalL) + 0.5)
                            }()
                            HStack {
                                Text("Luma \(lClip)")
                                Spacer()
                                Text("Mean \(meanL)")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                            RawLuminanceHistogramView(histogram: hist)
                                .frame(height: 72)
                        }
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
            histogram = nil
            async let meta = Task.detached(priority: .utility) {
                // True dimensions come from the decoded cache JPEG (full-res,
                // orientation baked in) — never from the displayed CGImage,
                // which may be a 320px thumbnail or screen-limited downsample.
                let cacheURL = try? await cache.cacheURL(for: file)
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
            let rawMax = histogram.bins.flatMap{ $0 }.map{ log10(Double($0)+1) }.max() ?? 0
            let logMax = rawMax > 0 ? rawMax : 1
            func yFor(_ count: Int) -> Double { size.height * (1 - log10(Double(count)+1)/logMax) }
            let binW = size.width / Double(binCount)
            // faint axes/baseline
            var axes = Path()
            axes.move(to: CGPoint(x: 0, y: size.height))
            axes.addLine(to: CGPoint(x: size.width, y: size.height))
            axes.move(to: CGPoint(x: 0, y: 0))
            axes.addLine(to: CGPoint(x: 0, y: size.height))
            ctx.stroke(axes, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
            let colors: [Color] = [.red.opacity(0.9), .green.opacity(0.9), .blue.opacity(0.9)]
            for channel in 0..<3 {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: yFor(histogram.bins[channel][0])))
                for bin in 1..<binCount {
                    let x = Double(bin) * binW
                    let y = yFor(histogram.bins[channel][bin])
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                ctx.stroke(path, with: .color(colors[channel]), lineWidth: 1.5)
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
            let rawMax = histogram.luminance.map{ log10(Double($0)+1) }.max() ?? 0
            let logMax = rawMax > 0 ? rawMax : 1
            func yFor(_ count: Int) -> Double { size.height * (1 - log10(Double(count)+1)/logMax) }
            let binW = size.width / Double(binCount)
            var axes = Path()
            axes.move(to: CGPoint(x: 0, y: size.height))
            axes.addLine(to: CGPoint(x: size.width, y: size.height))
            axes.move(to: CGPoint(x: 0, y: 0))
            axes.addLine(to: CGPoint(x: 0, y: size.height))
            ctx.stroke(axes, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: yFor(histogram.luminance[0])))
            for bin in 1..<binCount {
                let x = Double(bin) * binW
                let y = yFor(histogram.luminance[bin])
                path.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
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
            let flagColor = appState.session?.flagColor(for: file)
            if let c = flagColor, FlagBadgeLogic.shouldShow(isFlagged: true, hasImage: true) {
                FlagBadge(color: c, size: 44)
            }
        }
    }
}
