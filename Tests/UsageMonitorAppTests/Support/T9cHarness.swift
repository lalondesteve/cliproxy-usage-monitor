import Foundation
import UsageCore
@testable import UsageMonitorApp

let t9cCliproxyURL = URL(string: "http://100.64.0.1:8317")!
let t9cOcgoURL = URL(string: "http://100.64.0.1:8320")!
let t9cSavedSettings = AppSettings(
    cliproxyURL: t9cCliproxyURL, ocgoURL: t9cOcgoURL, menubarStyle: .normal,
    pool: PoolSettings(staleAfter: 1800, identityAliases: ["claude-x@example.com.json": "1a2b3c4d"]))

/// A SetupModel over fakes: saved settings in a private UserDefaults suite, both secrets
/// in a fake store, and a PollControl that records calls.
@MainActor
final class T9cHarness {
    let poll = T9cFakePollControl()
    let secrets: T9cFakeSecretStore
    let suite = T9cDefaults()
    let store: SettingsStore
    let model: SetupModel
    private(set) var savedCallbacks: [AppSettings] = []

    init(settings: AppSettings = t9cSavedSettings,
         secrets: [Keychain.Account: String] = [.cliproxyKey: "old-key", .ocgoToken: "old-token"]) throws {
        self.secrets = T9cFakeSecretStore(secrets)
        store = SettingsStore(defaults: suite.defaults)
        try store.save(settings)
        model = SetupModel(settings: settings, saver: SettingsSaver(
            settingsStore: store, secrets: self.secrets, pollControl: poll))
        model.onSaved = { [unowned self] settings, _ in savedCallbacks.append(settings) }
    }

    func loaded() async -> T9cHarness {
        await model.load()
        return self
    }

    var calls: [T9cFakePollControl.Call] { get async { await poll.calls } }
}
