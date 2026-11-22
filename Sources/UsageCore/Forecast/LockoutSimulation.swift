import Foundation

/// T11b. Forward simulation of the 5-hour window, per minute, over the next 5 hours
/// (plan.md "Forecast").
///
/// Model, one quota balance per subscription (`MergedAccount`):
/// - Start: each enabled account's 5-hour remaining after Pool rule 3, with its reset.
///   An account at 100% with an unset reset (or counted as reset) is idle: its next
///   window starts on first use and resets 5 hours later. Weekly and monthly readings
///   aren't drained; one with nothing left blocks the account until its reset, and
///   their remaining caps the headroom under most-headroom routing.
/// - Each minute, resets due by the minute's start apply first. Demand
///   (account-% per hour, the undivided sum of the account rates) then goes to the
///   enabled credential routes that are usable at that time: per-credential
///   `unavailable` reasons with an end date (`exhausted`, `coolingDown`) lift at that
///   date, the others last the whole run; an account blocked by a longer window or at
///   0% left takes nothing; with `forcedAccount` set only that account takes traffic.
/// - Routing: the highest priority tier with a usable credential first, then by
///   strategy. Round-robin splits per credential (an account with two usable
///   credentials gets two shares), weighted round-robin per credential weight,
///   fill-first sends everything to the first usable credential by `fileKey`, and
///   most-headroom levels the accounts with the most headroom (5-hour remaining capped
///   by the weekly and monthly remaining) down together. Demand an account can't take
///   because it ran out within the minute moves to the others, then to the next tier.
/// - A minute that starts with no usable account is a lockout minute. A lockout still
///   running at the end of the 5 hours ends at the earliest known recovery date of any
///   account; with none, the forecast is `.insufficientData` rather than a made-up end.
/// - Zero demand is safe while some known account is usable now, even if another
///   account is unknown; a pool already locked out reports that lockout.
/// - An account with an unknown 5-hour window that can't take traffic within the 5
///   hours (blocked past their end) is left out instead of making the forecast
///   `.insufficientData`. If it unblocks before the end found for a lockout still
///   running at the end of the 5 hours, that end is unknown (it might take traffic
///   earlier), so the forecast is `.insufficientData` for that lockout.
///
/// Withheld when the routing isn't one the simulation models: no routing reported for
/// the provider's source, or session affinity on.
public enum LockoutSimulation {
    public static let horizon: TimeInterval = 5 * 3600
    public static let step: TimeInterval = 60
    public static let windowLength: TimeInterval = 5 * 3600

    static let epsilon = 1e-9

    /// The forecast for `provider`: the first lockout within the horizon, `.safe`
    /// when there is none, `.insufficientData` without a demand, when an account that
    /// could take traffic has an unknown 5-hour window, or when the first lockout has no
    /// known end.
    public static func forecast(_ provider: Provider, ledger: any LedgerView,
                                demandPerHour: Double?, now: Date) -> LockoutForecast {
        switch prepare(provider, ledger: ledger, now: now) {
        case .withheld(let reason):
            return .withheld(reason: reason)
        case .unknown:
            return .insufficientData
        case .ready(var state):
            guard let demand = demandPerHour else { return .insufficientData }
            // Zero demand drains nothing: safe while a known account is usable now,
            // whatever the unknown ones hold.
            if demand <= 0, !state.usable(at: now).isEmpty { return .safe }
            if state.unknownInPlay { return .insufficientData }
            // A pool with no usable account now is locked out until its first recovery,
            // even at zero demand.
            return state.run(demandPerHour: max(demand, 0)).forecast
        }
    }

    /// Every lockout that starts within the horizon, each to its recovery. nil when the
    /// forecast is withheld or lacks data, or when the last lockout has no known end.
    public static func lockouts(_ provider: Provider, ledger: any LedgerView,
                                demandPerHour: Double, now: Date) -> [DateInterval]? {
        guard case .ready(var state) = prepare(provider, ledger: ledger, now: now) else {
            return nil
        }
        // Same zero-demand rule as `forecast`: nothing drains, so a known account usable
        // now stays usable and there is no lockout, whatever the unknown ones hold.
        if demandPerHour <= 0, !state.usable(at: now).isEmpty { return [] }
        guard !state.unknownInPlay else { return nil }
        let outcome = state.run(demandPerHour: max(demandPerHour, 0))
        return outcome.unended == nil ? outcome.runs : nil
    }

