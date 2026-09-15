import SwiftUI
import QuickCullCore

/// Cell identity key for the filmstrip.
///
/// The key includes the session's flag revision (bumped on every flag
/// mutation) AND the current index — a flag or index change re-keys the
/// whole strip, so the render pass after a burst of changes re-creates
/// every cell from the final state. Cell updates that a preempted render
/// pass dropped (badges or the highlight border stuck absent/stale under
/// rapid flag toggling or scrubbing) cannot survive: the next pass
/// re-creates the affected cells from scratch. Building the key is O(1)
/// (was: sorting and joining every flagged id per render).
private func stripKey(_ file: SessionFile, flagRevision: Int, currentIndex: Int) -> String {
    file.id + "#" + String(flagRevision) + "#" + String(currentIndex)
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
        // every change and feeds `flagColor` into `BadgedThumbnailView`,
        // which pins the badge to the image itself (not the placeholder
        // container) via `FlagBadgeLogic.shouldShow`.
        let files = appState.session?.files ?? []
        let flags = appState.session?.flags ?? [:]
        let currentIndex = appState.session?.currentIndex ?? 0
        // Track which thumbnails have loaded: a badge must wait for its
        // photo — it belongs to the image, not to the placeholder box.
        let loadedImages = appState.thumbWindow?.images ?? [:]
        let flagRevision = appState.session?.flagRevision ?? 0
        let elements = files.enumerated().map { index, file in
            (key: stripKey(file, flagRevision: flagRevision, currentIndex: currentIndex),
             index: index,
             file: file,
             flagColor: flags[file.id],
             image: loadedImages[index],
             isCurrent: index == currentIndex)
        }
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 3) {
                    // Iterate the files themselves, keyed by stable file id.
                    // Never ForEach(0..<count) with array subscripts in cells:
                    // when a commit shrinks the session, lazy stacks can
                    // re-render a surviving cell with a stale range index and
                    // trap on files[index] (crash).
                    ForEach(elements, id: \.key) { element in
                        ThumbnailCell(index: element.index, file: element.file,
                                      flagColor: element.flagColor,
                                      image: element.image, isCurrent: element.isCurrent)
                        // The strip window is bounded (radius 30), so a visible
                        // cell keeps its own load queued: scrolling past the
                        // window shows a placeholder only until that cell's
                        // load lands, and memory stays bounded by the window.
                        .task(id: element.index) {
                            appState.thumbWindow?.ensureLoaded(indices: [element.index])
                        }
                    }
                }
                .padding(6)
            }
            .frame(height: 102) // was 86; adds room for caption (64 thumb + 3 spacing + ~13 caption + 12 padding)
            .background(.thinMaterial)
            .onChange(of: appState.session?.currentIndex) {
                // scrollTo must target the ForEach's identity (the strip
                // key), not the integer index: cells are keyed by file id so
                // a commit-shrunk session can't re-render a stale index
                // (crash), and the key carries the flag revision.
                guard let session = appState.session,
                      session.files.indices.contains(session.currentIndex) else { return }
                let file = session.files[session.currentIndex]
                let key = stripKey(file, flagRevision: session.flagRevision,
                                   currentIndex: session.currentIndex)
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

struct ThumbnailCell: View {
    let index: Int
    let file: SessionFile
    let flagColor: FlagColor?
    let image: CGImage?
    let isCurrent: Bool
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 3) {
            BadgedThumbnailView(
                image: image,
                flagColor: flagColor,
                size: CGSize(width: 100, height: 64),
                badgeSize: 24
            )
            .overlay(
                Rectangle().strokeBorder(
                    isCurrent ? Color.accentColor : .clear,
                    lineWidth: 2)
            )
            Text(file.url.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 100, alignment: .center)
                .help(file.url.lastPathComponent)
        }
        .contentShape(Rectangle())
        .onTapGesture { appState.setCurrentIndex(index) }
        .help(file.url.lastPathComponent) // tooltip when hovering thumb as well
    }
}
