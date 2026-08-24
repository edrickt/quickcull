import SwiftUI
import QuickCullCore

/// Lets the File ▸ New Session menu command trigger the confirmation flow
/// in the focused window's ScrubView (focused values route commands to the
/// key window, so the alert appears exactly once in the right window).
struct NewSessionActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newSessionAction: (() -> Void)? {
        get { self[NewSessionActionKey.self] }
        set { self[NewSessionActionKey.self] = newValue }
    }
}

@main
struct QuickCullApp: App {
    @State private var appState = AppState()
    @State private var monitor: KeyboardMonitor?

    @FocusedValue(\.newSessionAction) private var newSessionAction

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    appState.prepareForLaunch()
                    let m = KeyboardMonitor()
                    m.start(appState: appState)
                    monitor = m
                    // Best-effort cache wipe on normal quit. Not guaranteed
                    // (force-quit skips it). The launch wipe is authoritative.
                    NotificationCenter.default.addObserver(
                        forName: NSApplication.willTerminateNotification,
                        object: nil, queue: .main) { _ in
                        let cache = appState.cache
                        Task { try? await cache.wipe() }
                    }
                }
                .onDisappear {
                    // Per-window monitor: stop it when the window closes so
                    // duplicate monitors don't double-fire after Cmd+N reopens.
                    monitor?.stop()
                    monitor = nil
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session") {
                    newSessionAction?()
                }
            }
        }
    }
}
