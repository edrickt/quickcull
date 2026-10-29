import AppKit
import QuickCullCore

/// App-wide key handling via a local event monitor (no focus requirements:
/// scrubbing must work the moment the window is up).
///
/// One instance for the whole app (`QuickCullApp` installs it once), so it is
/// main-actor-only: monitors and `NSApp` state are main-thread APIs.
@MainActor
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
            // A chord involving Space belongs to the system (Cmd+Space, and
            // Control+Space's input-source switch): the loupe is a bare key.
            guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else {
                return event
            }
            if event.type == .keyDown, event.isARepeat { return nil }
            let isDown = event.type == .keyDown
            Task { @MainActor in appState.setLoupeActive(isDown) }
            return nil // consume Space while scrubbing
        }
    }

    /// A modal, a sheet (the import panel is one), or a text field owns every
    /// key. Sheets are checked two ways: the key window may be the sheet
    /// itself (`isSheet`), or the sheet may hang off it (`attachedSheet`) —
    /// SwiftUI's `.fileImporter` presents either way depending on context,
    /// and checking only one left arrows/Space consumed as cull keys while
    /// the panel was open.
    private static var systemOwnsKeys: Bool {
        if NSApp.modalWindow != nil { return true }
        // Any window carrying a sheet owns the keys, not just the key window:
        // the import panel is app-wide (the monitor is too), so a sheet on a
        // background window still means the user is picking files.
        if NSApp.windows.contains(where: { $0.isSheet || $0.attachedSheet != nil }) { return true }
        if NSApp.keyWindow?.isSheet == true { return true }
        return NSApp.keyWindow?.firstResponder is NSTextView
    }

    private static func route(_ event: NSEvent) -> KeyEventOutcome {
        let flags = event.modifierFlags
        return KeyRouter.outcome(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            hasCommand: flags.contains(.command),
            hasControl: flags.contains(.control),
            hasOption: flags.contains(.option),
            hasModalWindow: NSApp.modalWindow != nil,
            hasSheet: NSApp.keyWindow?.isSheet == true
                || NSApp.keyWindow?.attachedSheet != nil
                || NSApp.windows.contains(where: { $0.isSheet }),
            isEditingText: NSApp.keyWindow?.firstResponder is NSTextView)
    }
}
