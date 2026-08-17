import SwiftUI
import QuickCullCore

struct ScrubView: View {
    @Environment(AppState.self) private var appState
    @State private var showCommitConfirm = false
    @State private var showCommitFailures = false
    // Zoom persists across images while staying in single-view mode, but
    // resets when leaving single (to grid) so a grid round-trip never
    // restores a stale 200% zoom. Hoisted here because ImageDisplayView is
    // recreated on viewMode toggle.
    @State private var zoomScale: CGFloat = 1
    @State private var zoomLastScale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var zoomLastOffset: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            if !appState.importFailures.isEmpty {
                importFailuresBanner
            }
            if appState.viewMode == .grid {
                GridView()
            } else {
                ImageDisplayView(
                    zoomScale: $zoomScale,
                    zoomLastScale: $zoomLastScale,
                    zoomOffset: $zoomOffset,
                    zoomLastOffset: $zoomLastOffset
                )
                Divider()
                FilmstripView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("View", selection: Binding(
                    get: { appState.viewMode },
                    set: { appState.setViewMode($0) }
                )) {
                    Text("Single").tag(AppState.ViewMode.scrub)
                    Text("Grid").tag(AppState.ViewMode.grid)
                }.pickerStyle(.segmented).disabled(appState.isCommitting)
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Filter", selection: Binding(
                    get: { appState.session?.filter ?? .all },
                    set: { appState.setFilter($0) }
                )) {
                    Text("All").tag(CullFilter.all)
                    Text("Flagged (\(appState.session?.flaggedCount ?? 0))").tag(CullFilter.flagged)
                    Text("Keepers (\(appState.session.map { $0.totalCount - $0.flaggedCount } ?? 0))")
                        .tag(CullFilter.keepers)
                }
                .pickerStyle(.segmented)
                .disabled(appState.isCommitting)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.requestCommit()
                    showCommitConfirm = true
                } label: {
                    if appState.isCommitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Move Flagged to Trash", systemImage: "trash")
                    }
                }
                .disabled(appState.session?.flaggedCount == 0 || appState.isCommitting)
            }
        }
        .alert("Move \(appState.pendingCommitCount) file(s) to Trash?",
               isPresented: $showCommitConfirm) {
            Button("Move to Trash", role: .destructive) {
                Task { await appState.confirmCommit() }
            }
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
        .onChange(of: appState.phase) { _, newPhase in
            // New import or empty session: reset zoom to fit so a stale 200% does not surprise the next shoot.
            if newPhase == .empty || isDecoding(newPhase) {
                zoomScale = 1
                zoomLastScale = 1
                zoomOffset = .zero
                zoomLastOffset = .zero
            }
        }
        .onChange(of: appState.viewMode) { oldMode, newMode in
            // Grid round-trip must not restore zoom: zoom persists only while staying in single.
            // Reset on any toggle so Single→Grid→Single lands at fit.
            if oldMode != newMode {
                zoomScale = 1
                zoomLastScale = 1
                zoomOffset = .zero
                zoomLastOffset = .zero
            }
        }
    }

    private func isDecoding(_ phase: AppPhase) -> Bool {
        if case .decoding = phase { return true }
        return false
    }

    /// Import failures are set before the decoding → scrubbing transition,
    /// so they appear here (DecodingView can never render them).
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
