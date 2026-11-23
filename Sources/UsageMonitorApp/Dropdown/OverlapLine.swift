import SwiftUI
import UsageCore

/// One bar of the overlap line, in points from the line's left edge.
struct OverlapRect: Equatable, Sendable {
    let alias: String
    let style: BarStyle
    let kind: Kind
    let minX: CGFloat
    let maxX: CGFloat
    /// Square ends (plan.md "Gauge design": any rounding at most 1 px). Always 0.
    let cornerRadius: CGFloat

    var width: CGFloat { maxX - minX }

    enum Kind: Equatable, Sendable { case bar, tick }
    static let tickWidth: CGFloat = 2
}

/// The overlap line (plan.md "Gauge design", option E): every bar runs from 0 to its
/// remaining %, on the 0-100 scale of `width`. Returned in drawing order, fullest
/// first, so the emptiest is drawn last and ends up on top. Equal values keep their
/// input order.
///
/// A seat with nothing left, or one that can't take traffic now (`greyed`: Pool rule 4
/// counts it as 0 in the usable share), has no bar: it is a 2 pt vertical tick at 0 in
/// its own color, drawn after the bars. Several ticks sit side by side, 1 pt apart, in
/// input order (user, 2026-11-23: "it sits as a vertical line at 0").
func overlapRects(bars: [GaugeBar], width: CGFloat) -> [OverlapRect] {
    let drawn = bars.enumerated()
        .sorted { a, b in
            a.element.remaining != b.element.remaining
                ? a.element.remaining > b.element.remaining
                : a.offset < b.offset
        }
        .compactMap { _, bar -> OverlapRect? in
            let w = width * CGFloat(min(max(bar.remaining, 0), 100)) / 100
            guard w > 0, !bar.greyed else { return nil }
            return OverlapRect(alias: bar.alias, style: .series(bar.colorIndex), kind: .bar,
                               minX: 0, maxX: w, cornerRadius: 0)
        }
    let ticks = bars.filter { $0.greyed || $0.remaining <= 0 }.enumerated().map { i, bar in
        let x = CGFloat(i) * (OverlapRect.tickWidth + 1)
        return OverlapRect(alias: bar.alias, style: .series(bar.colorIndex), kind: .tick,
                           minX: x, maxX: x + OverlapRect.tickWidth, cornerRadius: 0)
    }
    return drawn + ticks
}

/// Where the weekly pace marker goes; nil when the gauge has no pace (monthly, or
/// hidden by the weekly rule).
func paceX(_ gauge: WindowGauge?, width: CGFloat) -> CGFloat? {
    gauge?.pace.map { width * CGFloat(min(max($0, 0), 1)) }
}

/// One window's line: the overlap bars on the track, the zero ticks standing 2 pt above
/// and below the line, and (weekly) the pace marker, the full height of the view.
struct OverlapLineView: View {
    let bars: [GaugeBar]
    let palette: DropdownPalette
    var pace: Double? = nil
    var thickness: CGFloat = 8
    static let height: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            let y = (size.height - thickness) / 2
            context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: thickness)),
                         with: .color(palette.track))
            for r in overlapRects(bars: bars, width: size.width) {
                let rect = r.kind == .bar
                    ? CGRect(x: r.minX, y: y, width: r.width, height: thickness)
                    : CGRect(x: r.minX, y: max(y - 2, 0), width: r.width, height: min(thickness + 4, size.height))
                context.fill(Path(rect), with: .color(palette.fill(r.style)))
            }
            if let pace {
                let x = size.width * CGFloat(min(max(pace, 0), 1))
                let tick = CGRect(x: min(max(x - 1, 0), size.width - 2), y: 0, width: 2, height: size.height)
                context.fill(Path(tick), with: .color(palette.textPrimary))
            }
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityLabel(bars.map { "\($0.alias) \(Int($0.remaining.rounded()))%" }
            .joined(separator: ", "))
    }
}
