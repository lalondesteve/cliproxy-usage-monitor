import Foundation
import UsageCore

/// `AppSettings` in UserDefaults, as one JSON value. Secrets are not here; they live in
/// the Keychain (`SecretStore`).
///
/// `@unchecked`: UserDefaults isn't marked Sendable, but Apple documents it as safe to
/// use from any thread, and this type holds nothing else.
struct SettingsStore: @unchecked Sendable {
    static let key = "appSettings"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// nil when nothing was saved yet (first launch) or the stored value can't be read.
    func load() -> AppSettings? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    func save(_ settings: AppSettings) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: Self.key)
    }
}

extension AppSettings {
    /// A source is configured when it has a URL. With no ocgo URL the integrator passes
    /// `.notConfigured` for ocgo, so the Go row is hidden.
    func isConfigured(_ kind: SourceKind) -> Bool {
        switch kind {
        case .cliproxy: cliproxyURL != nil
        case .ocgo: ocgoURL != nil
        }
    }

    var ocgoConfigured: Bool { isConfigured(.ocgo) }
}
