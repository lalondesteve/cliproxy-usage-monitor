import SwiftUI

/// How one bar of the overlap line is filled.
enum BarStyle: Equatable, Sendable {
    /// The account's own color (`GaugeBar.colorIndex`). No grey: a seat that can't
    /// take traffic is a tick at 0 in its own color (`overlapRects`).
    case series(Int)
}

/// Text and track tones from docs/mockups/gauges-overlap.html, one set per color
/// scheme; the account colors are the user's four (2026-11-23), the same in both. Resolved from the SwiftUI color scheme rather than
/// dynamic NSColors, so offscreen renders get the same colors as the popover.
struct DropdownPalette: Sendable {
    let surface: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let track: Color
    let warning: Color
    let error: Color
    /// Orange, blue, green, purple. Higher indexes get derived colors
    /// (`seriesColor`), so two accounts never share one.
    let series: [Color]
    /// Saturation and brightness for derived colors, close to the palette's own.
    let derivedSaturation: Double
    let derivedBrightness: Double

    static let light = DropdownPalette(
        surface: hex(0xFCFCFB), textPrimary: hex(0x0B0B0B), textSecondary: hex(0x52514E),
        textMuted: hex(0x8A8984), track: hex(0xE9E8E4),
        warning: hex(0xB25E00), error: hex(0xC4302B),
        series: accountColors,
        derivedSaturation: 0.78, derivedBrightness: 0.80
    )

    static let dark = DropdownPalette(
        surface: hex(0x1A1A19), textPrimary: hex(0xF0EFEC), textSecondary: hex(0xC3C2B7),
        textMuted: hex(0x8F8E86), track: hex(0x2E2E2C),
        warning: hex(0xE0A040), error: hex(0xEF6B64),
        series: accountColors,
        derivedSaturation: 0.72, derivedBrightness: 0.86
    )

    static let accountColors = [hex(0xFF9E64), hex(0x7AA2F7), hex(0x9ECE6A), hex(0xBB9AF7)]

    static func forScheme(_ scheme: ColorScheme) -> DropdownPalette {
        scheme == .dark ? dark : light
    }

    func fill(_ style: BarStyle) -> Color {
        switch style {
        case .series(let index): seriesColor(index)
        }
    }

    /// The store hands out color indexes 0, 1, 2, ... per provider and never reuses
    /// them, so indexes past the palette keep growing with account turnover. Those
    /// step the hue by the golden angle from 100 degrees (between the palette's green
    /// and amber), alternating saturation so a hue near a palette color still reads
    /// differently. Same index, same color.
    func seriesColor(_ index: Int) -> Color {
        if index >= 0, index < series.count { return series[index] }
        let k = index < 0 ? series.count - 1 - index : index - series.count
        let hue = (100 + 137.507_764 * Double(k)).truncatingRemainder(dividingBy: 360) / 360
        let saturation = k % 2 == 0 ? derivedSaturation : derivedSaturation * 0.6
        return Color(hue: hue, saturation: saturation, brightness: derivedBrightness)
    }

    private static func hex(_ v: UInt32) -> Color {
        Color(.sRGB,
              red: Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255)
    }
}
