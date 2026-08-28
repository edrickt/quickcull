import SwiftUI
import QuickCullCore

/// Dismissible banner for failed decodes (and all-unsupported imports).
/// Shared verbatim by EmptyStateView and ScrubView.
struct ImportFailuresBanner: View {
    let failures: [DecodeOutcome]
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(summary)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Button("Dismiss") { onDismiss() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.15))
    }

    private var summary: String {
        let names = failures
            .prefix(3)
            .map { $0.file.url.lastPathComponent }
            .joined(separator: ", ")
        let count = failures.count
        return count > 3
            ? "\(count) file(s) could not be decoded: \(names) …"
            : "\(count) file(s) could not be decoded: \(names)"
    }
}
