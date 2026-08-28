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
                ImportFailuresBanner(failures: appState.importFailures,
                                     onDismiss: { appState.dismissImportFailures() })
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                FilmstripView()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // File ▸ New Session (menu bar) routes here via the focused value,
        // presenting the confirmation in this window.
        .focusedSceneValue(\.newSessionAction) { showNewSessionConfirm = true }
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

    /// View-mode/filter segmented pickers and all action buttons
    /// (metadata toggle, trash, move; New Session lives in the menu bar's
    /// File menu).
    /// They live here (not in the window toolbar) so the toolbar stays
    /// narrow enough to never overflow into the chevron: on macOS 26 a
    /// SwiftUI toolbar item crossing the overflow threshold during a
    /// resize trips an AppKit constraint-pass guard
    /// ("Update Constraints in Window pass" > view count) and crashes
    /// the app (EXC_BREAKPOINT in _postWindowNeedsUpdateConstraints).
    ///
    /// Width strategy: `ViewThatFits` shows the one-row bar when it fits,
    /// otherwise the two-row fallback. This matters because segmented
    /// pickers refuse to compress: in a single-row bar at a narrow window,
    /// SwiftUI would crush the text buttons into unreadable slivers and
    /// clip the last one off-window. The two-row bar (pickers on top,
    /// actions below) keeps every control at its natural size down to the
    /// window's minimum width (900pt).
    ///
    /// Each candidate fixes its own height (40pt one row, 72pt two rows)
    /// with the padding inside: without a fixed height the bar is
    /// vertically flexible, so the enclosing VStack stretches it and the
    /// controls float with empty space above and below.
    private var controlBar: some View {
        ViewThatFits(in: .horizontal) {
            singleRowBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(height: 40)
            twoRowBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(height: 72)
        }
    }

    private var singleRowBar: some View {
        HStack(spacing: 12) {
            viewModePicker
            filterPicker
            Spacer()
            actionButtons
        }
    }

    private var twoRowBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                viewModePicker
                filterPicker
                Spacer()
            }
            // Actions anchored left, aligned under the pickers above.
            HStack(spacing: 12) {
                actionButtons
                Spacer()
            }
        }
    }

    /// Per-color flag counts, computed once per read. Each `flaggedCount`
    /// call scans the flags dictionary; the bar previously issued ~10 scans
    /// per render (filter picker + both dropdowns).
    @MainActor
    private struct FlagCounts {
        let red: Int
        let yellow: Int
        let green: Int
        let all: Int
        let unflagged: Int

        init(_ session: Session?) {
            red = session?.flaggedCount(.red) ?? 0
            yellow = session?.flaggedCount(.yellow) ?? 0
            green = session?.flaggedCount(.green) ?? 0
            all = session?.flaggedCount() ?? 0
            unflagged = session.map { $0.totalCount - $0.flaggedCount() } ?? 0
        }
    }

    private var flagCounts: FlagCounts { FlagCounts(appState.session) }

    private var viewModePicker: some View {
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
    }

    private var filterPicker: some View {
        let counts = flagCounts
        return Picker("Filter", selection: Binding(
            get: { appState.session?.filter ?? .all },
            set: { appState.setFilter($0) }
        )) {
            Text("All").tag(CullFilter.all)
            Text("R (\(counts.red))").tag(CullFilter.red)
            Text("Y (\(counts.yellow))").tag(CullFilter.yellow)
            Text("G (\(counts.green))").tag(CullFilter.green)
            Text("Unflagged (\(counts.unflagged))").tag(CullFilter.keepers)
        }
        .pickerStyle(.segmented)
        .fontWeight(.light)
        .disabled(appState.isCommitting || appState.isMoving)
    }

    @ViewBuilder
    private var actionButtons: some View {
        let counts = flagCounts
        let busy = appState.isCommitting || appState.isMoving
        Button(hudVisible ? "Hide Metadata" : "Show Metadata") { hudVisible.toggle() }
            .fontWeight(.light)
            .help(hudVisible ? "Hide metadata" : "Show metadata")
            .disabled(busy)
        DropdownMenu(items: [
            .init("Trash R (\(counts.red))", destructive: true,
                  disabled: counts.red == 0 || busy) {
                appState.requestCommit(color: .red); showCommitConfirm = true
            },
            .init("Trash Y (\(counts.yellow))", destructive: true,
                  disabled: counts.yellow == 0 || busy) {
                appState.requestCommit(color: .yellow); showCommitConfirm = true
            },
            .init("Trash G (\(counts.green))", destructive: true,
                  disabled: counts.green == 0 || busy) {
                appState.requestCommit(color: .green); showCommitConfirm = true
            },
            .init("Trash All Flagged (\(counts.all))", destructive: true,
                  disabled: counts.all == 0 || busy) {
                appState.requestCommit(color: nil); showCommitConfirm = true
            },
        ]) {
            if appState.isCommitting {
                ProgressView().controlSize(.small)
            } else {
                Label("Move Flagged to Trash", systemImage: "trash").fontWeight(.light)
            }
        }
        .disabled(busy)
        DropdownMenu(items: [
            .init("Move R (\(counts.red))",
                  disabled: counts.red == 0 || busy) {
                if let dest = chooseMoveDestination() {
                    appState.requestMove(to: dest, color: .red); showMoveConfirm = true
                }
            },
            .init("Move Y (\(counts.yellow))",
                  disabled: counts.yellow == 0 || busy) {
                if let dest = chooseMoveDestination() {
                    appState.requestMove(to: dest, color: .yellow); showMoveConfirm = true
                }
            },
            .init("Move G (\(counts.green))",
                  disabled: counts.green == 0 || busy) {
                if let dest = chooseMoveDestination() {
                    appState.requestMove(to: dest, color: .green); showMoveConfirm = true
                }
            },
            .init("Move All Flagged (\(counts.all))",
                  disabled: counts.all == 0 || busy) {
                if let dest = chooseMoveDestination() {
                    appState.requestMove(to: dest, color: nil); showMoveConfirm = true
                }
            },
        ]) {
            if appState.isMoving {
                ProgressView().controlSize(.small)
            } else {
                Label("Move Flagged", systemImage: "folder").fontWeight(.light)
            }
        }
        .disabled(busy)
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
