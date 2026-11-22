import Foundation
import UsageCore

/// A `LedgerView` built by hand for the pool engine tests. `resetProven` answers only
/// for the exact (account, window, resetAt) it was given, so a wrong `resetAt` reads
/// as "no proof".
struct T3FakeLedgerView: LedgerView {
    struct ProofKey: Hashable {
        let id: AccountID
        let window: WindowKind
        let resetAt: Date
    }

    var accounts: [MergedAccount] = []
    var routing: [SourceKind: RoutingConfig] = [:]
    var readings: [AccountID: [WindowKind: SourceReading]] = [:]
    var proofs: [ProofKey: Bool] = [:]
    var unclassifiedReadings: [AccountID: [UnclassifiedReading]] = [:]

    func latest(_ id: AccountID, _ w: WindowKind) -> WindowReading? {
        readings[id]?[w].map { WindowReading(account: id, reading: $0) }
    }

    func resetProven(_ id: AccountID, _ w: WindowKind, resetAt: Date) -> Bool {
        proofs[ProofKey(id: id, window: w, resetAt: resetAt)] ?? false
    }

    func unclassified(_ id: AccountID) -> [UnclassifiedReading] {
        unclassifiedReadings[id] ?? []
    }

    // MARK: Building

    /// Adds an account named `alias` (also its identity and fileKey) and returns its id.
    @discardableResult
    mutating func add(_ provider: Provider, _ alias: String, enabled: Bool = true,
                      unavailable: [Unavailability] = [], email: String? = nil) -> AccountID {
        let id = AccountID(provider: provider, identity: alias)
        accounts.append(MergedAccount(
            id: id, alias: alias, email: email, enabled: enabled, unavailable: unavailable,
            credentials: [CredentialRoute(fileKey: alias, priority: 0, weight: 1,
                                          enabled: enabled, unavailable: unavailable)],
            colorIndex: accounts.count))
        return id
    }

    mutating func set(_ id: AccountID, _ w: WindowKind, used: Double, resets: Date? = nil,
                      at observedAt: Date) {
        readings[id, default: [:]][w] = SourceReading(
            provider: id.provider, fileKey: id.identity, window: w, usedPercent: used,
            resetsAt: resets, observedAt: observedAt,
            source: id.provider == .go ? .ocgo : .passive)
    }

    mutating func prove(_ id: AccountID, _ w: WindowKind, resetAt: Date, _ answer: Bool) {
        proofs[ProofKey(id: id, window: w, resetAt: resetAt)] = answer
    }
}
