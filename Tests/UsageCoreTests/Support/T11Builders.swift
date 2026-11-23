import Foundation
import UsageCore

/// 2026-11-22 (a Sunday) at `hh:mm` UTC, or `days` later.
func t11(_ hhmm: String, plusDays days: Int = 0) -> Date {
    date("2026-11-22T\(hhmm):00Z").addingTimeInterval(Double(days) * 24 * 3600)
}

func t11Reading(_ file: String, _ w: WindowKind = .fiveHour, used: Double, resets: Date?,
                at: Date, provider: Provider = .claude,
                source: ReadingSource = .passive) -> SourceReading {
    SourceReading(provider: provider, fileKey: file, window: w, usedPercent: used,
                  resetsAt: resets, observedAt: at, source: source)
}

func t11Route(_ fileKey: String, priority: Int = 0, weight: Int = 1, enabled: Bool = true,
              unavailable: [Unavailability] = []) -> CredentialRoute {
    CredentialRoute(fileKey: fileKey, priority: priority, weight: weight, enabled: enabled,
                    unavailable: unavailable)
}

func t11Routing(_ strategy: RoutingConfig.Strategy, affinity: Bool = false,
                forced: AccountID? = nil) -> RoutingConfig {
    RoutingConfig(strategy: strategy, sessionAffinity: affinity, forcedAccount: forced)
}

extension T3FakeLedgerView {
    /// Adds an account with the given credential routes (default: one route named after
    /// the alias, priority 0, weight 1).
    @discardableResult
    mutating func t11Add(_ provider: Provider, _ alias: String, routes: [CredentialRoute]? = nil,
                         unavailable: [Unavailability] = []) -> AccountID {
        let id = AccountID(provider: provider, identity: alias)
        accounts.append(MergedAccount(
            id: id, alias: alias, email: nil, enabled: true, unavailable: unavailable,
            credentials: routes ?? [t11Route(alias, unavailable: unavailable)],
            colorIndex: accounts.count))
        return id
    }
}
