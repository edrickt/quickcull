import SwiftUI
import CoreGraphics
import QuickCullCore
#if canImport(AppKit)
import AppKit
#endif

struct GridView: View {
    @Environment(AppState.self) private var appState

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 8)]

    var body: some View {
        // Parent-body reads: avoid per-cell observation that makes LazyVGrid re-evaluate 500 cells on every gridSelection change.
        // Mirrors FilmstripView's stripKey/elements pattern for fast scrub.
        // Grid uses its own all-thumbs window (no sliding window): gridThumbs loads every thumbnail and never evicts on scroll,
        // unlike the strip's thumbWindow (radius 30) which unloads off-window cells.
        let files = appState.session?.files ?? []
        let gridSelection = appState.gridSelection
        let flagged = appState.session?.flagged ?? Set<String>()
        let thumbImages = appState.gridThumbs?.images ?? [:]
        if files.isEmpty {
            ZStack { Color.black; Text("No photos in this filter").foregroundStyle(.secondary) }
        } else {
            // Compute once per body evaluation; GridCell receives plain values, not @Environment reads.
            let elements: [(index: Int, file: SessionFile, isSelected: Bool, isFlagged: Bool, image: CGImage?)] = files.enumerated().map { idx, file in
                (index: idx,
                 file: file,
                 isSelected: gridSelection.contains(file.id),
                 isFlagged: flagged.contains(file.id),
                 image: thumbImages[idx])
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(elements, id: \.file.id) { element in
                        GridCell(
                            index: element.index,
                            file: element.file,
                            isSelected: element.isSelected,
                            isFlagged: element.isFlagged,
                            image: element.image
                        )
                        .task(id: element.index) { appState.gridThumbs?.ensureLoaded(indices: [element.index]) }
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
                        .accessibilityLabel(element.file.url.lastPathComponent)
                        .accessibilityAddTraits(element.isSelected ? .isSelected : [])
                    }
                }
                .padding(12)
            }
            .background(Color.black.opacity(0.04))
        }
    }
}

private struct GridCell: View {
    let index: Int; let file: SessionFile; let isSelected: Bool; let isFlagged: Bool; let image: CGImage?
    var body: some View {
        VStack(spacing: 4) {
            BadgedThumbnailView(
                image: image,
                isFlagged: isFlagged,
                size: CGSize(width: 160, height: 108),
                badgeSize: 24
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
