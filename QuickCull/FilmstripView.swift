import SwiftUI
import QuickCullCore

struct FilmstripView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 3) {
                    // Iterate the files themselves, keyed by stable file id.
                    // Never ForEach(0..<count) with array subscripts in cells:
                    // when a commit shrinks the session, lazy stacks can
                    // re-render a surviving cell with a stale range index and
                    // trap on files[index] (crash).
                    ForEach(Array((appState.session?.files ?? []).enumerated()),
                            id: \.element.id) { index, file in
                        ThumbnailCell(index: index, file: file)
                    }
                }
                .padding(6)
            }
            .frame(height: 86)
            .background(.thinMaterial)
            .onChange(of: appState.session?.currentIndex) {
                // scrollTo must target the ForEach's identity (the file id),
                // not the integer index: cells are keyed by file id so a
                // commit-shrunk session can't re-render a stale index (crash).
                guard let session = appState.session,
                      session.files.indices.contains(session.currentIndex) else { return }
                let currentID = session.files[session.currentIndex].id
                withAnimation(.snappy) { proxy.scrollTo(currentID, anchor: .center) }
            }
        }
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
            if appState.session?.isFlagged(file) == true {
                FlagBadge(size: 24)
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
