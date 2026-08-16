import SwiftUI
import QuickCullCore

struct ScrubView: View {
    @Environment(AppState.self) private var appState
    @State private var showCommitConfirm = false
    @State private var showCommitFailures = false

    var body: some View {
        VStack(spacing: 0) {
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
}
