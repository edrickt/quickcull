import SwiftUI
import QuickCullCore

struct FlagBadge: View {
    var color: FlagColor
    var size: CGFloat = 32

    var body: some View {
        CornerTriangle().fill(color.uiColor)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
    }
}

/// Right isosceles triangle covering the top-right corner of its frame.
fileprivate struct CornerTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
