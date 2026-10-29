import SwiftUI
import CoreGraphics
import QuickCullCore
#if canImport(AppKit)
import AppKit
#endif

struct GridView: View {
    @Environment(AppState.self) private var appState
    /// Files the lazy grid currently has on screen, reported to the window as a
    /// set. Identity-keyed so a filter change or commit that renumbers the
    /// projection cannot leave stale positions in the viewport. A reference box,
    /// not `@State`: reporting it must not invalidate the body, which would
    /// rebuild the whole element array on every cell that appears.
    @State private var viewport = ViewportBox()

    private final class ViewportBox {
        private(set) var ids: Set<String> = []
        /// True when the id was not already present (the caller reports only then).
        @discardableResult
        func insert(_ id: String) -> Bool { ids.insert(id).inserted }
        @discardableResult
        func remove(_ id: String) -> Bool { ids.remove(id) != nil }
    }

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 8)]

    var body: some View {
        // Parent-body reads: avoid per-cell observation that makes LazyVGrid re-evaluate 500 cells on every gridSelection change.
        // Mirrors FilmstripView's stripKey/elements pattern for fast scrub.
        // The grid window is bounded by the viewport the cells report below
        // (`setViewport`), not by a fixed count: a fixed cap smaller than the
        // viewport evicted visible tiles, and a cell whose task had already run
        // never requested its thumbnail again.
        let files = appState.session?.files ?? []
        let gridSelection = appState.gridSelection
        let flags = appState.session?.flags ?? [:]
        let thumbImages = appState.gridThumbs?.images ?? [:]
        if files.isEmpty {
            ZStack { Color.black; Text("No photos in this filter").foregroundStyle(.secondary) }
        } else {
            // Compute once per body evaluation; GridCell receives plain values, not @Environment reads.
            let currentIndex = appState.session?.currentIndex ?? 0
            let currentID = files.indices.contains(currentIndex) ? files[currentIndex].id : nil
            let elements: [(index: Int, file: SessionFile, isSelected: Bool, flagColor: FlagColor?, image: CGImage?)] = files.enumerated().map { idx, file in
                (index: idx,
                 file: file,
                 isSelected: gridSelection.contains(file.id),
                 flagColor: flags[file.id],
                 image: thumbImages[idx])
            }
            ScrollViewReader { proxy in
                ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(elements, id: \.file.id) { element in
                        GridCell(
                            index: element.index,
                            file: element.file,
                            isSelected: element.isSelected,
                            flagColor: element.flagColor,
                            image: element.image
                        )
                        .onAppear {
                            guard viewport.insert(element.file.id) else { return }
                            appState.gridThumbs?.setViewport(ids: viewport.ids)
                        }
                        .onDisappear {
                            guard viewport.remove(element.file.id) else { return }
                            appState.gridThumbs?.setViewport(ids: viewport.ids)
                        }
                        .onTapGesture {
#if canImport(AppKit)
                            let event = NSApp.currentEvent
                            let clickCount = event?.clickCount ?? 1
                            if clickCount == 2 {
                                appState.handleGridDoubleClick(id: element.file.id)
                            } else {
                                let flags = event?.modifierFlags ?? NSEvent.modifierFlags
                                appState.handleGridTap(id: element.file.id,
                                                       isCmd: flags.contains(.command),
                                                       isShift: flags.contains(.shift))
                            }
#else
                            appState.handleGridTap(id: element.file.id, isCmd: false, isShift: false)
#endif
                        }
                        // A grid cell is a button: VoiceOver must be able to
                        // select it (the only route to batch flagging) and to
                        // open it in Single, neither of which a mouse-only tap
                        // handler exposes.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(element.file.url.lastPathComponent)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(element.isSelected ? .isSelected : [])
                        .accessibilityAction {
                            appState.handleGridTap(id: element.file.id, isCmd: false, isShift: false)
                        }
                        .accessibilityAction(named: "Open in Single") {
                            appState.handleGridDoubleClick(id: element.file.id)
                        }
                    }
                }
                .padding(12)
                }
                // Entering grid opens at the shoot's start with no mark for where
                // the user was (QA-40): scroll to the current photo on appear so
                // the position scrub left off is on screen, mirroring the
                // filmstrip's appear-scroll. No @State for the target: the
                // session owns the current index.
                .task(id: currentID) {
                    if let currentID { proxy.scrollTo(currentID, anchor: .center) }
                }
            }
            .background(Color.black.opacity(0.04))
        }
    }
}

private struct GridCell: View {
    let index: Int; let file: SessionFile; let isSelected: Bool; let flagColor: FlagColor?; let image: CGImage?
    var body: some View {
        VStack(spacing: 4) {
            // Fill the cell so a portrait frame does not leave a ragged column:
            // every tile is the same 160x108 window onto its photo.
            BadgedThumbnailView(
                image: image,
                flagColor: flagColor,
                size: CGSize(width: 160, height: 108),
                badgeSize: 24,
                fills: true
            )
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
            Text(file.url.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 160, alignment: .center)
                .help(file.url.lastPathComponent)
        }
        .contentShape(Rectangle())
        .help(file.url.lastPathComponent)
    }
}