    /// Where demand goes at `now`: each account's share of one unit, before any
    /// account runs out. Empty when withheld or unknown.
    static func shares(_ provider: Provider, ledger: any LedgerView,
                       now: Date) -> [AccountID: Double] {
        guard case .ready(var state) = prepare(provider, ledger: ledger, now: now),
              !state.unknownInPlay else {
            return [:]
        }
        let before = state.accounts.map(\.level)
        let unit = 1e-3
        _ = state.allocate(unit, at: now)
        var result: [AccountID: Double] = [:]
        for (i, a) in state.accounts.enumerated() where before[i] - a.level > 0 {
            result[a.id] = (before[i] - a.level) / unit
        }
        return result
    }

    // MARK: - Setup

    enum Prepared {
        case withheld(String)
        case unknown
        case ready(State)
    }

    static func prepare(_ provider: Provider, ledger: any LedgerView, now: Date) -> Prepared {
        guard let routing = ledger.routing[provider == .go ? .ocgo : .cliproxy] else {
            return .withheld("routing unknown")
        }
        if routing.sessionAffinity { return .withheld("session affinity is on") }

        let enabled = ledger.accounts.filter { $0.id.provider == provider && $0.enabled }
        guard !enabled.isEmpty else { return .unknown }

        var accounts: [SimAccount] = []
        var unknownInPlay = false
        var skippedUnblock: Date?
        let end = now.addingTimeInterval(horizon)
        for account in enabled {
            let forcedOut = routing.forcedAccount.map { $0 != account.id } ?? false
            let credentials = account.credentials.compactMap { c -> SimCredential? in
                guard !forcedOut, let from = usableFrom(c, strategy: routing.strategy) else {
                    return nil
                }
                return SimCredential(fileKey: c.fileKey, priority: c.priority,
                                     weight: routing.strategy == .weightedRoundRobin ? Double(c.weight) : 1,
                                     usableFrom: from)
            }
            var longer: [Longer] = []
            for w in [WindowKind.weekly, .monthly] {
                let s = ForecastWindow(ledger, account.id, w, now: now)
                if let left = s.remaining { longer.append(Longer(remaining: left, resetsAt: s.resetsAt)) }
            }
            // Never usable: no credential that can take traffic, or a longer window at 0
            // with no known reset. Its 5-hour state doesn't matter.
            if credentials.isEmpty
                || longer.contains(where: { $0.remaining <= epsilon && $0.resetsAt == nil }) {
                continue
            }
            let fiveHour = ForecastWindow(ledger, account.id, .fiveHour, now: now)
            guard let level = fiveHour.remaining else {
                // Unknown, but blocked past the horizon (no credential usable before its
                // end, or a longer window at 0 resetting after it): it takes no traffic
                // in this run, so leave it out instead of giving up on the forecast, and
                // remember when it unblocks (the latest of its earliest credential and
                // the resets of its blocking windows, all known here).
                let blocks = longer.filter { $0.remaining <= epsilon }.compactMap(\.resetsAt)
                let unblock = ([credentials.map(\.usableFrom).min()!] + blocks).max()!
                if unblock >= end {
                    skippedUnblock = min(skippedUnblock ?? unblock, unblock)
                } else {
                    unknownInPlay = true
                }
                continue
            }
            accounts.append(SimAccount(
                id: account.id, level: level, reset: fiveHour.resetsAt,
                fresh: level >= 100 && fiveHour.resetsAt == nil,
                longer: longer, credentials: credentials))
        }
        return .ready(State(strategy: routing.strategy, now: now, accounts: accounts,
                            unknownInPlay: unknownInPlay, skippedUnblock: skippedUnblock))
    }

