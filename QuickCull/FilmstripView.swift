import SwiftUI
import QuickCullCore

struct FilmstripView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 3) {
                    ForEach(0..<(appState.session?.count ?? 0), id: \.self) { index in
                        ThumbnailCell(index: index)
                            .id(index)
                    }
                }
                .padding(6)
            }
            .frame(height: 86)
            .background(.thinMaterial)
            .onChange(of: appState.session?.currentIndex) {
                if let current = appState.session?.currentIndex {
                    withAnimation(.snappy) { proxy.scrollTo(current, anchor: .center) }
                }
            }
        }
    }
}

struct ThumbnailCell: View {
    let index: Int
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
            if let file = appState.session?.files[index],
               appState.session?.isFlagged(file) == true {
                FlagBadge()
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
