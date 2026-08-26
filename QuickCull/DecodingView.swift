import SwiftUI
import QuickCullCore

struct DecodingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            if case .decoding(let completed, let total) = appState.phase {
                ProgressView(value: Double(completed), total: Double(total))
                    .frame(maxWidth: 400)
                Text("Decoding \(completed) of \(total)…")
                    .monospacedDigit()
            }
        }
        .padding(40)
    }
}