    /// When a credential can first take traffic; nil when not in this run.
    private static func usableFrom(_ c: CredentialRoute, strategy: RoutingConfig.Strategy) -> Date? {
        guard c.enabled else { return nil }
        if strategy == .weightedRoundRobin && c.weight <= 0 { return nil }
        var from = Date.distantPast
        for reason in c.unavailable {
            switch reason {
            case .upstreamUnavailable, .outOfRotation, .notForcedAccount:
                return nil
            case .exhausted(let until), .coolingDown(let until):
                guard let until else { return nil }
                from = max(from, until)
            }
        }
        return from
    }

    // MARK: - State

    struct SimCredential {
        let fileKey: String
        let priority: Int
        let weight: Double
        let usableFrom: Date
    }

    struct Longer {
        var remaining: Double
        var resetsAt: Date?
    }

    struct SimAccount {
        let id: AccountID
        /// 5-hour remaining, 0...100.
        var level: Double
        var reset: Date?
        /// Full and idle: the next use starts a window.
        var fresh: Bool
        var longer: [Longer]
        let credentials: [SimCredential]

        var cap: Double { longer.map(\.remaining).min() ?? .infinity }
        var headroom: Double { min(level, cap) }
    }

    struct State {
        let strategy: RoutingConfig.Strategy
        let now: Date
        var accounts: [SimAccount]
        /// An account that could take traffic in the horizon has an unknown 5-hour
        /// window: only zero demand with a usable account now gives an answer (`.safe`).
        var unknownInPlay = false
        /// The earliest unblock among unknown accounts left out as blocked past the
        /// horizon.
        var skippedUnblock: Date?

        /// The lockouts found by a run. `unended` is the start of a lockout still
        /// running at the end of the horizon with no known recovery date.
        struct Outcome {
            let runs: [DateInterval]
            let unended: Date?

            var forecast: LockoutForecast {
                if let first = runs.first { return .lockout(from: first.start, to: first.end) }
                return unended == nil ? .safe : .insufficientData
            }
        }

        /// Runs the minutes of the horizon. A lockout still running at its end ends at
        /// the earliest known recovery (`recovery(notBefore:)`): nothing drains while
        /// locked out, so only resets and block ends can lift it.
        mutating func run(demandPerHour: Double) -> Outcome {
            let perStep = demandPerHour * step / 3600
            let steps = Int(horizon / step)
            var runs: [DateInterval] = []
            var runStart: Date?
            for i in 0..<steps {
                let t = now.addingTimeInterval(Double(i) * step)
                applyResets(at: t)
                if usable(at: t).isEmpty {
                    if runStart == nil { runStart = t }
                } else {
                    if let start = runStart {
                        runs.append(DateInterval(start: start, end: t))
                        runStart = nil
                    }
                    _ = allocate(perStep, at: t)
                }
            }
            guard let start = runStart else { return Outcome(runs: runs, unended: nil) }
            // An unknown account unblocking before that end might take traffic and end
            // the lockout sooner: the end isn't known then.
            guard let end = recovery(notBefore: now.addingTimeInterval(Double(steps) * step)),
                  skippedUnblock.map({ $0 >= end }) ?? true else {
                return Outcome(runs: runs, unended: start)
            }
            return Outcome(runs: runs + [DateInterval(start: start, end: end)], unended: nil)
        }

        /// While locked out: the earliest time an account can take traffic again, from
        /// known dates only (its 5-hour reset when empty, the reset of a longer window
        /// at 0, the end of a credential's cooldown or exhaustion). An account missing
        /// any of the dates it needs gives nothing; nil when no account gives a date.
        func recovery(notBefore t: Date) -> Date? {
            accounts.compactMap { a -> Date? in
                guard var at = a.credentials.map(\.usableFrom).min() else { return nil }
                at = max(at, t)
                if a.level <= epsilon {
                    guard let reset = a.reset else { return nil }
                    at = max(at, reset)
                }
                for l in a.longer where l.remaining <= epsilon {
                    guard let reset = l.resetsAt else { return nil }
                    at = max(at, reset)
                }
                return at
            }.min()
        }

        mutating func applyResets(at t: Date) {
            for i in accounts.indices {
                if let r = accounts[i].reset, r <= t {
                    accounts[i].level = 100
                    accounts[i].reset = nil
                    accounts[i].fresh = true
                }
                for j in accounts[i].longer.indices {
                    if let r = accounts[i].longer[j].resetsAt, r <= t {
                        accounts[i].longer[j] = Longer(remaining: 100, resetsAt: nil)
                    }
                }
            }
        }

