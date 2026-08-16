import AppKit
import QuickCullCore

/// App-wide key handling via a local event monitor (no focus requirements —
/// scrubbing must work the moment the window is up).
final class KeyboardMonitor {
    private var token: Any?

    func start(appState: AppState) {
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let action = CullKeyMap.action(forKeyCode: event.keyCode) {
                Task { @MainActor in appState.handle(action) }
                return nil   // consume
            }
            return event
        }
    }

    func stop() {
        if let token {
            NSEvent.removeMonitor(token)
            self.token = nil
        }
    }
}
