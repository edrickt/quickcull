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
    /// One monitor and one quit observer for the whole app, not per window:
    /// closing a window must not disarm the keys or the quit-time cache wipe
    /// for the windows still open. Installed once by the first window's task.
    @State private var monitor: KeyboardMonitor?
    @State private var terminateObserver: NSObjectProtocol?

    @FocusedValue(\.newSessionAction) private var newSessionAction

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    // Both calls are idempotent: a second window (or a restored
                    // scene) must not wipe the cache the running session is
                    // reading from, nor stack a second app-wide key monitor.
                    appState.prepareForLaunch()
                    guard monitor == nil else { return }
                    let m = KeyboardMonitor()
                    m.start(appState: appState)
                    monitor = m
                    // Best-effort cache wipe on normal quit. Not guaranteed
                    // (force-quit skips it). The launch wipe is authoritative.
                    // `cache` is captured here (main actor) rather than read
                    // inside the Sendable observer closure.
                    let cache = appState.cache
                    terminateObserver = NotificationCenter.default.addObserver(
                        forName: NSApplication.willTerminateNotification,
                        object: nil, queue: .main) { _ in
                        Task { try? await cache.wipe() }
                    }
                }
        }
        .commands {
            // The standard New Window command stays (it is how a closed window
            // is reopened); a second window is harmless now that the launch
            // wipe and the key monitor are one-shot. New Session is the action
            // this app actually needs, so it gets its own shortcut.
            CommandGroup(after: .newItem) {
                Button("New Session") { newSessionAction?() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    // The focused value is nil while a commit/move is in flight
                    // (ScrubView withholds it), which disables the command.
                    .disabled(newSessionAction == nil)
            }
        }
    }
}
