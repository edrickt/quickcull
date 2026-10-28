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

/// Wipes the decode cache before the process exits.
///
/// `willTerminate` is too late for that: it is posted on the way to `exit()`, so
/// the async wipe it used to schedule had no run loop left and a normal quit
/// kept the whole cache (gigabytes at 45 MP) until the next launch's wipe.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isWiping = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isWiping else { return .terminateNow }
        isWiping = true
        let cache = ImageCacheStore(baseURL: ImageCacheStore.defaultBaseURL())
        Task { @MainActor in
            await Self.wipe(cache)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Deletes the cache, but never holds the quit open longer than a few
    /// seconds: a hung volume must not turn Quit into a freeze, and the launch
    /// wipe covers whatever is left.
    private static func wipe(_ cache: ImageCacheStore, timeout: Double = 5) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await cache.wipe() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }
}

@main
struct QuickCullApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    /// One monitor for the whole app, not per window: closing a window must not
    /// disarm the keys for the windows still open. Installed once by the first
    /// window's task.
    @State private var monitor: KeyboardMonitor?

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
