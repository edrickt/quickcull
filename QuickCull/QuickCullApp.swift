import SwiftUI
import QuickCullCore

@main
struct QuickCullApp: App {
    @State private var appState = AppState()
    @State private var monitor: KeyboardMonitor?

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
                    // (force-quit skips it) — the launch wipe is authoritative.
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
    }
}
