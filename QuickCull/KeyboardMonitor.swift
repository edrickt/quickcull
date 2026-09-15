import AppKit
import QuickCullCore

/// App-wide key handling via a local event monitor (no focus requirements:
/// scrubbing must work the moment the window is up).
final class KeyboardMonitor {
    private var token: Any?
    private var loupeToken: Any?

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

        // Loupe: hold Space (keyCode 49) to show 100% magnifier. Separate monitor
        // for keyDown+keyUp so hold state is tracked without interfering with scrub
        // keys: non-Space events pass straight through. A Space hold that is still
        // down when the app deactivates is cleared by the viewer's
        // didResignActive/didResignKey observers (a keyUp may never arrive).
        loupeToken = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard event.keyCode == 49 else { return event }
            if event.type == .keyDown, event.isARepeat { return nil }
            let isDown = event.type == .keyDown
            Task { @MainActor in appState.setLoupeActive(isDown) }
            return nil // consume Space while scrubbing
        }
    }

    func stop() {
        if let token {
            NSEvent.removeMonitor(token)
            self.token = nil
        }
        if let loupeToken {
            NSEvent.removeMonitor(loupeToken)
            self.loupeToken = nil
        }
    }
}
