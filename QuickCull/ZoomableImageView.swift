import SwiftUI
import QuickCullCore
#if canImport(AppKit)
import AppKit
#endif

/// Zoomable container for the main viewer image.
/// - Pinch (trackpad) scales 1x…4x.
/// - Double-click toggles fit (1x) ↔ 200% (2x). Any zoomed state double-click unzooms.
/// - Drag pans when zoomed (mouse drag + trackpad two-finger scroll), clamped so the image never leaves the viewport.
struct ZoomableImageView: View {
    let cgImage: CGImage
    let fileID: String?
    var flagColor: FlagColor? = nil
    /// Whether `cgImage` carries source pixels (`ImageWindow.isFullResolution`).
    /// The loupe labels itself honestly when it does not.
    var hasSourcePixels: Bool = true

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
                    .offset(renderOffset)
                if let c = flagColor {
                    // Pinned to the pane's corner, not to the scaled image frame:
                    // at 2x the image's own corner is outside the clipped
                    // viewport, so the flag indicator vanished exactly while the
                    // user was inspecting detail.
                    FlagBadge(color: c, size: 28)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .allowsHitTesting(false)
                }

                // Loupe: 100% 1:1 magnifier lens following cursor while Space held.
                // Only at fit (scale ~1), only while hovering inside the image, not while zoomed/panned.
                // The display window decodes at full resolution (ImageWindow.display),
                // so the crop below is true source-pixel 1:1 at any image size.
                if shouldShowLoupe(container: container, fitted: fitted) {
                    LoupeView(
                        cgImage: cgImage,
                        hoverLocation: hoverLocation!,
                        container: container,
                        fitted: fitted,
                        diameter: loupeDiameter,
                        offset: loupeOffset,
                        scale: scale,
                        panOffset: renderOffset,
                        hasSourcePixels: hasSourcePixels
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
            // `globalFrame` is in SwiftUI's window-relative `.global` space while
            // `NSEvent.mouseLocation` is screen-space, so the two must be bridged
            // through the window frame (see WindowHitTest) — comparing them
            // directly made pan depend on the window's position on screen.
            let gf = frameBinding.wrappedValue
            let mouse = NSEvent.mouseLocation
            if !gf.isEmpty {
                guard let window = event.window ?? NSApp.keyWindow else { return event }
                guard WindowHitTest.contains(screenPoint: mouse,
                                             windowFrame: window.frame,
                                             paneGlobalFrame: gf) else { return event }
            }
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

    /// Split binds one pan offset into both panes, but each pane has its own
    /// aspect ratio and therefore its own limits. Clamp against this pane's own
    /// geometry at render time, so a portrait neighbour cannot be dragged half
    /// out of its viewport by a pan the landscape pane needed.
    private var renderOffset: CGSize {
        clampedOffset(offset, container: liveContainer, fitted: liveFitted, scale: scale)
    }
}

/// 100% magnifier lens that follows the cursor while Space is held.
/// Crops the displayed CGImage at 1:1 (backing-pixel aware) around the
/// cursor's image-space coordinate. The display CGImage is the full-res
/// decode (ImageWindow.display has no downsample cap), so this is genuine
/// source-pixel 1:1 — the "100%" badge is exact at any image size.
private struct LoupeView: View {
    @Environment(\.displayScale) private var displayScale
    let cgImage: CGImage
    let hoverLocation: CGPoint
    let container: CGSize
    let fitted: CGSize
    let diameter: CGFloat
    let offset: CGPoint
    let scale: CGFloat
    let panOffset: CGSize
    /// False while the pane holds a half-size placeholder or a 320px filmstrip
    /// thumbnail: the lens then magnifies whatever it has, and must not claim
    /// source-pixel 1:1 while doing it.
    let hasSourcePixels: Bool

    var body: some View {
        GeometryReader { _ in
            // The pane's own backing scale, not the main screen's: on a
            // secondary display of a different scale the lens was sampling the
            // wrong number of source pixels and was not 1:1.
            let backing = displayScale
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
            // info badge: the real ratio, not a claim
            .overlay(alignment: .bottom) {
                Text(hasSourcePixels ? "100%" : "preview")
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
