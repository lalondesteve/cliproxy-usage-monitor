import Foundation

// T1 tracer only: plan.md Pool rule 1 (mean of 100 - used% over enabled accounts) for
// the 5-hour window, with unknown accounts giving the rule 3 range. No usable/quota
// split, staleness, resets, refill or other windows. Replaced by T3's
// `PoolEngine.dashboard`; it has the same signature (`DashboardBuilder`).

public enum TracerPool {
    public static let dashboard: DashboardBuilder = { ledger, _, sources, now in
        let rows: [ProviderRow] = Provider.allCases.compactMap { provider in
            let kind: SourceKind = provider == .go ? .ocgo : .cliproxy
            guard let status = sources[kind], status != .notConfigured else { return nil }
            let accounts = ledger.accounts.filter { $0.id.provider == provider && $0.enabled }
            guard !accounts.isEmpty else { return nil }
            return ProviderRow(
                provider: provider,
                fiveHour: fiveHourGauge(accounts: accounts, ledger: ledger),
                weekly: nil,
                monthly: nil,
                unclassified: [],
                forecast: nil
            )
        }
        return DashboardModel(generatedAt: now, rows: rows, sources: sources)
    }

    static func fiveHourGauge(accounts: [MergedAccount], ledger: any LedgerView) -> WindowGauge {
        let remaining: [(MergedAccount, WindowReading?)] = accounts.map {
            ($0, ledger.latest($0.id, .fiveHour))
        }
        let known = remaining.compactMap { a, r in r.map { (a, 100 - $0.reading.usedPercent) } }
        let total = accounts.count
        let unknown = total - known.count
        let knownSum = known.reduce(0) { $0 + $1.1 }
        let range = PercentRange(lower: knownSum / Double(total),
                                 upper: (knownSum + 100 * Double(unknown)) / Double(total))
        let bars = known
            .map { GaugeBar(alias: $0.0.alias, colorIndex: $0.0.colorIndex, remaining: $0.1, greyed: false) }
            .sorted { $0.remaining > $1.remaining }
        let details = remaining.map { a, r in
            AccountDetail(
                alias: a.alias, email: a.email,
                remaining: r.map { 100 - $0.reading.usedPercent },
                previous: nil,
                resetsAt: r?.reading.resetsAt,
                observedAt: r?.reading.observedAt,
                stale: false, usable: true, blockedReason: nil
            )
        }
        return WindowGauge(
            window: .fiveHour, known: known.count, total: total,
            quota: range, usable: range, bars: bars, nextRefill: nil,
            allFull: unknown == 0 && known.allSatisfy { $0.1 >= 100 },
            pace: nil, accounts: details
        )
    }
}
