import SwiftUI
import QuickCullCore

/// Reusable thumbnail that enforces the badge invariant:
/// badge is overlayed on the *image* (top-trailing), never on the placeholder.
/// Use for grid and any future thumbnail surfaces. The strip's Canvas uses
/// `FlagBadgeLogic.shouldShow` directly for its single-commit optimization.
struct BadgedThumbnailView: View {
    let image: CGImage?
    let flagColor: FlagColor?
    let size: CGSize
    let badgeSize: CGFloat

    var body: some View {
        Group {
            if let image {
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .overlay {
                        Image(decorative: image, scale: 2)
                            .resizable()
                            .scaledToFit()
                            .overlay(alignment: .topTrailing) {
                                if let c = flagColor, FlagBadgeLogic.shouldShow(isFlagged: true, hasImage: true) {
                                    FlagBadge(color: c, size: badgeSize)
                                }
                            }
                    }
                    .clipped()
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
