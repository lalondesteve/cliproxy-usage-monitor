import AppKit
import UsageCore

/// Draws the status item as one template image: logos plus text, or the compact glyph.
/// The image carries the text, so its width (from `StatusLayout` with text measured in
/// the menubar font) is the button's width and nothing gets clipped.
@MainActor
enum StatusImage {
    /// The menubar font with tabular digits, so the item doesn't shift as numbers change.
    static var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }

    static func height(font: NSFont) -> CGFloat {
        max(StatusLayout.compactGlyphSize, (font.ascender - font.descender).rounded(.up))
    }

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    static func layout(for entries: [StatusEntry], font: NSFont) -> StatusLayout.Normal {
        StatusLayout.normal(textWidths: entries.map { textWidth($0.text, font: font) })
    }

    /// Logos and % per provider. `logo` returns each provider's glyph at any size.
    static func normal(_ entries: [StatusEntry], font: NSFont = font,
                       logo: (Provider) -> NSImage?) -> NSImage {
        let layout = layout(for: entries, font: font)
        let height = height(font: font)
        let logos = entries.map { logo($0.provider) }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        // Digits are about cap height: center that band on the image's middle, like the glyph.
        let baseline = ((height - font.capHeight) / 2).rounded()
        let image = NSImage(size: NSSize(width: max(layout.width, 1), height: height), flipped: false) { _ in
            for (i, slot) in layout.slots.enumerated() {
                let origin = CGPoint(x: slot.glyphX, y: (height - StatusLayout.glyphSize) / 2)
                if let glyph = logos[i] {
                    let aspect = glyph.size.height > 0 ? glyph.size.width / glyph.size.height : 1
                    glyph.draw(in: StatusLayout.aspectFit(aspect: aspect, box: StatusLayout.glyphSize,
                                                          origin: origin))
                }
                (entries[i].text as NSString).draw(at: NSPoint(x: slot.textX, y: baseline + font.descender),
                                                   withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = entries
            .map { "\(StatusAssets.displayName($0.provider)) \($0.text)" }
            .joined(separator: ", ")
        return image
    }

    /// The 16 px three-spoke glyph.
    static func compact(glyph: NSImage?, font: NSFont = font) -> NSImage {
        let size = StatusLayout.compactGlyphSize
        let height = height(font: font)
        let image = NSImage(size: NSSize(width: size, height: height), flipped: false) { _ in
            glyph?.draw(in: NSRect(x: 0, y: (height - size) / 2, width: size, height: size))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Usage Monitor"
        return image
    }

    /// A PNG of a template image as the menubar would tint it: black ink on a light bar
    /// and white ink on a dark bar, stacked, at `scale`.
    static func reviewPNG(_ image: NSImage, scale: CGFloat = 4, padding: CGFloat = 6) -> Data? {
        let band = NSSize(width: image.size.width + 2 * padding, height: 24)
        let pixels = NSSize(width: band.width * scale, height: band.height * 2 * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width),
                                         pixelsHigh: Int(pixels.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        // Points, so the context draws at `scale` pixels per point.
        rep.size = NSSize(width: band.width, height: band.height * 2)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bands: [(y: CGFloat, background: NSColor, ink: NSColor)] = [
            (band.height, NSColor(white: 0.95, alpha: 1), .black),
            (0, NSColor(white: 0.16, alpha: 1), .white),
        ]
        for b in bands {
            b.background.setFill()
            NSRect(x: 0, y: b.y, width: band.width, height: band.height).fill()
            let tinted = tint(image, b.ink)
            tinted.draw(in: NSRect(x: padding, y: b.y + (band.height - image.size.height) / 2,
                                   width: image.size.width, height: image.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func tint(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// Logo and glyph files: from the app bundle, else the repo's assets/ (swift run, tests).
enum StatusAssets {
    static func logoName(_ provider: Provider) -> String {
        switch provider {
        case .claude: "claude"
        case .codex: "codex"
        case .go: "opencode"
        }
    }

    static func displayName(_ provider: Provider) -> String {
        switch provider {
        case .claude: "Claude"
        case .codex: "Codex"
        case .go: "OpenCode Go"
        }
    }

    static var currentDirectory: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath) }

    /// `repoRoot` is where assets/ lives when not running from the .app.
    static func image(named name: String, subdirectory: String, repoRoot: URL? = nil) -> NSImage? {
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: "svg"),
            (repoRoot ?? currentDirectory).appendingPathComponent("assets/\(subdirectory)/\(name).svg"),
        ]
        guard let url = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else { return nil }
        return NSImage(contentsOf: url)
    }

    static func logo(_ provider: Provider, repoRoot: URL? = nil) -> NSImage? {
        image(named: logoName(provider), subdirectory: "logos", repoRoot: repoRoot)
    }

    static func compactGlyph(repoRoot: URL? = nil) -> NSImage? {
        image(named: "compact", subdirectory: "icons", repoRoot: repoRoot)
    }
}
