import SwiftUI
import QuickCullCore

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.phase {
        case .empty: EmptyStateView()
        case .decoding: DecodingView()
        case .scrubbing: ScrubView()
        }
    }
}
