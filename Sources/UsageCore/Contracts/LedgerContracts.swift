import Foundation

/// Ledger -> pool engine and forecast.
public protocol LedgerView: Sendable {
    /// Deduplicated by AccountID, with stable alias.
    var accounts: [MergedAccount] { get }
    var routing: [SourceKind: RoutingConfig] { get }
    func latest(_ id: AccountID, _ w: WindowKind) -> WindowReading?
    /// plan.md Pool rule 3: true only with proof that this window was unused since resetAt.
    func resetProven(_ id: AccountID, _ w: WindowKind, resetAt: Date) -> Bool
    func unclassified(_ id: AccountID) -> [UnclassifiedReading]
}

/// The ledger's write side (T4). T8 calls `apply` for every source snapshot and for
/// fork `current`. Readings whose fileKey isn't in the latest credential list are kept
/// in the store but ignored until a credential with that fileKey appears.
///
/// T4's `Ledger` conforms and also has `init(store: HistoryStore, settings: PoolSettings)`
/// (store for `alias(for:)` and restore). The init isn't a protocol requirement so
/// fakes don't need a store.
public protocol LedgerUpdating: LedgerView {
    /// Alias list changes take effect at once.
    func updateSettings(_ settings: PoolSettings)
    func apply(_ s: SourceSnapshot)
    func apply(readings: [SourceReading])
    /// Last snapshots + latestReadings + counter marks.
    func restore() throws
}

/// Pool engine (T3): `PoolEngine.dashboard(ledger:settings:sources:now:)`, a pure
/// function with this type. A provider whose source is `.notConfigured` gets no row.
public typealias DashboardBuilder = @Sendable (
    _ ledger: any LedgerView,
    _ settings: PoolSettings,
    _ sources: [SourceKind: SourceStatus],
    _ now: Date
) -> DashboardModel

public struct CredentialRoute: Equatable, Sendable {
    public let fileKey: String
    public let priority: Int
    public let weight: Int
    public let enabled: Bool
    public let unavailable: [Unavailability]

    public init(fileKey: String, priority: Int, weight: Int, enabled: Bool,
                unavailable: [Unavailability]) {
        self.fileKey = fileKey
        self.priority = priority
        self.weight = weight
        self.enabled = enabled
        self.unavailable = unavailable
    }
}

public struct MergedAccount: Equatable, Sendable {
    public let id: AccountID
    public let alias: String
    public let email: String?
    public let enabled: Bool
    public let unavailable: [Unavailability]
    /// Routing is per credential file.
    public let credentials: [CredentialRoute]
    public let colorIndex: Int

    public init(id: AccountID, alias: String, email: String?, enabled: Bool,
                unavailable: [Unavailability], credentials: [CredentialRoute], colorIndex: Int) {
        self.id = id
        self.alias = alias
        self.email = email
        self.enabled = enabled
        self.unavailable = unavailable
        self.credentials = credentials
        self.colorIndex = colorIndex
    }
}
