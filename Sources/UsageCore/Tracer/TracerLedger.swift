import Foundation

// T1 tracer only. A `LedgerView` over one source snapshot, so the tracer runs
// source -> LedgerView -> dashboard -> status item through the contract types.
// Replaced by T4's `Ledger`; delete this folder when T3 and T4 land (T10).

public struct TracerLedger: LedgerView {
    private let snapshot: SourceSnapshot

    public init(snapshot: SourceSnapshot) {
        self.snapshot = snapshot
    }

    public var accounts: [MergedAccount] {
        snapshot.accounts.enumerated().map { index, a in
            MergedAccount(
                id: a.id,
                alias: a.fileKey,
                email: a.email,
                enabled: a.enabled,
                unavailable: a.unavailable,
                credentials: [CredentialRoute(
                    fileKey: a.fileKey,
                    priority: a.routing?.priority ?? 0,
                    weight: a.routing?.weight ?? 1,
                    enabled: a.enabled,
                    unavailable: a.unavailable
                )],
                colorIndex: index
            )
        }
    }

    public var routing: [SourceKind: RoutingConfig] {
        snapshot.routing.map { [snapshot.source: $0] } ?? [:]
    }

    public func latest(_ id: AccountID, _ w: WindowKind) -> WindowReading? {
        let fileKeys = Set(snapshot.accounts.filter { $0.id == id }.map(\.fileKey))
        return snapshot.readings
            .filter { $0.provider == id.provider && $0.window == w && fileKeys.contains($0.fileKey) }
            .max { $0.observedAt < $1.observedAt }
            .map { WindowReading(account: id, reading: $0) }
    }

    public func resetProven(_ id: AccountID, _ w: WindowKind, resetAt: Date) -> Bool {
        false
    }

    public func unclassified(_ id: AccountID) -> [UnclassifiedReading] {
        []
    }
}
