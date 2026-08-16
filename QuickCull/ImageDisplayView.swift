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
            } else if let thumb = appState.thumbWindow?.image(at: index) {
                // The display-size decode (~100-400 ms for a 45 MP cache
                // entry) lags fast scrubbing. Show the already-resident
                // same-index thumbnail upscaled so the current photo is
                // visible immediately; the sharp image replaces it when the
                // decode lands. Same index = same photo, never a wrong image.
                Image(decorative: thumb, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().controlSize(.large)
            }
        }
    }
}
