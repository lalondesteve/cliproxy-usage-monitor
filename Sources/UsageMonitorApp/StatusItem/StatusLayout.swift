import CoreGraphics
import UsageCore

/// One provider in the menubar: which logo, and the text after it.
struct StatusEntry: Equatable {
    let provider: Provider
    let text: String

    /// The source that feeds a provider's row.
    static func source(for provider: Provider) -> SourceKind {
        provider == .go ? .ocgo : .cliproxy
    }

    /// Providers shown in the menubar, in `Provider.allCases` order. A provider is
    /// hidden when its source is missing or `.notConfigured` (plan.md: "without ocgo
    /// the Go row is hidden"), or when the model has no row for it. A row without a
    /// 5-hour number shows "--".
    static func entries(for model: DashboardModel) -> [StatusEntry] {
        Provider.allCases.compactMap { provider in
            guard let status = model.sources[source(for: provider)], status != .notConfigured,
                  let row = model.row(provider) else { return nil }
            return StatusEntry(provider: provider, text: StatusText.title(for: row.fiveHour))
        }
    }
}

/// Pure geometry of the status item image (plan.md "Gauge design", Menubar): a 14 px
/// glyph, 3 px to the number, 10 px between providers; Compact is one 16 px glyph.
/// Heights and vertical placement are the renderer's job.
enum StatusLayout {
    static let glyphSize: CGFloat = 14
    static let glyphToText: CGFloat = 3
    static let betweenProviders: CGFloat = 10
    static let compactGlyphSize: CGFloat = 16

    struct Slot: Equatable {
        /// Left edge of the 14 px glyph box; the logo is aspect-fitted and centered in it.
        let glyphX: CGFloat
        let textX: CGFloat
        let textWidth: CGFloat
    }

    struct Normal: Equatable {
        let slots: [Slot]
        let width: CGFloat
    }

    /// Text widths are rounded up to whole points so the image never clips the text.
    static func normal(textWidths: [CGFloat]) -> Normal {
        var x: CGFloat = 0
        var slots: [Slot] = []
        for (i, raw) in textWidths.enumerated() {
            if i > 0 { x += betweenProviders }
            let width = raw.rounded(.up)
            slots.append(Slot(glyphX: x, textX: x + glyphSize + glyphToText, textWidth: width))
            x += glyphSize + glyphToText + width
        }
        return Normal(slots: slots, width: x)
    }

    /// The rect a glyph of `aspect` (width / height) takes inside a square box at `origin`.
    static func aspectFit(aspect: CGFloat, box: CGFloat, origin: CGPoint) -> CGRect {
        guard aspect > 0 else { return CGRect(origin: origin, size: CGSize(width: box, height: box)) }
        let size = aspect >= 1
            ? CGSize(width: box, height: box / aspect)
            : CGSize(width: box * aspect, height: box)
        return CGRect(x: origin.x + (box - size.width) / 2, y: origin.y + (box - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
