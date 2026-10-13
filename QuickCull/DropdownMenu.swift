import AppKit
import SwiftUI
import QuickCullCore

/// A pull-down menu rendered as a custom panel with click-through dismissal.
///
/// Native SwiftUI `Menu` (an AppKit `NSMenu`) consumes the first click
/// outside an open menu: the menu closes but the click never reaches the
/// control underneath, so pressing another button while the dropdown is
/// open requires a second press. This control renders its items in an
/// overlay panel instead and uses a local event monitor to close the panel
/// while letting the same click land (see `DropdownClickPolicy`) — the
/// first press activates the button underneath.
struct DropdownMenu<Label: View>: View {
    struct Item: Identifiable {
        /// The title doubles as the identity: it is unique inside a menu, and
        /// a stable id keeps `ForEach` diffing (and hover) intact across the
        /// menu's frequent parent re-renders. A fresh `UUID()` per render
        /// re-created every row instead.
        let id: String
        let title: String
        let destructive: Bool
        let disabled: Bool
        /// Optional leading SF Symbol (e.g. a flag-colored dot); `nil` reserves
        /// the icon column so rows with and without icons align.
        let icon: String?
        let iconColor: Color?
        let action: () -> Void

        init(_ title: String, destructive: Bool = false, disabled: Bool = false,
             icon: String? = nil, iconColor: Color? = nil, action: @escaping () -> Void) {
            self.id = title
            self.title = title
            self.destructive = destructive
            self.disabled = disabled
            self.icon = icon
            self.iconColor = iconColor
            self.action = action
        }
    }

    let items: [Item]
    let label: Label

    @State private var isOpen = false
    @State private var toggleFrame: CGRect = .zero // window coordinates
    /// The panel's frame is written from the AppKit layout pass and read only
    /// by the event monitor (never by `body`), so it lives in a reference box:
    /// a `@State` write there would invalidate layout for a value no layout
    /// depends on.
    @State private var panelFrameBox = FrameBox()
    @State private var windowWidth: CGFloat = 0
    @State private var monitor: Any?
    @State private var resignObserver: NSObjectProtocol?
    @State private var hoveredItemID: String?

    private final class FrameBox {
        var frame: CGRect = .zero
    }

    init(items: [Item], @ViewBuilder label: () -> Label) {
        self.items = items
        self.label = label()
    }

    var body: some View {
        Button {
            if isOpen { close() } else { open() }
        } label: {
            label
        }
        // The label carries its own visible face (ScrubView.BarIconFace);
        // the default bordered style would draw a second system bezel
        // around it.
        .buttonStyle(.plain)
        .background(FrameAnchor { frame, width in
            // Written during the AppKit layout pass. The toggle frame feeds
            // `panelXOffset`, so it does have to invalidate layout.
            toggleFrame = frame
            windowWidth = width
        })
        .overlay(alignment: .topLeading) {
            if isOpen {
                // The anchor sits INSIDE the offset chain so its report
                // includes the translation (an anchor attached after
                // .offset measures the pre-offset frame).
                panel
                    .background(FrameAnchor { frame, _ in
                        panelFrameBox.frame = frame
                    })
                    .offset(x: panelXOffset, y: toggleFrame.height + 4)
            }
        }
        .onExitCommand { close() }
        .onDisappear { removeMonitorAsync() }
    }

    /// Keeps the panel inside the window when the dropdown sits near the
    /// right edge (a panel overflowing the window would route clicks to
    /// whatever window is underneath on screen).
    private var panelXOffset: CGFloat {
        guard windowWidth > 0 else { return 0 }
        let maxLeading = max(0, windowWidth - 240 - 8)
        return min(toggleFrame.minX, maxLeading) - toggleFrame.minX
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                Button {
                    item.action()
                    close()
                } label: {
                    HStack(spacing: 8) {
                        Group {
                            if let systemImage = item.icon {
                                Image(systemName: systemImage)
                                    .font(.system(size: 10, weight: .bold))
                            } else {
                                Color.clear.frame(width: 10, height: 10)
                            }
                        }
                        .frame(width: 12)
                        .foregroundStyle(item.iconColor ?? Color.secondary)
                        Text(item.title)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .background(hoveredItemID == item.id ? Color.primary.opacity(0.09) : Color.clear)
                }
                .buttonStyle(.plain)
                .foregroundStyle(item.destructive ? Color.red : Color.primary)
                .opacity(item.disabled ? 0.4 : 1)
                .disabled(item.disabled)
                .onHover { hovering in
                    hoveredItemID = hovering ? item.id : nil
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 240, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
    }

    private func open() {
        guard !isOpen else { return }
        isOpen = true
        installMonitor()
    }

    private func close() {
        guard isOpen else { return }
        isOpen = false
        removeMonitorAsync()
    }

    /// Removing a monitor from inside its own event handler can deadlock
    /// (NSEvent.removeMonitor during event dispatch), so the removal is
    /// deferred to the next runloop turn.
    private func removeMonitorAsync() {
        if let monitor {
            self.monitor = nil
            let token = monitor
            DispatchQueue.main.async { NSEvent.removeMonitor(token) }
        }
        if let resignObserver {
            self.resignObserver = nil
            let token = resignObserver
            DispatchQueue.main.async { NotificationCenter.default.removeObserver(token) }
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            guard self.isOpen, let window = event.window else { return event }
            let click = window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
            let panel = window.convertToScreen(self.panelFrameBox.frame)
            let toggle = window.convertToScreen(self.toggleFrame)
            switch DropdownClickPolicy.classify(click: click, panel: panel, toggle: toggle) {
            case .ignore:
                return event // inside the panel: let the items handle it
            case .consume:
                self.close() // on the toggle button: close without re-opening
                return nil
            case .passThrough:
                self.close() // elsewhere: close and let the click land
                return event
            }
        }
        // A native menu closes when the app deactivates; match that.
        // (self is a value-type View struct; capturing it by value is fine —
        // the @State storage behind it is shared and the observer is always
        // removed in removeMonitor().)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { _ in
            self.close()
        }
    }
}

/// Invisible AppKit view that reports its window-coordinate frame (and the
/// window's content width) whenever the layout changes. Reporting via the
/// AppKit view tree is deterministic (unlike SwiftUI's `.global` coordinate
/// space, which can measure zero in some hosting contexts).
struct FrameAnchor: NSViewRepresentable {
    var onFrame: (CGRect, CGFloat) -> Void

    func makeNSView(context: Context) -> AnchorNSView {
        let view = AnchorNSView()
        view.onFrame = onFrame
        return view
    }

    func updateNSView(_ nsView: AnchorNSView, context: Context) {
        nsView.onFrame = onFrame
        nsView.report()
    }
}

final class AnchorNSView: NSView {
    var onFrame: (CGRect, CGFloat) -> Void = { _, _ in }

    /// The anchor exists only to report its frame; it must never intercept
    /// clicks meant for the controls underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        report()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        report()
    }

    /// Reports the frame in window coordinates (convert(to: nil)) and the
    /// window's content width.
    func report() {
        guard let window else { return }
        onFrame(convert(bounds, to: nil), window.contentView?.bounds.width ?? 0)
    }
}
