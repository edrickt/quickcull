import AppKit
import SwiftUI
import QuickCullCore

struct ScrubView: View {
    @Environment(AppState.self) private var appState
    @State private var showCommitConfirm = false
    @State private var showCommitFailures = false
    @State private var showNewSessionConfirm = false
    @State private var showMoveConfirm = false
    @State private var showMoveFailures = false
    // Zoom persists across images while staying in single-view mode, but
    // resets when leaving single (to grid) so a grid round-trip never
    // restores a stale 200% zoom. Hoisted here because ImageDisplayView is
    // recreated on viewMode toggle.
    @State private var zoomScale: CGFloat = 1
    @State private var zoomLastScale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var zoomLastOffset: CGSize = .zero
    @State private var hudVisible = false // hidden by default, Single only

    var body: some View {
        VStack(spacing: 0) {
            if !appState.importFailures.isEmpty {
                importFailuresBanner
            }
            controlBar
            if appState.viewMode == .grid {
                GridView()
            } else {
                ImageDisplayView(
                    zoomScale: $zoomScale,
                    zoomLastScale: $zoomLastScale,
                    zoomOffset: $zoomOffset,
                    zoomLastOffset: $zoomLastOffset,
                    hudVisible: $hudVisible
                )
                Divider()
                FilmstripView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(hudVisible ? "Hide Metadata" : "Show Metadata") { hudVisible.toggle() }
                    .fontWeight(.light)
                    .help(hudVisible ? "Hide metadata" : "Show metadata")
                    .disabled(appState.isCommitting || appState.isMoving)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Session") { showNewSessionConfirm = true }
                    .fontWeight(.light)
                    .disabled(appState.isCommitting || appState.isMoving)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Trash R (\(appState.session?.flaggedCount(.red) ?? 0))", role: .destructive) {
                        appState.requestCommit(color: .red); showCommitConfirm = true
                    }.disabled((appState.session?.flaggedCount(.red) ?? 0) == 0 || appState.isCommitting || appState.isMoving)
                    Button("Trash Y (\(appState.session?.flaggedCount(.yellow) ?? 0))", role: .destructive) {
                        appState.requestCommit(color: .yellow); showCommitConfirm = true
                    }.disabled((appState.session?.flaggedCount(.yellow) ?? 0) == 0 || appState.isCommitting || appState.isMoving)
                    Button("Trash G (\(appState.session?.flaggedCount(.green) ?? 0))", role: .destructive) {
                        appState.requestCommit(color: .green); showCommitConfirm = true
                    }.disabled((appState.session?.flaggedCount(.green) ?? 0) == 0 || appState.isCommitting || appState.isMoving)
                    Button("Trash All Flagged (\(appState.session?.flaggedCount() ?? 0))", role: .destructive) {
                        appState.requestCommit(color: nil); showCommitConfirm = true
                    }.disabled((appState.session?.flaggedCount() ?? 0) == 0 || appState.isCommitting || appState.isMoving)
                } label: {
                    if appState.isCommitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Move Flagged to Trash", systemImage: "trash")
                    }
                }
                .fontWeight(.light)
                .disabled(appState.isCommitting || appState.isMoving)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Move R (\(appState.session?.flaggedCount(.red) ?? 0))") {
                        if let dest = chooseMoveDestination() {
                            appState.requestMove(to: dest, color: .red); showMoveConfirm = true
                        }
                    }.disabled((appState.session?.flaggedCount(.red) ?? 0) == 0 || appState.isCommitting || appState.isMoving)
                    Button("Move Y (\(appState.session?.flaggedCount(.yellow) ?? 0))") {
                        if let dest = chooseMoveDestination() {
                            appState.requestMove(to: dest, color: .yellow); showMoveConfirm = true
                        }
                    }.disabled((appState.session?.flaggedCount(.yellow) ?? 0) == 0 || appState.isCommitting || appState.isMoving)
                    Button("Move G (\(appState.session?.flaggedCount(.green) ?? 0))") {
                        if let dest = chooseMoveDestination() {
                            appState.requestMove(to: dest, color: .green); showMoveConfirm = true
                        }
                    }.disabled((appState.session?.flaggedCount(.green) ?? 0) == 0 || appState.isCommitting || appState.isMoving)
                    Button("Move All Flagged (\(appState.session?.flaggedCount() ?? 0))") {
                        if let dest = chooseMoveDestination() {
                            appState.requestMove(to: dest, color: nil); showMoveConfirm = true
                        }
                    }.disabled((appState.session?.flaggedCount() ?? 0) == 0 || appState.isCommitting || appState.isMoving)
                } label: {
                    if appState.isMoving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Move Flagged", systemImage: "folder")
                    }
                }
                .fontWeight(.light)
                .disabled(appState.isCommitting || appState.isMoving)
            }
        }
        .alert("Move \(appState.pendingCommitCount) \(appState.pendingCommitColor?.displayName ?? "flagged") file(s) to Trash?",
               isPresented: $showCommitConfirm) {
            Button("Move to Trash", role: .destructive) {
                Task { await appState.confirmCommit() }
            }
            Button("Cancel", role: .cancel) { appState.cancelCommit() }
        } message: {
            Text("Flagged files will be removed from this session. Scrubbing continues with the rest.")
        }
        .alert("Could not move \(appState.commitFailures.count) \(appState.lastCommitColor?.displayName ?? "flagged") file(s) to Trash",
               isPresented: $showCommitFailures) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The remaining files keep their flags. You may need to grant file access in System Settings.")
        }
        .alert("Move \(appState.pendingMoveCount) \(appState.pendingMoveColor?.displayName ?? "flagged") file(s) to \"\(appState.pendingMoveDestination?.lastPathComponent ?? "")\"?",
               isPresented: $showMoveConfirm) {
            Button("Move", role: .none) {
                Task { await appState.confirmMove() }
            }
            Button("Cancel", role: .cancel) { appState.cancelMove() }
        } message: {
            Text("Flagged files will be moved to the selected folder and removed from this session. Scrubbing continues with the rest.")
        }
        .alert("Could not move \(appState.moveFailures.count) \(appState.lastMoveColor?.displayName ?? "flagged") file(s)",
               isPresented: $showMoveFailures) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The remaining files keep their flags. You may need to grant file access in System Settings, or choose a writable folder.")
        }
        .alert("Start new session?", isPresented: $showNewSessionConfirm) {
            Button("Start New Session", role: .destructive) { appState.startNewSession() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This discards the current session, including flagged photos, and clears the decode cache.")
        }
        .onChange(of: appState.commitFailures.count) {
            if appState.commitFailures.count > 0 { showCommitFailures = true }
        }
        .onChange(of: appState.moveFailures.count) {
            if appState.moveFailures.count > 0 { showMoveFailures = true }
        }
        .onChange(of: appState.phase) { _, newPhase in
            // New import or empty session: reset zoom to fit so a stale 200% does not surprise the next shoot.
            if newPhase == .empty || isDecoding(newPhase) {
                zoomScale = 1
                zoomLastScale = 1
                zoomOffset = .zero
                zoomLastOffset = .zero
                hudVisible = false
            }
        }
        .onChange(of: appState.viewMode) { oldMode, newMode in
            // Grid round-trip must not restore zoom: zoom persists only while staying in single.
            // Reset zoom on any toggle so Single→Grid→Single lands at fit.
            // hudVisible is preserved across viewMode changes (user expects metadata to stay visible).
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

    /// View-mode and filter segmented pickers, formerly toolbar items.
    /// They live here (not in the window toolbar) so the toolbar stays
    /// narrow enough to never overflow into the chevron: on macOS 26 a
    /// SwiftUI toolbar item crossing the overflow threshold during a
    /// resize trips an AppKit constraint-pass guard
    /// ("Update Constraints in Window pass" > view count) and crashes
    /// the app (EXC_BREAKPOINT in _postWindowNeedsUpdateConstraints).
    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker("View", selection: Binding(
                get: { appState.viewMode },
                set: { appState.setViewMode($0) }
            )) {
                Text("Single").tag(AppState.ViewMode.scrub)
                Text("Split").tag(AppState.ViewMode.split)
                Text("Grid").tag(AppState.ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .fontWeight(.light)
            .disabled(appState.isCommitting || appState.isMoving)
            Picker("Filter", selection: Binding(
                get: { appState.session?.filter ?? .all },
                set: { appState.setFilter($0) }
            )) {
                Text("All").tag(CullFilter.all)
                Text("R (\(appState.session?.flaggedCount(.red) ?? 0))").tag(CullFilter.red)
                Text("Y (\(appState.session?.flaggedCount(.yellow) ?? 0))").tag(CullFilter.yellow)
                Text("G (\(appState.session?.flaggedCount(.green) ?? 0))").tag(CullFilter.green)
                Text("Unflagged (\(appState.session.map { $0.totalCount - $0.flaggedCount() } ?? 0))").tag(CullFilter.keepers)
            }
            .pickerStyle(.segmented)
            .fontWeight(.light)
            .disabled(appState.isCommitting || appState.isMoving)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

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

    private func chooseMoveDestination() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        panel.message = "Choose a folder to move flagged images to"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
