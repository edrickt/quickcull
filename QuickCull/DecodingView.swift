import SwiftUI
import QuickCullCore

/// Shown while every file decodes. The first picture appears as soon as its
/// cache JPEG lands (`AppState.decodePreview`), while scrubbing and flagging
/// stay locked until the whole import completes — the blocking guarantee is
/// unchanged, only the wait for a first glimpse is shortened.
struct DecodingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let preview = appState.decodePreview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(0.9)
                    .transition(.opacity)
            }
            VStack(spacing: 16) {
                if case .decoding(let completed, let total) = appState.phase {
                    ProgressView(value: Double(completed), total: Double(total))
                        .frame(maxWidth: 400)
                    Text("Decoding \(completed) of \(total)…")
                        .monospacedDigit()
                    if appState.decodePreview != nil {
                        Text("First picture ready — input unlocks when all files are decoded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
