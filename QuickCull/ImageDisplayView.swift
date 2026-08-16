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
            } else {
                ProgressView().controlSize(.large)
            }
            if let file = appState.session?.files[index],
               appState.session?.isFlagged(file) == true {
                VStack {
                    HStack {
                        Spacer()
                        FlagBadge().padding(12)
                    }
                    Spacer()
                }
            }
        }
    }
}
