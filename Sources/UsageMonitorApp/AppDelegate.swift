import AppKit
import UsageCore

@main
enum UsageMonitorMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate(options: LaunchOptions.parse(CommandLine.arguments))
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let testTokenPrefix = "t1-test-token-"
    private let options: LaunchOptions
    private let keychain = Keychain()
    private var statusItem: StatusItemController?
    private var source: (any UsageSource)?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(actions: .init(
            refresh: { [weak self] in self?.refresh() },
            writeTestToken: { [weak self] in self?.writeTestToken() }
        ))
        Task { await start() }
    }

    private func start() async {
        if options.debugWriteTestToken { await writeTestTokenNow() }
        await readTestToken()
        let token = await readOcgoToken()
        switch Wiring.ocgoSource(options: options, token: token) {
        case .success(let setup):
            source = setup.source
            statusItem?.setSourceDescription(setup.description)
            log("ocgo source: \(setup.description)")
            refresh()
        case .failure(let error):
            statusItem?.setSourceDescription("none")
            statusItem?.showError(error.description)
            log("ocgo source error: \(error.description)")
        }
    }

    private func refresh() {
        guard let source else { return }
        Task {
            switch await Wiring.poll(source) {
            case .success(let model):
                statusItem?.show(model)
                log("go 5-hour usable: \(StatusText.title(for: model.row(.go)?.fiveHour))")
                writeDebugSnapshot()
            case .failure(let error):
                statusItem?.showError("\(error)")
                log("ocgo poll failed: \(error)")
            }
        }
    }

    private func writeDebugSnapshot() {
        guard let url = options.debugSnapshot, let statusItem else { return }
        let snapshot = statusItem.debugSnapshot()
        log("status item: \(snapshot.description)")
        do {
            try snapshot.png?.write(to: url)
            log("status item snapshot written to \(url.path)")
        } catch {
            log("status item snapshot failed: \(error)")
        }
    }

    private func writeTestToken() {
        Task {
            await writeTestTokenNow()
            await readTestToken()
        }
    }

    /// Writes only the debug account, never the real ocgo token.
    private func writeTestTokenNow() async {
        let value = Self.testTokenPrefix + ISO8601DateFormatter().string(from: Date())
        let keychain = self.keychain
        let result = await Task.detached {
            Result { try keychain.write(value, for: .debugTestToken) }
        }.value
        switch result {
        case .success: log("keychain write ok (\(Keychain.Account.debugTestToken.rawValue)): \(value)")
        case .failure(let e): log("keychain write failed: \(e)")
        }
    }

    /// The debug token, shown in full so a relaunch can be checked against the write.
    private func readTestToken() async {
        let text: String
        switch await readSecret(.debugTestToken) {
        case .success(let token?): text = "found (\(token))"
        case .success(nil): text = "none"
        case .failure(let e): text = "error \(e)"
        }
        statusItem?.setTestTokenDescription(text)
        log("keychain read (\(Keychain.Account.debugTestToken.rawValue)): \(text)")
    }

    /// The real ocgo token. Never shown or logged; only its length.
    private func readOcgoToken() async -> String? {
        let result = await readSecret(.ocgoToken)
        let text: String
        switch result {
        case .success(let token?): text = "found (\(token.count) chars)"
        case .success(nil): text = "none"
        case .failure(let e): text = "error \(e)"
        }
        statusItem?.setTokenDescription(text)
        log("keychain read (\(Keychain.Account.ocgoToken.rawValue)): \(text)")
        return (try? result.get()) ?? nil
    }

    /// Reads off the main thread: SecItemCopyMatching blocks while a prompt is shown.
    private func readSecret(_ account: Keychain.Account) async -> Result<String?, Error> {
        let keychain = self.keychain
        return await Task.detached { Result { try keychain.read(account) } }.value
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("UsageMonitor: \(message)\n".utf8))
    }
}
