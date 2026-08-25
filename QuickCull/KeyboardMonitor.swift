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
        // for keyDown+keyUp so hold state is tracked without interfering with scrub keys.
        loupeToken = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            // Space is not a modifier; flagsChanged is used only to clear stuck hold
            // when the app loses focus or modifier state changes while Space is held.
            if event.type == .flagsChanged {
                // If loupe is active but Space is no longer flagged as down (e.g. Cmd+Tab),
                // flagsChanged gives us a chance to reset. We conservatively clear if no keys held?
                // Instead, check if Space key is still logically down via current event's keyCode - not reliable for flagsChanged.
                // So we just ensure loupe is cleared if window loses key status; the view's onDisappear also clears.
                return event
            }
            if event.keyCode == 49 { // Space
                let isDown = event.type == .keyDown
                if event.isARepeat { return nil }
                Task { @MainActor in appState.setLoupeActive(isDown) }
                return nil // consume Space while scrubbing
            }
            return event
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
