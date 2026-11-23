import Foundation

/// plan.md "Pool rules" 1 to 6 and the weekly pace marker, as a pure function from the
/// ledger to the dashboard. Matches `DashboardBuilder`:
/// `let build: DashboardBuilder = PoolEngine.dashboard`.
///
/// - A provider gets a row when its source has a status other than `.notConfigured`
///   and the ledger holds at least one account for it (enabled or not).
/// - Disabled accounts are left out of every gauge, hover list and `total`.
/// - Every row has a 5-hour and a weekly gauge; Go rows also have a monthly one.
/// - Pool rule 4 (usable vs quota) applies to the 5-hour gauge only. In the weekly and
///   monthly gauges `usable == quota` and nothing is greyed.
public enum PoolEngine {
    public static func dashboard(ledger: any LedgerView, settings: PoolSettings,
                                 sources: [SourceKind: SourceStatus], now: Date) -> DashboardModel {
        let all = ledger.accounts
        let rows: [ProviderRow] = Provider.allCases.compactMap { provider in
            guard let status = sources[sourceKind(provider)], status != .notConfigured else {
                return nil
            }
            let accounts = all.filter { $0.id.provider == provider }
            guard !accounts.isEmpty else { return nil }
            return row(provider, accounts: accounts.filter(\.enabled), ledger: ledger,
                       settings: settings, now: now)
        }
        return DashboardModel(generatedAt: now, rows: rows, sources: sources)
    }

    static func sourceKind(_ provider: Provider) -> SourceKind {
        provider == .go ? .ocgo : .cliproxy
    }

    // MARK: - Row

    private static func row(_ provider: Provider, accounts: [MergedAccount],
                            ledger: any LedgerView, settings: PoolSettings,
                            now: Date) -> ProviderRow {
        let windows: [WindowKind] = provider == .go ? [.fiveHour, .weekly, .monthly]
                                                    : [.fiveHour, .weekly]
        // Monthly is read for every provider: it only blocks when a reading exists.
        let states: [[WindowKind: WindowState]] = accounts.map { account in
            Dictionary(uniqueKeysWithValues: WindowKind.allCases.map {
                ($0, WindowState(account, $0, ledger: ledger, now: now))
            })
        }
        let entries = zip(accounts, states).map { account, windowStates in
            Entry(account: account, states: windowStates,
                  blockers: blockers(account, windowStates))
        }
        func gauge(_ w: WindowKind) -> WindowGauge? {
            windows.contains(w)
                ? Self.gauge(w, entries: entries, staleAfter: settings.staleAfter, now: now)
                : nil
        }
        let unclassified = accounts.flatMap { account in
            ledger.unclassified(account.id).map {
                UnclassifiedDetail(alias: account.alias, lengthSeconds: $0.lengthSeconds,
                                   usedPercent: $0.usedPercent, resetsAt: $0.resetsAt,
                                   observedAt: $0.observedAt)
            }
        }
        return ProviderRow(provider: provider, fiveHour: gauge(.fiveHour), weekly: gauge(.weekly),
                           monthly: gauge(.monthly), unclassified: unclassified, forecast: nil)
    }

    /// One enabled account with its windows evaluated.
    private struct Entry {
        let account: MergedAccount
        let states: [WindowKind: WindowState]
        /// Why the account can't take 5-hour traffic now (Pool rule 4). Empty = usable.
        let blockers: [Blocker]

        var usable: Bool { blockers.isEmpty }

        /// When every blocker has ended; nil when any has no known end.
        var blockEnd: Date? {
            var end = Date.distantPast
            for b in blockers {
                guard let until = b.until else { return nil }
                end = max(end, until)
            }
            return end
        }

        var blockedReason: String? {
            blockers.isEmpty ? nil : blockers.map(\.reason).joined(separator: ", ")
        }
    }

    private struct Blocker {
        let reason: String
        let until: Date?
    }

    /// Pool rule 4: unavailable, cooling down, not the forced account, or a longer window
    /// (weekly, monthly) with nothing left.
    private static func blockers(_ account: MergedAccount,
                                 _ states: [WindowKind: WindowState]) -> [Blocker] {
        var result = account.unavailable.map { u -> Blocker in
            switch u {
            case .upstreamUnavailable: Blocker(reason: "unavailable", until: nil)
            case .outOfRotation: Blocker(reason: "out of rotation", until: nil)
            case .exhausted(let until): Blocker(reason: "exhausted", until: until)
            case .coolingDown(let until): Blocker(reason: "cooling down", until: until)
            case .notForcedAccount: Blocker(reason: "not the forced account", until: nil)
            }
        }
        for (w, name) in [(WindowKind.weekly, "weekly"), (.monthly, "monthly")] {
            if let s = states[w], let left = s.remaining, left <= 0 {
                result.append(Blocker(reason: "\(name) limit", until: s.resetsAt))
            }
        }
        return result
    }

    // MARK: - Gauge

