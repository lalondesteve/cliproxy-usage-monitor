import SwiftUI
import UsageCore

/// One bar of the overlap line, in points from the line's left edge.
struct OverlapRect: Equatable, Sendable {
    let alias: String
    let style: BarStyle
    let minX: CGFloat
    let maxX: CGFloat
    /// Square ends (plan.md "Gauge design": any rounding at most 1 px). Always 0.
    let cornerRadius: CGFloat

    var width: CGFloat { maxX - minX }
}

/// The overlap line (plan.md "Gauge design", option E): every bar runs from 0 to its
/// remaining %, on the 0-100 scale of `width`. Returned in drawing order, fullest
/// first, so the emptiest is drawn last and ends up on top. Equal values keep their
/// input order. Bars with nothing left have no width and are left out.
func overlapRects(bars: [GaugeBar], width: CGFloat) -> [OverlapRect] {
    bars.enumerated()
        .sorted { a, b in
            a.element.remaining != b.element.remaining
                ? a.element.remaining > b.element.remaining
                : a.offset < b.offset
        }
        .compactMap { _, bar in
            let w = width * CGFloat(min(max(bar.remaining, 0), 100)) / 100
            guard w > 0 else { return nil }
            return OverlapRect(alias: bar.alias,
                               style: bar.greyed ? .grey : .series(bar.colorIndex),
                               minX: 0, maxX: w, cornerRadius: 0)
        }
}

/// The weekly and monthly meter: one pooled bar plus the weekly pace marker.
struct MeterGeometry: Equatable, Sendable {
    /// The pooled value's lower bound: a range fills only what is certain.
    let fillWidth: CGFloat
    /// nil when the gauge has no pace (monthly, or hidden by the weekly rule).
    let paceX: CGFloat?

    init(gauge: WindowGauge?, width: CGFloat) {
        let lower = gauge?.quota?.lower ?? 0
        fillWidth = width * CGFloat(min(max(lower, 0), 100)) / 100
        paceX = gauge?.pace.map { width * CGFloat(min(max($0, 0), 1)) }
    }
}

/// The 5-hour line. 8 pt thick, as in the mockup.
struct OverlapLineView: View {
    let bars: [GaugeBar]
    let palette: DropdownPalette
    static let thickness: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.track))
            for r in overlapRects(bars: bars, width: size.width) {
                let rect = CGRect(x: r.minX, y: 0, width: r.width, height: size.height)
                context.fill(Path(rect), with: .color(palette.fill(r.style)))
            }
        }
        .frame(height: Self.thickness)
        .accessibilityElement()
        .accessibilityLabel(bars.map { "\($0.alias) \(Int($0.remaining.rounded()))%" }
            .joined(separator: ", "))
    }
}

/// Weekly and monthly: a thinner pooled meter; the pace marker is a 2 pt tick that
/// stands out above and below it.
struct MeterView: View {
    let gauge: WindowGauge?
    let palette: DropdownPalette
    static let height: CGFloat = 12
    static let thickness: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            let y = (size.height - Self.thickness) / 2
            let g = MeterGeometry(gauge: gauge, width: size.width)
            context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: Self.thickness)),
                         with: .color(palette.track))
            context.fill(Path(CGRect(x: 0, y: y, width: g.fillWidth, height: Self.thickness)),
                         with: .color(palette.meter))
            if let x = g.paceX {
                let tick = CGRect(x: min(max(x - 1, 0), size.width - 2), y: 0, width: 2, height: size.height)
                context.fill(Path(tick), with: .color(palette.textPrimary))
            }
        }
        .frame(height: Self.height)
    }
}
