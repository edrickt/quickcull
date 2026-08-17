import SwiftUI
import QuickCullCore
#if canImport(AppKit)
import AppKit
#endif

struct GridView: View {
    @Environment(AppState.self) private var appState

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 8)]

    var body: some View {
        let files = appState.session?.files ?? []
        if files.isEmpty {
            ZStack { Color.black; Text("No photos in this filter").foregroundStyle(.secondary) }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        GridCell(index: index, file: file,
                                 isSelected: appState.gridSelection.contains(file.id),
                                 isFlagged: appState.session?.isFlagged(file) ?? false)
                        .onAppear { appState.thumbWindow?.ensureLoaded(indices: [index]) }
                        .onTapGesture(count: 1) {
#if canImport(AppKit)
                            let flags = NSEvent.modifierFlags
                            appState.handleGridTap(id: file.id,
                                                   isCmd: flags.contains(.command),
                                                   isShift: flags.contains(.shift))
#else
                            appState.handleGridTap(id: file.id, isCmd: false, isShift: false)
#endif
                        }
                        .onTapGesture(count: 2) {
                            appState.handleGridDoubleClick(id: file.id)
                        }
                        .accessibilityLabel(file.url.lastPathComponent)
                        .accessibilityAddTraits(appState.gridSelection.contains(file.id) ? .isSelected : [])
                    }
                }
                .padding(12)
            }
            .background(Color.black.opacity(0.04))
        }
    }
}

private struct GridCell: View {
    let index: Int; let file: SessionFile; let isSelected: Bool; let isFlagged: Bool
    @Environment(AppState.self) private var appState
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = appState.thumbWindow?.image(at: index) {
                Image(decorative: image, scale: 2)
                    .resizable().scaledToFill().frame(width: 160, height: 108).clipped()
            } else {
                Rectangle().fill(.quaternary).frame(width: 160, height: 108)
            }
            if isFlagged { FlagBadge(size: 24).shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5) }
        }
        .frame(width: 160, height: 108)
        .clipped()
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}
