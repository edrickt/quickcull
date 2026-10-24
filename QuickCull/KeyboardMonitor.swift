import AppKit
import QuickCullCore

/// App-wide key handling via a local event monitor (no focus requirements:
/// scrubbing must work the moment the window is up).
final class KeyboardMonitor {
    private var token: Any?
    private var loupeToken: Any?

    func start(appState: AppState) {
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Self.route(event) {
            case .passthrough:
                return event
            case .selectAll:
                Task { @MainActor in appState.selectAllInGrid() }
                return nil
            case .handle(let action):
                Task { @MainActor in appState.handle(action) }
                return nil   // consume
            }
        }

        // Loupe: hold Space (keyCode 49) to show the magnifier. Separate monitor
        // for keyDown+keyUp so hold state is tracked without interfering with scrub
        // keys: non-Space events pass straight through. A Space hold that is still
        // down when the app deactivates is cleared by the viewer's
        // didResignActive/didResignKey observers (a keyUp may never arrive).
        loupeToken = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard event.keyCode == 49 else { return event }
            guard !Self.systemOwnsKeys else { return event }
            if event.type == .keyDown, event.isARepeat { return nil }
            let isDown = event.type == .keyDown
            Task { @MainActor in appState.setLoupeActive(isDown) }
            return nil // consume Space while scrubbing
        }
    }

    /// A modal (the folder picker runs one) or a text field owns every key.
    private static var systemOwnsKeys: Bool {
        if NSApp.modalWindow != nil { return true }
        return NSApp.keyWindow?.firstResponder is NSTextView
    }

    private static func route(_ event: NSEvent) -> KeyEventOutcome {
        let flags = event.modifierFlags
        return KeyRouter.outcome(
            keyCode: event.keyCode,
            hasCommand: flags.contains(.command),
            hasControl: flags.contains(.control),
            hasOption: flags.contains(.option),
            hasModalWindow: NSApp.modalWindow != nil,
            isEditingText: NSApp.keyWindow?.firstResponder is NSTextView)
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
