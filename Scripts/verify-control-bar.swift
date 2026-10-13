#!/usr/bin/env swift
// verify-control-bar.swift — regression check for the control bar legibility
// bug ("when the window is small enough, the buttons are illegible").
//
// The app's minimum window width is 900pt (QuickCullApp.swift). The control
// bar in ScrubView must render every control at its intrinsic size inside
// that width: if the bar overflows, SwiftUI crushes the text buttons into
// slivers (segmented pickers refuse to compress) and clips the trailing
// button off-window — the illegibility bug.
//
// This script mirrors the bar's structure (ScrubView.controlBar) with real
// AppKit-backed SwiftUI controls and asserts:
//   1. nothing is rendered compressed (frame width < intrinsic width),
//   2. nothing is clipped (frame outside the 900pt content area),
// when the bar is laid out at 900pt using the production layout structure.
//
// Usage:
//   swift Scripts/verify-control-bar.swift
//
// In sandboxed environments (e.g. the DSH harness) the Swift compiler needs
// its sandbox disabled and a writable module cache:
//   swift -Xfrontend -disable-sandbox -module-cache-path /tmp/modulecache Scripts/verify-control-bar.swift
import AppKit
import SwiftUI

let _ = NSApplication.shared

// Mirror of ScrubView.controlBar content. Keep in sync with ScrubView.swift.
enum BarContent {
    static func viewPicker() -> some View {
        Picker("View", selection: .constant(0)) {
            Text("Single").tag(0)
            Text("Split").tag(1)
            Text("Grid").tag(2)
        }
        .pickerStyle(.segmented)
    }
    // Multi-select filter segments (mirror of ScrubView.filterPicker —
    // keep in sync): plain buttons in an HStack inside a quaternary-filled
    // group, with the same padding and 24pt control height as production.
    static func filterPicker() -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { _ in
                Button(action: {}) {
                    Text("All")
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .frame(minHeight: 20)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
    }
    // Metadata toggle sits at the end of the pickers group (ScrubView.metadataButton).
    // Single-icon buttons carry a BarIconFace: quaternary rounded rect at
    // the shared 24pt control height.
    static func metadataButton() -> some View {
        Button(action: {}) {
            Image(systemName: "info.circle")
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    @ViewBuilder
    static func actions() -> some View {
        Button {} label: {
            Image(systemName: "trash")
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Button {} label: {
            Image(systemName: "folder")
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// THE PRODUCTION LAYOUT STRUCTURE.
// v1 (pre-fix): the single-row bar exactly as ScrubView builds it today.
// v2 (post-fix): ViewThatFits with a two-row fallback (pickers / actions).
// This is the line to change when the layout structure in ScrubView changes.
struct ControlBarLayout: View {
    var body: some View {
        // POST-FIX: ViewThatFits shows the one-row bar when it fits and
        // falls back to a two-row bar (pickers / actions) at narrow widths.
        // Each candidate fixes its own height (padding inside) so the bar
        // never stretches vertically in the enclosing VStack.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                BarContent.viewPicker()
                BarContent.filterPicker()
                BarContent.metadataButton()
                Spacer()
                BarContent.actions()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(height: 40)
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    BarContent.viewPicker()
                    BarContent.filterPicker()
                    BarContent.metadataButton()
                    Spacer()
                }
                HStack(spacing: 12) {
                    BarContent.actions()
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(height: 72)
        }
    }
}

// The bar always sits at the top of ScrubView's VStack
// (VStack(spacing:0){…}.frame(maxHeight:.infinity, alignment:.top)).
// Mirror that context so the vertical assertion matches the real app.
struct AppContext: View {
    var body: some View {
        VStack(spacing: 0) {
            ControlBarLayout()
            Divider()
            Color.gray
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

let minWindowWidth: CGFloat = 900 // QuickCullApp.swift .frame(minWidth:)
let referenceWidth: CGFloat = 1600 // wide enough that nothing ever compresses

// Collect the widths, vertical extent, and leftmost position of every
// control-like view (segmented pickers render as NSSegmentedControl;
// SwiftUI buttons/menus render as _FocusRingView).
func controls(in root: NSView) -> [(width: CGFloat, maxY: CGFloat, minX: CGFloat, isButton: Bool)] {
    var out: [(width: CGFloat, maxY: CGFloat, minX: CGFloat, isButton: Bool)] = []
    func walk(_ v: NSView) {
        let name = String(describing: type(of: v))
        if v is NSControl || name.contains("FocusRing") {
            out.append((v.frame.width, v.frame.maxY, v.frame.minX, name.contains("FocusRing")))
        }
        for s in v.subviews { walk(s) }
    }
    walk(root)
    return out
}

func isClipped(_ root: NSView, width: CGFloat) -> Bool {
    var clipped = false
    func walk(_ v: NSView) {
        let f = v.frame
        if f.width > 0 && (f.maxX > width + 0.5 || f.minX < -0.5) {
            clipped = true
            print("  FAIL: \(String(describing: type(of: v))) frame=\(f) is outside the \(Int(width))pt content area")
        }
        for s in v.subviews { walk(s) }
    }
    walk(root)
    return clipped
}

func render<V: View>(_ view: V, width: CGFloat, height: CGFloat = 700) -> NSView {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    return host
}

// Render the layout at the minimum window width and at a wide reference
// width, then assert:
//   1. the same set of control widths appears in both (nothing compressed
//      at 900pt),
//   2. nothing is clipped horizontally,
//   3. the bar keeps its natural height (maxY within the one-row 40pt /
//      two-row 72pt frames) — i.e. the enclosing VStack does not stretch
//      it, which would float the controls with empty space around them.
let narrowHost = render(AppContext(), width: minWindowWidth)
let wideHost = render(AppContext(), width: referenceWidth)

let narrow = controls(in: narrowHost)
let wide = controls(in: wideHost)

var failures = 0
if narrow.count != wide.count {
    print("FAIL: control count differs at \(Int(minWindowWidth))pt (\(narrow.count)) vs \(Int(referenceWidth))pt (\(wide.count))")
    failures += 1
} else {
    for (n, w) in zip(narrow.map(\.width).sorted(), wide.map(\.width).sorted()) where abs(n - w) > 1 {
        print("FAIL: control \(String(format: "%.0f", n))pt wide at \(Int(minWindowWidth))pt vs \(String(format: "%.0f", w))pt at \(Int(referenceWidth))pt — compressed")
        failures += 1
    }
}
let narrowMaxY = narrow.map(\.maxY).max() ?? 0
let wideMaxY = wide.map(\.maxY).max() ?? 0
let twoRowBarHeight: CGFloat = 76 // 72pt frame + focus-ring slack
let oneRowBarHeight: CGFloat = 48 // 40pt frame + focus-ring slack
if narrowMaxY > twoRowBarHeight {
    print("FAIL: bar content reaches y=\(String(format: "%.0f", narrowMaxY)) at \(Int(minWindowWidth))pt — bar is being stretched vertically")
    failures += 1
}
if wideMaxY > oneRowBarHeight {
    print("FAIL: bar content reaches y=\(String(format: "%.0f", wideMaxY)) at \(Int(referenceWidth))pt — expected the one-row bar, but content is taller (two-row variant selected?)")
    failures += 1
}
// In the two-row bar at 900pt the action buttons must be anchored left,
// aligned under the pickers (minX at the padding edge, not pushed right).
// Only applies when the two-row variant is actually selected: with the
// icon-based buttons the one-row bar usually fits at 900pt (actions then
// sit right of the Spacer by design).
let twoRowSelected = narrowMaxY > oneRowBarHeight
if twoRowSelected {
    let narrowButtons = narrow.filter(\.isButton)
    if let leftmostButton = narrowButtons.map(\.minX).min(), leftmostButton > 40 {
        print("FAIL: leftmost action button starts at x=\(String(format: "%.0f", leftmostButton)) at \(Int(minWindowWidth))pt — action row is not left-anchored")
        failures += 1
    }
}
if isClipped(narrowHost, width: minWindowWidth) { failures += 1 }

if failures == 0 {
    print("PASS: every control in the control bar renders at intrinsic size inside \(Int(minWindowWidth))pt")
    exit(0)
} else {
    print("FAIL: control bar is compressed or clipped at \(Int(minWindowWidth))pt (the illegibility bug)")
    exit(1)
}
