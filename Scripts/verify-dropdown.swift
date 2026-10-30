#!/usr/bin/env swift
// verify-dropdown.swift — E2E mechanics test for DropdownMenu's click-through
// dismissal.
//
// Bug: with a native SwiftUI Menu (NSMenu), the first click outside the open
// menu closes it but is consumed by the menu tracking loop, so pressing
// another button requires a second press.
//
// Fix: DropdownMenu renders its items in an overlay panel and closes via a
// local event monitor that lets the same click land (DropdownClickPolicy).
//
// This script drives a real NSWindow with REAL system mouse events
// (CGEventPost — synthetic NSApp.sendEvent events do not satisfy SwiftUI's
// gesture tracking), then asserts:
//   1. clicking the toggle opens the panel,
//   2. clicking a target button while the panel is open activates the target
//      on the FIRST press (the fix) and closes the panel,
//   3. clicking the toggle again while open closes it without re-opening,
//   4. clicking a panel item runs the item action and closes the panel,
//   5. a plain click elsewhere closes the panel without side effects.
//
// The DropdownMenu view itself lives in the app target, so this script
// mirrors its structure (button + overlay panel + monitor + policy) and
// links the REAL DropdownClickPolicy from QuickCullCore.
//
// Note: the test window appears briefly on screen (real events need the
// window on the display), and the harness app activates itself for the few
// seconds it runs.
//
// Usage:
//   swiftc -Xfrontend -disable-sandbox -module-cache-path /tmp/modulecache \
//     -Xcc -IBuild/libraw/include -F Build/Release/Build/Products/Release \
//     -framework QuickCullCore -o /tmp/verify-dropdown Scripts/verify-dropdown.swift
//   DYLD_FRAMEWORK_PATH=Build/Release/Build/Products/Release /tmp/verify-dropdown
import AppKit
import SwiftUI
import QuickCullCore
import Darwin

setvbuf(stdout, nil, _IONBF, 0) // unbuffered: output survives a hard kill

let _ = NSApplication.shared
NSApp.setActivationPolicy(.accessory) // no dock icon for the test window

// ---- mirror of DropdownMenu (app target) ----
struct TestDropdown: View {
    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let action: () -> Void
    }
    let items: [Item]
    @State private var isOpen = false
    @State private var toggleFrame: CGRect = .zero // window coords
    @State private var panelFrame: CGRect = .zero  // window coords
    @State private var windowWidth: CGFloat = 0
    @State private var monitor: Any?

    var body: some View {
        Button { if isOpen { close() } else { open() } } label: { Text("Toggle") }
            .background(FrameAnchor { frame, width in
                toggleFrame = frame
                windowWidth = width
            })
            .overlay(alignment: .topLeading) {
                if isOpen {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            Button { item.action(); close() } label: {
                                Text(item.title).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 200, alignment: .leading)
                    .background(.regularMaterial)
                    .background(FrameAnchor { frame, _ in panelFrame = frame })
                    .offset(x: panelXOffset, y: toggleFrame.height + 4)
                }
            }
    }

    private var panelXOffset: CGFloat {
        guard windowWidth > 0 else { return 0 }
        let maxLeading = max(0, windowWidth - 200 - 8)
        return min(toggleFrame.minX, maxLeading) - toggleFrame.minX
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
    // Removing a monitor from inside its own handler can deadlock; defer.
    private func removeMonitorAsync() {
        if let monitor {
            self.monitor = nil
            let token = monitor
            DispatchQueue.main.async { NSEvent.removeMonitor(token) }
        }
    }
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard self.isOpen, let window = event.window else { return event }
            let click = window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
            let panel = window.convertToScreen(self.panelFrame)
            let toggle = window.convertToScreen(self.toggleFrame)
            switch DropdownClickPolicy.classify(click: click, panel: panel, toggle: toggle) {
            case .ignore: return event
            case .consume: self.close(); return nil
            case .passThrough: self.close(); return event
            }
        }
    }
}

/// Mirror of the production FrameAnchor (AppKit view reporting its
/// window-coordinate frame).
struct FrameAnchor: NSViewRepresentable {
    var onFrame: (CGRect, CGFloat) -> Void
    func makeNSView(context: Context) -> AnchorNSView {
        let v = AnchorNSView()
        v.onFrame = onFrame
        return v
    }
    func updateNSView(_ nsView: AnchorNSView, context: Context) {
        nsView.onFrame = onFrame
        nsView.report()
    }
}
final class AnchorNSView: NSView {
    var onFrame: (CGRect, CGFloat) -> Void = { _, _ in }
    // The anchor must never intercept clicks meant for the controls under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        report()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        report()
    }
    func report() {
        guard let window else { return }
        onFrame(convert(bounds, to: nil), window.contentView?.bounds.width ?? 0)
    }
}

// ---- harness ----
final class Harness {
    private final class Counter { var value = 0 }

    let window: NSWindow
    let hosting: NSHostingView<AnyView>
    private let screen: NSRect
    private let counter: Counter
    private let targetCounter: Counter
    var targetClicks: Int { targetCounter.value }
    var itemActions: Int { counter.value }

