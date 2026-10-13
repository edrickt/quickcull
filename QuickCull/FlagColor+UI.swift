import AppKit
import SwiftUI
import QuickCullCore

extension FlagColor {
    var uiColor: Color {
        switch self {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        }
    }

    /// A pre-rendered color dot for AppKit-backed controls. Segmented
    /// pickers draw their images template-style and strip SF Symbol tints,
    /// so the filter segments need a real bitmap with isTemplate = false.
    var segmentDot: Image {
        let size: CGFloat = 11
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(self.uiColor).withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image)
    }
}