    private static func gauge(_ w: WindowKind, entries: [Entry], staleAfter: TimeInterval,
                              now: Date) -> WindowGauge {
        let fiveHour = w == .fiveHour
        let total = entries.count
        let states = entries.map { $0.states[w]! }
        let known = states.filter { $0.remaining != nil }.count

        func range(_ value: (Entry, WindowState) -> (lower: Double, upper: Double))
            -> PercentRange? {
            guard total > 0 else { return nil }
            let sums = zip(entries, states).map(value)
                .reduce((0.0, 0.0)) { ($0.0 + $1.lower, $0.1 + $1.upper) }
            return PercentRange(lower: sums.0 / Double(total), upper: sums.1 / Double(total))
        }
        // Pool rules 1 and 3: unknown counts as 0 and then 100.
        let quota = range { _, s in s.remaining.map { ($0, $0) } ?? (0, 100) }
        let usable = fiveHour
            ? range { e, s in e.usable ? (s.remaining.map { ($0, $0) } ?? (0, 100)) : (0, 0) }
            : quota

        let bars = zip(entries, states).enumerated()
            .compactMap { index, pair -> (Int, GaugeBar)? in
                let (e, s) = pair
                guard let left = s.remaining else { return nil }
                return (index, GaugeBar(alias: e.account.alias, colorIndex: e.account.colorIndex,
                                        remaining: left, greyed: fiveHour && !e.usable))
            }
            .sorted { $0.1.remaining != $1.1.remaining ? $0.1.remaining > $1.1.remaining
                                                       : $0.0 < $1.0 }
            .map(\.1)

        let details = zip(entries, states).map { e, s in
            AccountDetail(
                alias: e.account.alias, email: e.account.email,
                remaining: s.remaining, previous: s.previous,
                resetsAt: s.resetsAt, observedAt: s.observedAt,
                // Unknown now: the hover's age is the previous reading's.
                stale: (s.observedAt ?? s.previous?.observedAt)
                    .map { now.timeIntervalSince($0) > staleAfter } ?? false,
                usable: fiveHour ? e.usable : true,
                blockedReason: fiveHour ? e.blockedReason : nil)
        }

        let allFull = fiveHour && total > 0
            && zip(entries, states).allSatisfy { e, s in e.usable && s.remaining == 100 }

        return WindowGauge(
            window: w, known: known, total: total, quota: quota, usable: usable, bars: bars,
            nextRefill: fiveHour ? nextRefill(entries, total: total, now: now) : nil,
            allFull: allFull,
            pace: w == .weekly ? pace(states, now: now) : nil,
            accounts: details)
    }

    /// Pool rule 5: the first moment usable 5-hour quota rises. A usable account refills
    /// at its own 5-hour reset; a blocked one when its block ends, to 100 if its 5-hour
    /// reset falls before then, else to its current level; an account still empty when
    /// its block ends refills at its later 5-hour reset. Unknown accounts are skipped.
    private static func nextRefill(_ entries: [Entry], total: Int,
                                   now: Date) -> WindowGauge.NextRefill? {
        var events: [(at: Date, gain: Double)] = []
        for e in entries {
            guard let s = e.states[.fiveHour], let left = s.remaining else { continue }
            if e.usable {
                if left < 100, let reset = s.resetsAt, reset > now {
                    events.append((reset, 100 - left))
                }
            } else if let end = e.blockEnd, end > now {
                let level = s.resetsAt.map { $0 <= end } == true ? 100 : left
                if level > 0 {
                    events.append((end, level))
                } else if let reset = s.resetsAt, reset > end {
                    // Empty when the block ends: usable quota first rises at its reset.
                    events.append((reset, 100))
                }
            }
        }
        guard let first = events.map(\.at).min(), total > 0 else { return nil }
        let gain = events.filter { $0.at == first }.reduce(0) { $0 + $1.gain }
        return WindowGauge.NextRefill(at: first, poolGain: gain / Double(total))
    }

    /// plan.md "Weekly gauge": mean over known accounts of the share of each account's
    /// week still to go. Counted as reset, or unset reset at 0% used, gives 1; a known
    /// account with usage and no reset time hides the marker.
    private static func pace(_ states: [WindowState], now: Date) -> Double? {
        let week: TimeInterval = 7 * 24 * 3600
        var shares: [Double] = []
        for s in states {
            guard let left = s.remaining else { continue }
            if s.countedAsReset {
                shares.append(1)
            } else if let reset = s.resetsAt {
                shares.append(min(max(reset.timeIntervalSince(now) / week, 0), 1))
            } else if left >= 100 {
                shares.append(1)
            } else {
                return nil
            }
        }
        return shares.isEmpty ? nil : shares.reduce(0, +) / Double(shares.count)
    }
}

extension PoolEngine {
    /// One account's window after Pool rule 3.
    fileprivate struct WindowState {
        /// nil = unknown.
        let remaining: Double?
        /// The old value when a past reset couldn't be proven.
        let previous: AccountDetail.Previous?
        /// nil when unset or when the window was counted as reset (next reset not known).
        let resetsAt: Date?
        /// The reading's time; nil when unknown.
        let observedAt: Date?
        let countedAsReset: Bool

        init(_ account: MergedAccount, _ w: WindowKind, ledger: any LedgerView, now: Date) {
            guard let r = ledger.latest(account.id, w)?.reading else {
                self.init(remaining: nil, previous: nil, resetsAt: nil, observedAt: nil,
                          countedAsReset: false)
                return
            }
            let left = min(max(100 - r.usedPercent, 0), 100)
            if let reset = r.resetsAt, reset <= now {
                if ledger.resetProven(account.id, w, resetAt: reset) {
                    self.init(remaining: 100, previous: nil, resetsAt: nil, observedAt: r.observedAt,
                              countedAsReset: true)
                } else {
                    self.init(remaining: nil,
                              previous: AccountDetail.Previous(value: left, observedAt: r.observedAt),
                              resetsAt: reset, observedAt: nil, countedAsReset: false)
                }
                return
            }
            self.init(remaining: left, previous: nil, resetsAt: r.resetsAt,
                      observedAt: r.observedAt, countedAsReset: false)
        }

        private init(remaining: Double?, previous: AccountDetail.Previous?, resetsAt: Date?,
                     observedAt: Date?, countedAsReset: Bool) {
            self.remaining = remaining
            self.previous = previous
            self.resetsAt = resetsAt
            self.observedAt = observedAt
            self.countedAsReset = countedAsReset
        }
    }
}
