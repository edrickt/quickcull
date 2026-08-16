import SwiftUI
import QuickCullCore

struct ScrubView: View {
    @Environment(AppState.self) private var appState
    @State private var showCommitConfirm = false
    @State private var showCommitFailures = false

    var body: some View {
        VStack(spacing: 0) {
            if !appState.importFailures.isEmpty {
                importFailuresBanner
            }
            ImageDisplayView()
            Divider()
            FilmstripView()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.requestCommit()
                    showCommitConfirm = true
                } label: {
                    Label("Move Flagged to Trash", systemImage: "trash")
                }
                .disabled(appState.session?.flaggedCount == 0)
            }
        }
        .alert("Move \(appState.pendingCommitCount) file(s) to Trash?",
               isPresented: $showCommitConfirm) {
            Button("Move to Trash", role: .destructive) { appState.confirmCommit() }
            Button("Cancel", role: .cancel) { appState.cancelCommit() }
        } message: {
            Text("Flagged files will be removed from this session. Scrubbing continues with the rest.")
        }
        .alert("Could not move \(appState.commitFailures.count) file(s) to Trash",
               isPresented: $showCommitFailures) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The remaining files keep their flags. You may need to grant file access in System Settings.")
        }
        .onChange(of: appState.commitFailures.count) {
            if appState.commitFailures.count > 0 { showCommitFailures = true }
        }
    }

    /// Import failures are set before the decoding → scrubbing transition,
    /// so they are surfaced here (DecodingView can never render them).
    private var importFailuresBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(importFailureSummary)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Button("Dismiss") { appState.dismissImportFailures() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.15))
    }

    private var importFailureSummary: String {
        let names = appState.importFailures
            .prefix(3)
            .map { $0.file.url.lastPathComponent }
            .joined(separator: ", ")
        let count = appState.importFailures.count
        return count > 3
            ? "\(count) file(s) could not be decoded: \(names) …"
            : "\(count) file(s) could not be decoded: \(names)"
    }
}
