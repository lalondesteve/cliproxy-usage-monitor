import SwiftUI
import UsageCore

/// Column widths from the mockup's grid (64 px name, line, number), with the number
/// column wide enough for a range ("41-74%").
enum DropdownLayout {
    static let width: CGFloat = 360
    static let padding: CGFloat = 14
    static let nameWidth: CGFloat = 64
    static let numberWidth: CGFloat = 52
    static let gap: CGFloat = 10
    /// Where the line starts; aux text under it lines up with it.
    static var lineInset: CGFloat { nameWidth + gap }
}

/// The dropdown's content: one row per provider, then the state of each source.
/// Renders only what `DashboardModel` says; no fetching.
struct DropdownView: View {
    let model: DashboardModel?
    let clock: DropdownClock
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = DropdownPalette.forScheme(scheme)
        VStack(alignment: .leading, spacing: 14) {
            if let model, !model.rows.isEmpty {
                ForEach(model.rows, id: \.provider) { row in
                    ProviderRowView(row: row, clock: clock,
                                    sourceStatus: model.sources[DropdownText.source(for: row.provider)])
                }
            } else {
                Text(model == nil ? "Loading…" : "No data yet")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
            }
            if let model, SourcesFooter.hasProblems(model) {
                Rectangle().fill(palette.track).frame(height: 1)
                SourcesFooter(model: model, clock: clock)
            }
        }
        .padding(DropdownLayout.padding)
        .frame(width: DropdownLayout.width, alignment: .leading)
    }
}

struct ProviderRowView: View {
    let row: ProviderRow
    let clock: DropdownClock
    let sourceStatus: SourceStatus?
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    /// The row's hover detail (per-account values, unknowns' old values, unclassified
    /// readings, forecast).
    var hover: RowHover { RowHover(row: row, clock: clock) }

    var body: some View {
        let palette = DropdownPalette.forScheme(scheme)
        let five = row.fiveHour
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DropdownLayout.gap) {
                Text(DropdownText.providerName(row.provider))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: DropdownLayout.nameWidth, alignment: .leading)
                OverlapLineView(bars: five?.bars ?? [], palette: palette)
                number(DropdownText.headline(five), size: 13, palette: palette)
            }
            auxLine(palette: palette)
            if row.weekly != nil { meterRow("weekly", row.weekly, palette: palette) }
            if row.monthly != nil { meterRow("monthly", row.monthly, palette: palette) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .popover(isPresented: $hovering, arrowEdge: .leading) {
            RowHoverView(hover: hover).environment(\.colorScheme, scheme)
        }
    }

    /// Under the line: "2 of 3 known · 3m ago" on the left (it may wrap), "reset
    /// in …" on the right (never truncated); a source in trouble gets its own line.
    private func auxLine(palette: DropdownPalette) -> some View {
        let five = row.fiveHour
        let problem = DropdownText.sourceProblem(DropdownText.source(for: row.provider), sourceStatus)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let left = knownAndFreshness(five, palette: palette) {
                    left.fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if let countdown = DropdownText.countdown(five, now: clock.now) {
                    Text(countdown).lineLimit(1).fixedSize().layoutPriority(1)
                }
            }
            if let problem { Text(problem).foregroundStyle(palette.warning) }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(palette.textMuted)
        .padding(.leading, DropdownLayout.lineInset)
    }

    /// "2 of 3 known · 3m ago", with "stale, 42m ago" in the warning color
    /// (plan.md Pool rule 6: freshness on every number). nil when there's nothing to say.
    private func knownAndFreshness(_ g: WindowGauge?, palette: DropdownPalette) -> Text? {
        var parts: [Text] = []
        if let k = DropdownText.known(g) { parts.append(Text(k)) }
        if let oldest = DropdownText.oldestReading(g) {
            let age = DropdownText.age(oldest, now: clock.now)
            parts.append(DropdownText.isStale(g)
                ? Text("stale, \(age)").foregroundStyle(palette.warning)
                : Text(age))
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + Text(" · ") + $1 }
    }

    private func meterRow(_ name: String, _ g: WindowGauge?, palette: DropdownPalette) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DropdownLayout.gap) {
                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textMuted)
                    .frame(width: DropdownLayout.nameWidth, alignment: .trailing)
                OverlapLineView(bars: g?.bars ?? [], palette: palette, pace: g?.pace, thickness: 6)
                number(DropdownText.headline(g), size: 12, palette: palette)
            }
            if let notes = knownAndFreshness(g, palette: palette) {
                indented(notes.foregroundStyle(palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true))
            }
        }
        .padding(.top, 3)
    }

    private func number(_ s: String, size: CGFloat, palette: DropdownPalette) -> some View {
        Text(s)
            .font(.system(size: size, weight: .semibold).monospacedDigit())
            .foregroundStyle(palette.textPrimary)
            .lineLimit(1)
            .fixedSize()
            .frame(width: DropdownLayout.numberWidth, alignment: .trailing)
    }

    private func indented(_ t: some View) -> some View {
        t.font(.system(size: 11).monospacedDigit())
            .padding(.leading, DropdownLayout.lineInset)
    }
}

/// The hover card for a provider row.
struct RowHoverView: View {
    let hover: RowHover
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = DropdownPalette.forScheme(scheme)
        VStack(alignment: .leading, spacing: 8) {
            Text(hover.title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            ForEach(Array(hover.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                    ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            swatch(line.swatch, palette: palette)
                            Text(line.label).foregroundStyle(palette.textPrimary)
                            Text(line.value).fontWeight(.semibold).foregroundStyle(palette.textPrimary)
                            Text(line.detail)
                                .foregroundStyle(line.warning ? palette.warning : palette.textMuted)
                        }
                    }
                    ForEach(Array(section.notes.enumerated()), id: \.offset) { _, note in
                        Text(note).foregroundStyle(palette.textMuted)
                    }
                }
                .font(.system(size: 11).monospacedDigit())
            }
        }
        .padding(10)
        .fixedSize()
    }

    @ViewBuilder
    private func swatch(_ style: BarStyle?, palette: DropdownPalette) -> some View {
        if let style {
            RoundedRectangle(cornerRadius: 1).fill(palette.fill(style)).frame(width: 8, height: 8)
        } else {
            RoundedRectangle(cornerRadius: 1).strokeBorder(palette.textMuted, lineWidth: 1)
                .frame(width: 8, height: 8)
        }
    }
}

/// Only the sources in trouble (auth stopped, failing); a source polling normally, or
/// not configured, says nothing.
struct SourcesFooter: View {
    let model: DashboardModel
    let clock: DropdownClock
    @Environment(\.colorScheme) private var scheme

    static func troubled(_ model: DashboardModel) -> [SourceKind] {
        SourceKind.allCases.filter {
            switch model.sources[$0] {
            case .authStopped?, .failing?: true
            default: false
            }
        }
    }

    static func hasProblems(_ model: DashboardModel) -> Bool { !troubled(model).isEmpty }

    var body: some View {
        let palette = DropdownPalette.forScheme(scheme)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.troubled(model), id: \.self) { kind in
                let s = DropdownText.sourceStatus(kind, model.sources[kind]!, clock)
                Text(s.text).foregroundStyle(color(s.severity, palette))
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .fixedSize(horizontal: false, vertical: true)
    }

    private func color(_ s: DropdownText.Severity, _ p: DropdownPalette) -> Color {
        switch s {
        case .normal: p.textMuted
        case .warning: p.warning
        case .error: p.error
        }
    }
}
