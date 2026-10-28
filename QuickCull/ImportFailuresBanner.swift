import SwiftUI
import QuickCullCore

/// Dismissible banner for failed decodes (and all-unsupported imports).
/// Shared verbatim by EmptyStateView and ScrubView. The wording comes from
/// `ImportFailureSummary` so a cache/disk failure is not reported as a broken
/// photo (see `DecodeError.cannotStorePreview`).
struct ImportFailuresBanner: View {
    let failures: [DecodeOutcome]
    let onDismiss: () -> Void

    var body: some View {
        let summary = ImportFailureSummary.text(for: failures)
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(summary)
                .font(.caption)
                .lineLimit(2)
                .help(summary)
            Spacer()
            Button("Dismiss") { onDismiss() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.15))
    }
}
