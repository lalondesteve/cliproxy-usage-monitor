import Foundation
import Security

/// Generic-password items in the login keychain, one per secret. T9c owns and extends
/// this; T1 uses it for the ocgo token and the debug write.
struct Keychain: Sendable {
    static let defaultService = "ca.lals.usage-monitor"

    enum Account: String, Sendable {
        case ocgoToken = "ocgo-token"
        case cliproxyKey = "cliproxy-key"
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
