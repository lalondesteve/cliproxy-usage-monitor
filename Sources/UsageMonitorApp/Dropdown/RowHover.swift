import Foundation
import UsageCore

/// What hovering a provider row shows: each account's value, reset and freshness per
/// window, the old value and its age for unknowns, the next refill, unclassified
/// readings (even for accounts with no bar), and forecast text.
struct RowHover: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        /// nil: the account has no bar in this window (unknown, or not a window reading).
        let swatch: BarStyle?
        let label: String
        let value: String
        let detail: String
        let warning: Bool
    }

    struct Section: Equatable, Sendable {
        let title: String
        let lines: [Line]
        /// Free text under the lines ("next refill 14:10, +27% of pool").
        let notes: [String]
    }

    let title: String
    let sections: [Section]

    init(row: ProviderRow, clock c: DropdownClock) {
        title = DropdownText.providerName(row.provider)
        var sections: [Section] = []
        if let g = row.fiveHour { sections.append(Self.window(g, name: "5-hour", c)) }
        if let g = row.weekly { sections.append(Self.window(g, name: "Weekly", c)) }
        if let g = row.monthly { sections.append(Self.window(g, name: "Monthly", c)) }
        if !row.unclassified.isEmpty {
            sections.append(Section(
                title: "Unclassified (in no pool)",
                lines: row.unclassified.map { Self.unclassified($0, c) },
                notes: []))
        }
        if let f = row.forecast, let s = Self.forecast(f, c) { sections.append(s) }
        self.sections = sections
    }

    static func window(_ g: WindowGauge, name: String, _ c: DropdownClock) -> Section {
        var title = name
        if g.window == .fiveHour {
            title += ": \(DropdownText.percent(g.usable)) usable"
            if let q = g.quota, DropdownText.percent(q) != DropdownText.percent(g.usable) {
                title += ", quota \(DropdownText.percent(q))"
            }
        } else {
            title += ": \(DropdownText.percent(g.quota)) left"
            if let p = g.pace { title += ", pace \(DropdownText.percent(p * 100))" }
        }
        if let k = DropdownText.known(g) { title += " (\(k))" }

        let lines = g.accounts.map { a -> Line in
            let bar = g.bars.first { $0.alias == a.alias }
            return account(a, bar: bar, c)
        }
        var notes: [String] = []
        if let r = g.nextRefill {
            notes.append("next refill \(DropdownText.clock(r.at, c)), \(DropdownText.poolGain(r.poolGain))")
        } else if g.allFull {
            notes.append("all full: a new window starts with the next request")
        }
        return Section(title: title, lines: lines, notes: notes)
    }

    static func account(_ a: AccountDetail, bar: GaugeBar?, _ c: DropdownClock) -> Line {
        var parts: [String] = []
        if let email = a.email { parts.append(email) }
        if a.remaining == nil {
            if let p = a.previous {
                parts.append("was \(DropdownText.percent(p.value)) \(DropdownText.age(p.observedAt, now: c.now))")
            } else {
                parts.append("never read")
            }
        }
        if !a.usable { parts.append(a.blockedReason ?? "not usable") }
        if let r = a.resetsAt { parts.append(DropdownText.reset(r, c)) }
        if let o = a.observedAt, a.remaining != nil {
            parts.append("read \(DropdownText.age(o, now: c.now))")
        }
        if a.stale { parts.append("stale") }
        return Line(
            swatch: bar.map { .series($0.colorIndex) },
            label: a.alias,
            value: a.remaining.map(DropdownText.percent) ?? "unknown",
            detail: parts.joined(separator: " · "),
            warning: a.stale)
    }

    static func unclassified(_ u: UnclassifiedDetail, _ c: DropdownClock) -> Line {
        var parts = [DropdownText.windowLength(u.lengthSeconds)]
        if let r = u.resetsAt { parts.append(DropdownText.reset(r, c)) }
        parts.append("read \(DropdownText.age(u.observedAt, now: c.now))")
        return Line(swatch: nil, label: u.alias, value: "\(DropdownText.percent(u.usedPercent)) used",
                    detail: parts.joined(separator: " · "), warning: false)
    }

    static func forecast(_ f: ForecastSummary, _ c: DropdownClock) -> Section? {
        var notes: [String] = []
        if let burn = f.poolBurnPerHour { notes.append("burn \(DropdownText.burnPercent(burn)) of pool per hour") }
        notes.append(DropdownText.lockout(f.lockout, c))
        // A nil runOut means either "lasts until its reset" or "no burn rate", so it
        // says nothing reassuring: only accounts with a run-out time are listed.
        for w in f.weekly {
            guard let text = ForecastText.weekly(w, timeZone: c.timeZone) else { continue }
            notes.append("\(w.alias): weekly \(text)")
        }
        return Section(title: "Forecast", lines: [], notes: notes)
    }
}
