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
            if !appState.importFailures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(appState.importFailures.count) file(s) could not be decoded:")
                        .font(.headline)
                    List(appState.importFailures, id: \.file.id) { outcome in
                        Text("\(outcome.file.url.lastPathComponent) — \(outcome.error.map(String.init(describing:)) ?? "")")
                            .font(.caption)
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
        .padding(40)
    }
}
