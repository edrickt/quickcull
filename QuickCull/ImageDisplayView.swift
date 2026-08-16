import SwiftUI
import QuickCullCore

struct ImageDisplayView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let index = appState.session?.currentIndex ?? 0
        ZStack {
            Color.black
            if let image = appState.displayImages?.image(at: index) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .overlay(alignment: .topTrailing) {
                        // Pinned to the image's own corner so it follows the
                        // image bounds even when letterboxed.
                        if let file = appState.session?.files[index],
                           appState.session?.isFlagged(file) == true {
                            FlagBadge(size: 44)
                        }
                    }
            } else {
                ProgressView().controlSize(.large)
            }
        }
    }
}
