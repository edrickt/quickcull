import AppKit
import QuickCullCore

/// App-wide key handling via a local event monitor (no focus requirements:
/// scrubbing must work the moment the window is up).
final class KeyboardMonitor {
    private var token: Any?

    func start(appState: AppState) {
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Grid select-all: Cmd+A / Ctrl+A (accept both for muscle memory)
            let isA = event.keyCode == 0 || event.charactersIgnoringModifiers?.lowercased() == "a"
            let hasSelectAllModifier = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
            if isA && hasSelectAllModifier {
                Task { @MainActor in appState.selectAllInGrid() }
                return nil
            }
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
