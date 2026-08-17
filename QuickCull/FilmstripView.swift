import SwiftUI
import QuickCullCore

/// Cell identity key for the filmstrip.
///
/// The key includes the FULL flag state (every flagged id plus the current
/// index), not just this cell's own flag: a flag or index change re-keys
/// the whole strip, so the render pass after a burst of changes re-creates
/// every cell from the final state. Cell updates that a preempted render
/// pass dropped (badges stuck absent under rapid flag toggling) cannot
/// survive: the next pass re-creates the affected cells from scratch.
private func stripKey(_ file: SessionFile, flagVersion: String) -> String {
    file.id + "#" + flagVersion
}

struct FilmstripView: View {
    @Environment(AppState.self) private var appState
    /// Last time the strip scrolled. Used to skip the scroll animation while
    /// the user is scrubbing rapidly: an animated scroll (~0.25 s) can't
    /// keep up with key repeat (~50-150 ms), so every new animation restarts
    /// mid-flight and the strip permanently trails the active index.
    @State private var lastScrollAt = Date.distantPast

    var body: some View {
        // Read the flag set and index HERE, in the parent's body, not inside
        // the ForEach closure: reads in the lazy content closure are
        // attributed to the cell views, whose in-place updates can be
        // dropped by a preempted render pass (badges stuck absent while the
        // viewer updates). A parent-body read re-keys the whole strip on
        // every change AND re-feeds the badge canvas, which redraws every
        // badge in a single view from the final state.
        let files = appState.session?.files ?? []
        let flagged = appState.session?.flagged ?? []
        let currentIndex = appState.session?.currentIndex ?? 0
        // Track which thumbnails have loaded: a badge must wait for its
        // photo — it belongs to the image, not to the placeholder box.
        let loadedImages = appState.thumbWindow?.images ?? [:]
        let flagVersion = flagged.sorted().joined(separator: ",") + "|\(currentIndex)"
        let elements = files.enumerated().map { index, file in
            (key: stripKey(file, flagVersion: flagVersion),
             index: index,
             file: file,
             isFlagged: flagged.contains(file.id),
             hasImage: loadedImages[index] != nil)
        }
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                // The badges live in a single Canvas layered over the cells
                // (not inside each cell): a per-cell conditional view's
                // commit can be dropped by a preempted render pass under
                // rapid flag toggling, leaving some badges stuck absent.
                // One canvas view redraws ALL badges from the current data
                // in a single commit — nothing to drop.
                //
                // A badge draws only for a cell that HAS its image: the
                // badge belongs to the photo, never to the empty
                // placeholder box it will land on.
                ZStack(alignment: .topLeading) {
                    LazyHStack(spacing: 3) {
                        // Iterate the files themselves, keyed by stable file id.
                        // Never ForEach(0..<count) with array subscripts in cells:
                        // when a commit shrinks the session, lazy stacks can
                        // re-render a surviving cell with a stale range index and
                        // trap on files[index] (crash).
                        ForEach(elements, id: \.key) { element in
                            ThumbnailCell(index: element.index, file: element.file)
                        }
                    }
                    .padding(6)
                    FlagBadgeCanvas(elements: elements)
                }
            }
            .frame(height: 86)
            .background(.thinMaterial)
            .onChange(of: appState.session?.currentIndex) {
                // scrollTo must target the ForEach's identity (the strip
                // key), not the integer index: cells are keyed by file id so
                // a commit-shrunk session can't re-render a stale index
                // (crash), and the key carries the current flag state.
                guard let session = appState.session,
                      session.files.indices.contains(session.currentIndex) else { return }
                let file = session.files[session.currentIndex]
                let version = session.flagged.sorted().joined(separator: ",") + "|\(session.currentIndex)"
                let key = stripKey(file, flagVersion: version)
                let now = Date()
                let scrubbing = now.timeIntervalSince(lastScrollAt) < 0.15
                lastScrollAt = now
                if scrubbing {
                    // Rapid succession (key repeat): jump instantly so the
                    // center cell is always the active one.
                    proxy.scrollTo(key, anchor: .center)
                } else {
                    // Deliberate step/jump after a pause: smooth glide.
                    withAnimation(.snappy) { proxy.scrollTo(key, anchor: .center) }
                }
            }
        }
    }
}

/// Draws every reject-flag badge for the strip in ONE view.
///
/// One Canvas = one render commit per state change, so a badge can never
/// be left stale by a partially-applied update. It sits inside the scroll
/// content, layered over the cells, so it scrolls with them. Badge
/// positions mirror the cell layout (100 pt cells, 3 pt spacing, 6 pt
/// padding, 24 pt badge in each cell's top-right corner).
private struct FlagBadgeCanvas: View {
    let elements: [(key: String, index: Int, file: SessionFile, isFlagged: Bool, hasImage: Bool)]

    var body: some View {
        Canvas { context, size in
            // The badge belongs to the photo: draw it only for a flagged
            // cell whose image has actually loaded, so it never sits on
            // the empty placeholder box (the container).
            for element in elements where element.isFlagged && element.hasImage {
                let x = CGFloat(6 + element.index * 103 + 76)
                let y = CGFloat(6)
                let rect = CGRect(x: x, y: y, width: 24, height: 24)
                // Subtle shadow, mirroring FlagBadge.
                var shadow = context
                shadow.translateBy(x: 0, y: 0.5)
                shadow.fill(trianglePath(in: rect), with: .color(.black.opacity(0.35)))
                context.fill(trianglePath(in: rect), with: .color(.red))
            }
        }
    }

    /// Right isosceles triangle covering the top-right corner (same shape
    /// as the view's CornerTriangle).
    private func trianglePath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct ThumbnailCell: View {
    let index: Int
    let file: SessionFile
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = appState.thumbWindow?.image(at: index) {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 100, height: 64)
        .clipped()
        .overlay(
            Rectangle().strokeBorder(
                index == appState.session?.currentIndex ? Color.accentColor : .clear,
                lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { appState.setCurrentIndex(index) }
    }
}