        /// (account index, credential) pairs that can take traffic at `t`.
        func usable(at t: Date) -> [(account: Int, credential: SimCredential)] {
            var result: [(Int, SimCredential)] = []
            for (i, a) in accounts.enumerated()
            where a.level > epsilon && !a.longer.contains(where: { $0.remaining <= epsilon }) {
                for c in a.credentials where c.usableFrom <= t {
                    result.append((i, c))
                }
            }
            return result
        }

        /// Takes `amount` from the usable accounts by routing; returns what nobody
        /// could take. Starts a window on an idle account's first use.
        mutating func allocate(_ amount: Double, at t: Date) -> Double {
            let routes = usable(at: t)
            let before = accounts.map(\.level)
            var left = amount
            if strategy == .fillFirst {
                let order = routes.sorted {
                    $0.credential.priority != $1.credential.priority
                        ? $0.credential.priority > $1.credential.priority
                        : $0.credential.fileKey < $1.credential.fileKey
                }
                for r in order where left > epsilon {
                    let take = min(accounts[r.account].level, left)
                    accounts[r.account].level -= take
                    left -= take
                }
            } else {
                let tiers = Set(routes.map(\.credential.priority)).sorted(by: >)
                for tier in tiers where left > epsilon {
                    var weights: [Int: Double] = [:]
                    for r in routes where r.credential.priority == tier && r.credential.weight > 0 {
                        weights[r.account, default: 0] += r.credential.weight
                    }
                    left = strategy == .mostHeadroom
                        ? levelDown(left, among: Array(weights.keys))
                        : proportional(left, weights: weights)
                }
            }
            for i in accounts.indices where accounts[i].level < before[i] {
                if accounts[i].level < epsilon { accounts[i].level = 0 }
                if accounts[i].fresh {
                    accounts[i].fresh = false
                    accounts[i].reset = t.addingTimeInterval(windowLength)
                }
            }
            return left
        }

        /// Round-robin and weighted: split by weight; an account that runs out passes
        /// the rest of its share on.
        private mutating func proportional(_ amount: Double, weights: [Int: Double]) -> Double {
            var left = amount
            var active = weights.filter { accounts[$0.key].level > epsilon }
            while left > epsilon, !active.isEmpty {
                let total = active.values.reduce(0, +)
                let short = active.filter { accounts[$0.key].level <= left * $0.value / total }
                if short.isEmpty {
                    for (i, w) in active { accounts[i].level -= left * w / total }
                    return 0
                }
                for i in short.keys {
                    left -= accounts[i].level
                    accounts[i].level = 0
                    active[i] = nil
                }
            }
            return max(left, 0)
        }

        /// Most-headroom: lower the accounts with the most headroom together. An
        /// account whose 5-hour remaining is above its cap keeps its headroom while
        /// that surplus drains, so it takes demand first among its peers.
        private mutating func levelDown(_ amount: Double, among indices: [Int]) -> Double {
            var left = amount
            while left > epsilon {
                let candidates = indices.filter { accounts[$0].level > epsilon }
                guard let top = candidates.map({ accounts[$0].headroom }).max() else { break }
                let group = candidates.filter { accounts[$0].headroom >= top - epsilon }
                let surplus = group.filter { accounts[$0].level - accounts[$0].cap > epsilon }
                if !surplus.isEmpty {
                    let room = surplus.map { accounts[$0].level - accounts[$0].cap }.min()!
                    let each = min(left / Double(surplus.count), room)
                    for i in surplus { accounts[i].level -= each }
                    left -= each * Double(surplus.count)
                    continue
                }
                let next = candidates.filter { !group.contains($0) }
                    .map { accounts[$0].headroom }.max() ?? 0
                let cost = Double(group.count) * (top - next)
                if left <= cost {
                    for i in group { accounts[i].level -= left / Double(group.count) }
                    return 0
                }
                for i in group { accounts[i].level = next }
                left -= cost
            }
            return max(left, 0)
        }
    }
}
