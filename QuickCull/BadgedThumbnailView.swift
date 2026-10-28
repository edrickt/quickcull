import SwiftUI
import QuickCullCore

/// Reusable thumbnail that enforces the badge invariant:
/// badge is overlayed on the *image* (top-trailing), never on the placeholder.
/// The invariant is structural here — the badge code lives inside the
/// `if let image` branch, so a placeholder can never carry one — and
/// `FlagBadgeLogic.shouldShow` states the rule for the same inputs.
/// Use for grid and any future thumbnail surfaces.
struct BadgedThumbnailView: View {
    let image: CGImage?
    let flagColor: FlagColor?
    let size: CGSize
    let badgeSize: CGFloat
    /// Grid tiles fill their uniform cell (the spec asks for a tidy wall); the
    /// filmstrip fits whole frames so nothing is cropped in the navigation
    /// strip.
    var fills: Bool = false

    var body: some View {
        Group {
            if let image {
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .overlay {
                        Image(decorative: image, scale: 2)
                            .resizable()
                            .aspectRatio(contentMode: fills ? .fill : .fit)
                            // Pin the layout to the tile: a `.fill` image reports
                            // the covering size (taller than the tile for a
                            // portrait frame), and an overlay on that frame put
                            // the badge outside the clipped tile — a flagged
                            // portrait photo showed no badge at all.
                            .frame(width: size.width, height: size.height)
                            .overlay(alignment: .topTrailing) {
                                // `hasImage` is structurally true (we are inside
                                // `if let image`); `isFlagged` is the real input.
                                if FlagBadgeLogic.shouldShow(isFlagged: flagColor != nil, hasImage: true),
                                   let color = flagColor {
                                    FlagBadge(color: color, size: badgeSize)
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
