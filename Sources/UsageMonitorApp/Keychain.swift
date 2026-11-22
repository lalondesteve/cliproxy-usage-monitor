import Foundation
import Security
import UsageCore

/// Where Settings keeps secrets. `Keychain` is the real one; tests use a fake so they
/// never touch the login keychain. Calls may block while macOS shows an access prompt,
/// so callers run them off the main thread.
protocol SecretStore: Sendable {
    func read(_ account: Keychain.Account) throws -> String?
    func write(_ value: String, for account: Keychain.Account) throws
    func delete(_ account: Keychain.Account) throws
}

/// Generic-password items in the login keychain, one per secret. T9c owns and extends
/// this; T1 uses it for the ocgo token and the debug write.
///
/// Access is tied to the app's code signature. An ad-hoc signature pins the cdhash, so
/// every rebuild prompts again; build with a local self-signed identity
/// (`CODESIGN_IDENTITY=... make app`) to keep items readable across rebuilds.
struct Keychain: SecretStore {
    static let defaultService = "ca.lals.usage-monitor"

    enum Account: String, Sendable {
        case ocgoToken = "ocgo-token"
        case cliproxyKey = "cliproxy-key"

        /// The account Settings stores a source's secret under.
        static func secret(for kind: SourceKind) -> Account {
            switch kind {
            case .cliproxy: .cliproxyKey
            case .ocgo: .ocgoToken
            }
        }
        /// The debug menu's test token. Separate from the real secrets so writing it
        /// never overwrites a live credential.
        case debugTestToken = "debug-test-token"
    }

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "OSStatus \(status) (\(message))"
        }
    }

    let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? Keychain.defaultService) {
        self.service = service
    }

    private func query(_ account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    /// nil when no item exists. May block while macOS shows an access prompt, so call
    /// it off the main thread.
    func read(_ account: Account) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure(status: status)
        }
    }

    /// Updates the item, or adds it when missing.
    func write(_ value: String, for account: Account) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure(status: update) }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Usage Monitor (\(account.rawValue))"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func delete(_ account: Account) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(status: status)
        }
    }
}
