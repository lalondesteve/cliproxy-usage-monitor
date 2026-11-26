import Foundation
import UsageCore

/// Clock and zone for every time the dropdown prints. Tests and PNG renders fix both.
struct DropdownClock: Sendable {
    var now: Date
    var timeZone: TimeZone = .current
}

/// Every string the dropdown shows, as pure functions of the model.
enum DropdownText {
    static func providerName(_ p: Provider) -> String {
        switch p {
        case .claude: "Claude"
        case .codex: "Codex"
        case .go: "Go"
        }
    }

    static func sourceName(_ k: SourceKind) -> String {
        switch k {
        case .cliproxy: "cliproxy"
        case .ocgo: "ocgo"
        }
    }

    /// The source that feeds a provider (Claude and Codex come through cliproxy).
    static func source(for p: Provider) -> SourceKind {
        p == .go ? .ocgo : .cliproxy
    }

    /// "48%", or a range with unknown accounts: "41-74%".
    static func percent(_ r: PercentRange?) -> String {
        guard let r else { return "--" }
        let lower = Int(r.lower.rounded())
        let upper = Int(r.upper.rounded())
        return lower == upper ? "\(lower)%" : "\(lower)-\(upper)%"
    }

    static func percent(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    /// The number beside a line: the usable share for the 5-hour window (as in the
    /// menubar), the quota for weekly and monthly ("59% left across 3").
    static func headline(_ g: WindowGauge?) -> String {
        guard let g else { return "--" }
        return percent(g.window == .fiveHour ? g.usable : g.quota)
    }

    /// Bottom right of the 5-hour line: "reset in 5h" when every enabled account is
    /// full and usable, else the time to `nextRefill`, else nothing.
    static func countdown(_ g: WindowGauge?, now: Date) -> String? {
        guard let g else { return nil }
        if g.allFull { return "reset in 5h" }
        guard let refill = g.nextRefill else { return nil }
        let seconds = refill.at.timeIntervalSince(now)
        guard seconds > 0 else { return "reset due" }
        return "reset in " + duration(minutes: Int((seconds / 60).rounded(.up)))
    }

    /// Under the weekly percent: "reset in 2d 3h" to the soonest weekly reset still
    /// ahead among the window's accounts; nil when none is known.
    static func resetCountdown(_ g: WindowGauge?, now: Date) -> String? {
        guard let next = g?.accounts.compactMap(\.resetsAt).filter({ $0 > now }).min() else {
            return nil
        }
        return "reset in " + duration(minutes: Int((next.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// "40m", "1h 05m", "5h", "2d 3h".
    static func duration(minutes m: Int) -> String {
        let m = max(0, m)
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h >= 24 { return h % 24 == 0 ? "\(h / 24)d" : "\(h / 24)d \(h % 24)h" }
        return m % 60 == 0 ? "\(h)h" : "\(h)h " + String(format: "%02dm", m % 60)
    }

    /// "usable 38%, quota 55%" when the two differ as printed.
    static func usableAndQuota(_ g: WindowGauge?) -> String? {
        guard let g, let usable = g.usable, let quota = g.quota else { return nil }
        let u = percent(usable), q = percent(quota)
        return u == q ? nil : "usable \(u), quota \(q)"
    }

    /// "2 of 3 known" while some account is unknown.
    static func known(_ g: WindowGauge?) -> String? {
        guard let g else { return nil }
        if g.total == 0 { return "no enabled accounts" }
        return g.known < g.total ? "\(g.known) of \(g.total) known" : nil
    }

    /// The oldest reading behind the number: the number is only as fresh as that.
    static func oldestReading(_ g: WindowGauge?) -> Date? {
        g?.accounts.compactMap { $0.remaining == nil ? nil : $0.observedAt }.min()
    }

    /// Whether a reading behind the number is stale: contributing (known) accounts
    /// only, matching `oldestReading`. An unknown account with an old previous value
    /// is marked in its own hover line instead.
    static func isStale(_ g: WindowGauge?) -> Bool {
        g?.accounts.contains { $0.remaining != nil && $0.stale } ?? false
    }

    /// "just now", "3m ago", "2h 05m ago", "3d ago".
    static func age(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes >= 24 * 60 { return "\(minutes / (24 * 60))d ago" }
        return duration(minutes: minutes) + " ago"
    }

    /// "14:10" today, "Thu 09:00" on another day.
    static func clock(_ date: Date, _ c: DropdownClock) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = c.timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = c.timeZone
        f.dateFormat = cal.isDate(date, inSameDayAs: c.now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }

    /// "resets 14:10"; a reset already past (not proven, so the value stayed unknown
    /// or old) reads "reset 12:00 passed".
    static func reset(_ date: Date, _ c: DropdownClock) -> String {
        date > c.now ? "resets \(clock(date, c))" : "reset \(clock(date, c)) passed"
    }

    /// "+27% of pool"
    static func poolGain(_ gain: Double) -> String { "+\(Int(gain.rounded()))% of pool" }

    /// Unclassified readings: "no window length", "1h 30m window".
    static func windowLength(_ seconds: Int?) -> String {
        guard let seconds else { return "no window length" }
        return duration(minutes: seconds / 60) + " window"
    }

    static func error(_ e: SourceError) -> String {
        switch e {
        case .unauthorized: "unauthorized"
        case .remoteManagementDisabled: "remote management disabled"
        case .ipBanned: "IP banned"
        case .tlsUntrusted: "TLS certificate not trusted"
        case .timeout: "timed out"
        case .unreachable: "unreachable"
        case .http(let code): "HTTP \(code)"
        case .decoding: "unexpected response"
        }
    }

    enum Severity: Equatable { case normal, warning, error }

    static func sourceStatus(_ k: SourceKind, _ s: SourceStatus, _ c: DropdownClock)
        -> (text: String, severity: Severity) {
        let name = sourceName(k)
        switch s {
        case .ok(let at):
            return ("\(name): updated \(age(at, now: c.now))", .normal)
        case .authStopped(let e):
            return ("\(name): \(error(e)), polling stopped. Fix it in Setup.", .error)
        case .failing(let e, let since):
            return ("\(name): \(error(e)) since \(clock(since, c)), retrying", .warning)
        case .notConfigured:
            return ("\(name): not configured", .normal)
        }
    }

    // MARK: Forecast (plan.md "Forecast": text only)

    /// The 5-hour lockout forecast: "safe for 5h", "lockout at 17:09 to 17:20", or why
    /// there is none. When a clock change falls between the two times, both carry
    /// their zone ("lockout at 01:50 EDT to 01:20 EST") so the order stays clear.
    static func lockout(_ l: LockoutForecast, _ c: DropdownClock) -> String {
        switch l {
        case .safe:
            return "safe for 5h"
        case .lockout(let from, let to):
            guard c.timeZone.secondsFromGMT(for: from) != c.timeZone.secondsFromGMT(for: to) else {
                return "lockout at \(clock(from, c)) to \(clock(to, c))"
            }
            return "lockout at \(clock(from, c)) \(zone(from, c)) to \(clock(to, c)) \(zone(to, c))"
        case .withheld(let reason):
            return "no lockout forecast: \(reason)"
        case .insufficientData:
            return "no lockout forecast yet: not enough readings"
        }
    }

    /// The zone's abbreviation at `date`: "EDT", or "GMT+9" where there is none.
    static func zone(_ date: Date, _ c: DropdownClock) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = c.timeZone
        f.dateFormat = "zzz"
        return f.string(from: date)
    }

    /// A pool-share rate as printed: "18%", or "<1%" for a rate that rounds to 0 but
    /// isn't 0.
    static func burnPercent(_ perHour: Double) -> String {
        perHour > 0 && perHour < 0.5 ? "<1%" : percent(perHour)
    }

    /// The pool-share burn rate under the 5-hour line: "burn 18%/h", "burn <1%/h".
    static func burn(_ perHour: Double) -> String { "burn \(burnPercent(perHour))/h" }

    /// Under the 5-hour line: "burn 18%/h · lockout at 17:09 to 17:20".
    static func forecastLine(_ f: ForecastSummary, _ c: DropdownClock) -> String {
        ([f.poolBurnPerHour.map(burn)] + [lockout(f.lockout, c)]).compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Under the weekly line, one per account that runs out before its reset:
    /// "claude-1 runs out Wed 18:00, resets Thu 09:00". A nil run-out ("lasts until its
    /// reset" or "no rate yet") says nothing worth a line.
    static func weeklyRunOuts(_ f: ForecastSummary, _ c: DropdownClock) -> [String] {
        f.weekly.compactMap { w in
            ForecastText.weekly(w, timeZone: c.timeZone).map { "\(w.alias) \($0)" }
        }
    }
}
