import AppKit
import SwiftUI
import UsageCore

/// The Settings window, shown on first launch and from the menu. The integrator owns
/// one, keeps it alive, and calls `present()`.
///
/// Wiring sketch (AppDelegate):
///
///     let store = SettingsStore()
///     let settings = store.load() ?? AppSettings()
///     let model = SetupModel(settings: settings, saver: SettingsSaver(
///         settingsStore: store, secrets: Keychain(), pollControl: coordinator))
///     model.onSaved = { settings, _ in /* menubar style, ocgoConfigured */ }
///     setupWindow = SetupWindowController(model: model)
///     if SetupWindowController.needsSetup(settings: settings) { setupWindow.present() }
@MainActor
final class SetupWindowController: NSWindowController {
    /// First launch, or no source has a URL yet.
    nonisolated static func needsSetup(settings: AppSettings) -> Bool {
        !SourceKind.allCases.contains { settings.isConfigured($0) }
    }

    let model: SetupModel

    init(model: SetupModel) {
        self.model = model
        let hosting = NSHostingController(rootView: SetupView(model: model))
        let window = EscapeClosingWindow(contentViewController: hosting)
        window.title = "Usage Monitor Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 680))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Escape closes the window, like a dialog. Unsaved edits are dropped, as with the
    /// close button.
    private final class EscapeClosingWindow: NSWindow {
        override func cancelOperation(_ sender: Any?) { performClose(sender) }
    }

    /// Brings the window to the front. Opening a closed window reloads the saved values
    /// and the Keychain: the window and its view outlive a close, so edits, Test results
    /// or an unreadable-secret note from last time would otherwise remain. A minimized
    /// window is still open, so it keeps its edits. The app is an accessory (no Dock
    /// icon), so it has to activate itself for the window to take focus.
    func present() {
        if window?.isVisible != true, window?.isMiniaturized != true { model.startLoad() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
