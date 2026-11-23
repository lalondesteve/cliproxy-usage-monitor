import AppKit
import UsageCore

@main
enum UsageMonitorMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let options = LaunchOptions.parse(CommandLine.arguments)
            let env: Wiring.Environment
            do {
                env = try Wiring.environment(for: options)
            } catch {
                Wiring.log("\(error)")
                exit(64)
            }
            let delegate = AppDelegate(options: options, env: env)
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

/// Owns the status item, the dropdown, the Settings window and the pipeline
/// (`Wiring`). The coordinator is built off the main thread, since it reads the
/// Keychain; Settings opens once it exists.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private let env: Wiring.Environment
    private var statusItem: StatusItemController?
    private let dropdown = DropdownPopover()
    private var pipeline: AppPipeline?
    private var setupWindow: SetupWindowController?
    /// Settings was asked for before the coordinator existed.
    private var settingsRequested = false

    init(options: LaunchOptions, env: Wiring.Environment) {
        self.options = options
        self.env = env
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = env.settingsStore.load() ?? AppSettings()
        let statusItem = StatusItemController(
            actions: .init(refresh: { [weak self] in self?.pipeline?.refresh() },
                           openSettings: { [weak self] in self?.openSettings() }),
            style: settings.menubarStyle)
        statusItem.onOpenDropdown = { [weak self, weak statusItem] in
            guard let self else { return }
            Wiring.toggle(dropdown, anchor: statusItem?.anchorView)
        }
        self.statusItem = statusItem
        dropdown.state.clockOffset = env.clockOffset
        if let fixtures = options.fixtures { Wiring.log("fixtures from \(fixtures.path)") }

        let env = self.env
        Task {
            let coordinator = await Task.detached { Wiring.makeCoordinator(env) }.value
            attach(coordinator, settings: settings)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pipeline?.stop()
    }

    private func attach(_ coordinator: PollCoordinator, settings: AppSettings) {
        guard let statusItem else { return }
        let pipeline = AppPipeline(coordinator: coordinator)
        var presenters: [any DashboardPresenting] = [statusItem, dropdown]
        if let url = options.debugSnapshot { presenters.append(SnapshotWriter(statusItem: statusItem, url: url)) }
        pipeline.present(to: presenters)
        // Stamped with the environment's clock, so fixture-mode gaps line up with the
        // fixture readings (--now runs behind wall time).
        let clock = env.clock
        pipeline.run(power: Wiring.powerEvents(now: { clock.now }))
        self.pipeline = pipeline

        let model = Wiring.makeSetupModel(settings: settings, env: env, pollControl: coordinator)
        // The Go row follows from the save itself: SettingsSaver calls configChanged(.ocgo)
        // when the ocgo URL changes, and the coordinator republishes with ocgo
        // .notConfigured when the URL is gone, which hides the row in both views.
        model.onSaved = { [weak self] saved, _ in
            self?.statusItem?.style = saved.menubarStyle
            Wiring.log("settings saved (menubar \(saved.menubarStyle.rawValue), "
                + "ocgo \(saved.ocgoConfigured ? "configured" : "not configured"))")
        }
        model.onMenubarStyle = { [weak self] style in
            self?.statusItem?.style = style
            Wiring.log("menubar \(style.rawValue)")
        }
        setupWindow = SetupWindowController(model: model)
        if settingsRequested || (options.fixtures == nil && SetupWindowController.needsSetup(settings: settings)) {
            settingsRequested = false
            setupWindow?.present()
        }
    }

    private func openSettings() {
        dropdown.close()
        if let setupWindow {
            setupWindow.present()
        } else {
            settingsRequested = true
        }
    }
}

/// `--debug-snapshot`: writes a PNG of the status item after each model.
@MainActor
private final class SnapshotWriter: DashboardPresenting {
    let statusItem: StatusItemController
    let url: URL

    init(statusItem: StatusItemController, url: URL) {
        self.statusItem = statusItem
        self.url = url
    }

    func show(_ model: DashboardModel) {
        let snapshot = statusItem.debugSnapshot()
        Wiring.log("status item: \(snapshot.description)")
        do {
            try snapshot.png?.write(to: url)
        } catch {
            Wiring.log("status item snapshot failed: \(error)")
        }
    }
}
