import SwiftUI
import QuickCullCore

/// Reusable thumbnail that enforces the badge invariant:
/// badge is overlayed on the *image* (top-trailing), never on the placeholder.
/// Use for grid and any future thumbnail surfaces. The strip's Canvas uses
/// `FlagBadgeLogic.shouldShow` directly for its single-commit optimization.
struct BadgedThumbnailView: View {
    let image: CGImage?
    let isFlagged: Bool
    let size: CGSize
    let badgeSize: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        if FlagBadgeLogic.shouldShow(isFlagged: isFlagged, hasImage: true) {
                            FlagBadge(size: badgeSize)
                                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                        }
                    }
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}