    init() {
        let counter = Counter()
        let targetCounter = Counter()
        screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        // Target sits LEFT of the dropdown (as in the real single-row bar)
        // so the open panel below the dropdown never covers it.
        hosting = NSHostingView(rootView: AnyView(VStack(spacing: 0) {
            HStack(spacing: 40) {
                Button("Target") { targetCounter.value += 1 }
                Spacer()
                TestDropdown(items: [
                    .init(title: "Move R (12)") { counter.value += 1 },
                    .init(title: "Move All Flagged (12)") { counter.value += 1 },
                ])
            }
            .padding(20)
            Spacer(minLength: 0)
        }))
        window.contentView = hosting
        self.counter = counter
        self.targetCounter = targetCounter
        // Top-right corner of the main screen; the window stays frontmost
        // only for the few seconds the test runs.
        window.setFrameOrigin(NSPoint(x: screen.maxX - 720, y: screen.maxY - 540))
        window.orderFront(nil)
        window.makeKey()
        // Without activation the window stays behind the active app and the
        // window server routes posted clicks to whatever is on top instead.
        // Activation is asynchronous: wait until the window is really key
        // before any click, or the first posted click can be lost.
        NSApp.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(3.0)
        while !window.isKeyWindow && Date() < deadline { pump(0.1) }
        pump(0.3)
    }

    func pump(_ seconds: Double = 0.15) {
        // A CLI app has no NSApplicationMain, so the main runloop never
        // drains the app event queue on its own — pump it manually so
        // posted events reach sendEvent (and the local monitor).
        let deadline = Date().addingTimeInterval(seconds)
        while let event = NSApp.nextEvent(matching: .any, until: deadline,
                                          inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        hosting.layoutSubtreeIfNeeded()
    }

    /// Quartz (top-left origin) screen point for a window-coordinate point.
    func quartzPoint(_ windowPoint: CGPoint) -> CGPoint {
        let screenPoint = window.convertToScreen(NSRect(origin: windowPoint, size: .zero)).origin
        return CGPoint(x: screenPoint.x, y: screen.maxY - screenPoint.y)
    }

    func click(atWindowPoint p: CGPoint) {
        let q = quartzPoint(p)
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                           mouseCursorPosition: q, mouseButton: .left)!
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                         mouseCursorPosition: q, mouseButton: .left)!
        down.post(tap: .cghidEventTap)
        usleep(120_000)
        up.post(tap: .cghidEventTap)
        pump(0.25)
    }

    /// SwiftUI buttons render as views whose class name contains "FocusRing".
    func clickableViews() -> [NSView] {
        var out: [NSView] = []
        func walk(_ v: NSView) {
            let name = String(describing: type(of: v))
            if v is NSButton || name.contains("FocusRing") { out.append(v) }
            for s in v.subviews { walk(s) }
        }
        walk(hosting)
        return out
    }

    /// Window-coordinate center of a view.
    func center(of view: NSView) -> CGPoint {
        let r = view.convert(view.bounds, to: nil)
        return CGPoint(x: r.midX, y: r.midY)
    }

    /// The toggle sits on the right of the row; panel items are wide.
    var toggle: NSView {
        clickableViews().first { v in
            !(v is NSButton) && v.frame.width < 100 && v.frame.minX > 500
        }!
    }

    /// The target button sits on the left of the row.
    var target: NSView {
        clickableViews().first { v in
            !(v is NSButton) && v.frame.width < 100 && v.frame.minX < 200
        }!
    }

    /// The panel's frame anchor (reports correct window coords; the item
    /// focus rings sit in a pre-offset space and cannot be clicked by frame).
    var panelAnchor: NSView? {
        var found: NSView?
        func walk(_ v: NSView) {
            if String(describing: type(of: v)) == "AnchorNSView", v.frame.width > 100 { found = v }
            for s in v.subviews { walk(s) }
        }
        walk(hosting)
        return found
    }

    func panelIsVisible() -> Bool { panelAnchor != nil }

    /// Window-coordinate center of panel item `index` (0 = top item),
    /// derived from the panel anchor's frame.
    func itemPoint(_ index: Int) -> CGPoint {
        let f = panelAnchor!.convert(panelAnchor!.bounds, to: nil)
        let itemHeight = f.height / 2 // two items
        return CGPoint(x: f.midX, y: f.maxY - itemHeight * (CGFloat(index) + 0.5))
    }
}

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL"): \(name)")
    if !ok { failures += 1 }
}

let h = Harness()

// Warm-up: the first posted click can be swallowed by window activation.
h.click(atWindowPoint: CGPoint(x: 60, y: 60))

// 1. click toggle -> panel opens
h.click(atWindowPoint: h.center(of: h.toggle))
check("clicking the toggle opens the panel", h.panelIsVisible())

// 2. click target while panel open -> FIRST press activates target + closes panel
let before = h.targetClicks
h.click(atWindowPoint: h.center(of: h.target))
check("first press on another button activates it (click-through)", h.targetClicks == before + 1)
check("panel closed after pass-through click", !h.panelIsVisible())

// 3. open again, click toggle -> closes without re-opening
h.click(atWindowPoint: h.center(of: h.toggle))
check("reopened", h.panelIsVisible())
h.click(atWindowPoint: h.center(of: h.toggle))
check("clicking the toggle closes the panel", !h.panelIsVisible())
check("toggle click did not re-open the panel (consumed)", !h.panelIsVisible())

// 4. open, click an item -> item action runs, panel closes
let beforeItems = h.itemActions
h.click(atWindowPoint: h.center(of: h.toggle))
h.click(atWindowPoint: h.itemPoint(1))
check("panel item action ran", h.itemActions == beforeItems + 1)
check("panel closed after item selection", !h.panelIsVisible())

// 5. open, click empty space -> closes, nothing else fires
let before2 = h.targetClicks
h.click(atWindowPoint: h.center(of: h.toggle))
h.click(atWindowPoint: CGPoint(x: 620, y: 60))
check("click on empty space closes the panel", !h.panelIsVisible())
check("empty-space click did not hit the target", h.targetClicks == before2)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
